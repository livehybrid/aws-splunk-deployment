#!/usr/bin/env bash
# Deep Splunk-side health checks for a workspace, via SSM (no inbound access
# needed). Complements scripts/smoke-test.sh, which covers the AWS side.
#
#   ./scripts/cluster-health.sh <env>        e.g. prod | dev
#
# Checks:
#   1. Indexer cluster (on the Cluster Manager):
#        RF met, SF met, all data searchable, peer count Up.
#   2. SHC (on a search head):
#        captain elected (dynamic), service_ready_flag, member count Up.
#        Skipped when the workspace runs a standalone SH (enable_shc=false).
#   3. KV store (on a search head):
#        local member ready, exactly one KV store captain, no failed members.
#   4. License Manager: ENTERPRISE licence stack present and VALID.
#   5. Monitoring Console: distributed-search peers registered.
#
# Auth: admin password resolved from Secrets Manager on the instance.
# Override admin username with SPLUNK_ADMIN_USER (default splunkadmin).
set -uo pipefail
export AWS_PAGER="" # AWS CLI v2 pipes TTY output through less otherwise

ENV="${1:?usage: cluster-health.sh <env>}"
REGION="${AWS_REGION:-eu-west-2}"
AUSER="${SPLUNK_ADMIN_USER:-splunkadmin}"
FAIL=0

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n=== %s ===\n' "$*"; }

instance_for_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:project,Values=splunk" \
              "Name=tag:environment,Values=$ENV" \
              "Name=tag:role,Values=$1" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null
}

# run_splunk <instance-id> <splunk subcommand...>, prints stdout, rc=1 on fail.
run_splunk() {
  local id=$1; shift
  local remote params cmd_id status
  # `|| true`, checks grep for positive markers, so a non-zero splunk exit
  # (e.g. shcluster-status on a standalone SH) must still return its output
  # rather than tripping SSM's Failed status and swallowing stdout.
  remote="
ADMIN=\$(aws secretsmanager get-secret-value --region $REGION \
  --secret-id /monitoring/splunk/password --query SecretString --output text)
sudo -u splunk /opt/splunk/bin/splunk $* -auth \"$AUSER:\$ADMIN\" 2>&1 || true
"
  params=$(jq -n --arg c "$remote" '{commands: [$c]}')
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$id" \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query 'Command.CommandId' --output text) || return 1
  for _ in $(seq 1 45); do
    status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$id" \
      --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success)
        aws ssm get-command-invocation --region "$REGION" \
          --command-id "$cmd_id" --instance-id "$id" \
          --query 'StandardOutputContent' --output text
        return 0 ;;
      Failed|Cancelled|TimedOut) return 1 ;;
    esac
    sleep 2
  done
  return 1
}

###############################################################################
hdr "Indexer cluster (via Cluster Manager)"
MGR=$(instance_for_role manager)
if [ -z "$MGR" ] || [ "$MGR" = "None" ]; then
  red "no running manager instance"
else
  OUT=$(run_splunk "$MGR" show cluster-status --verbose) || OUT=""
  if [ -z "$OUT" ]; then
    red "cluster-status query failed on $MGR"
  else
    echo "$OUT" | grep -qiE 'replication factor met.*yes' \
      && green "replication factor met" \
      || red "replication factor NOT met"
    echo "$OUT" | grep -qiE 'search factor met.*yes' \
      && green "search factor met" \
      || red "search factor NOT met"
    echo "$OUT" | grep -qiE 'all data is searchable.*yes' \
      && green "all data searchable" \
      || red "data NOT fully searchable"
    # cluster-status prints each peer's "Status  Up" on its own line.
    PEERS_UP=$(echo "$OUT" | grep -cE '^\s*Status\s+Up\b' || true)
    if [ "$PEERS_UP" -gt 0 ]; then
      green "indexer peers Up: $PEERS_UP"
    else
      red "no indexer peers in Up state"
    fi
  fi
fi

###############################################################################
hdr "Search head cluster"
SH=$(instance_for_role searchhead)
if [ -z "$SH" ] || [ "$SH" = "None" ]; then
  red "no running searchhead instance"
else
  OUT=$(run_splunk "$SH" show shcluster-status --verbose) || OUT=""
  # NB: must not match benign output like "kvstore_maintenance_status : disabled".
  if echo "${OUT:-}" | grep -qiE 'not part of a search head cluster|not enabled'; then
    # Standalone SH (dev, enable_shc=false).
    green "standalone SH (no SHC in this workspace), skipping SHC checks"
  elif [ -z "$OUT" ]; then
    red "shcluster-status query failed on $SH"
  else
    CAPTAIN=$(echo "$OUT" | grep -E 'elected_captain' | head -1 | awk -F: '{print $2}' | xargs)
    if [ -n "$CAPTAIN" ]; then
      green "captain elected: $CAPTAIN"
    else
      red "no elected captain"
    fi
    echo "$OUT" | grep -qE 'dynamic_captain\s*:\s*1' \
      && green "dynamic captain election active" \
      || red "dynamic captain NOT active (static captain?)"
    echo "$OUT" | grep -qE 'service_ready_flag\s*:\s*1' \
      && green "SHC service ready" \
      || red "SHC service NOT ready"
    MEMBERS_UP=$(echo "$OUT" | grep -cE 'status\s*:\s*Up' || true)
    if [ "$MEMBERS_UP" -ge 1 ]; then
      green "SHC members Up: $MEMBERS_UP"
    else
      red "no SHC members Up"
    fi
    echo "$OUT" | grep -qE 'rolling_restart_flag\s*:\s*1' \
      && red "rolling restart in progress" \
      || green "no rolling restart in progress"
  fi

  #############################################################################
  hdr "KV store (via search head)"
  KV=$(run_splunk "$SH" show kvstore-status) || KV=""
  if [ -z "$KV" ]; then
    red "kvstore-status query failed on $SH"
  else
    echo "$KV" | grep -qE 'status\s*:\s*ready' \
      && green "local KV store ready" \
      || red "local KV store NOT ready"
    CAPTAINS=$(echo "$KV" | grep -cE 'replicationStatus\s*:\s*KV store captain' || true)
    case "$CAPTAINS" in
      1) green "exactly one KV store captain" ;;
      0) # standalone KV store has no replication section at all
         if echo "$KV" | grep -qE 'replicationStatus'; then
           red "no KV store captain elected"
         else
           green "standalone KV store (no replication), captain check n/a"
         fi ;;
      *) red "$CAPTAINS KV store captains (split brain?)" ;;
    esac
    FAILED=$(echo "$KV" | grep -cE 'status\s*:\s*(failed|down)' || true)
    [ "$FAILED" -eq 0 ] \
      && green "no failed KV store members" \
      || red "$FAILED KV store member(s) failed/down"
  fi
fi

###############################################################################
hdr "License Manager"
LIC=$(instance_for_role license)
if [ -z "$LIC" ] || [ "$LIC" = "None" ]; then
  red "no running license instance"
else
  OUT=$(run_splunk "$LIC" list licenses) || OUT=""
  if [ -z "$OUT" ]; then
    red "license query failed on $LIC"
  else
    echo "$OUT" | grep -qE 'group_id:Enterprise' \
      && green "Enterprise licence group active" \
      || red "Enterprise licence group NOT active"
    VALID=$(echo "$OUT" | grep -cE 'status:VALID' || true)
    [ "$VALID" -ge 1 ] \
      && green "valid licence(s): $VALID" \
      || red "no VALID licences installed"
  fi
fi

###############################################################################
hdr "Monitoring Console"
MC=$(instance_for_role monitoring_console)
if [ -z "$MC" ] || [ "$MC" = "None" ]; then
  red "no running monitoring_console instance"
else
  OUT=$(run_splunk "$MC" list search-server) || OUT=""
  PEERS=$(echo "${OUT:-}" | grep -cE '^Server at URI' || true)
  if [ "$PEERS" -ge 1 ]; then
    green "MC distributed-search peers: $PEERS"
  else
    red "MC has no distributed-search peers configured"
  fi
fi

###############################################################################
hdr "Result"
if [ "$FAIL" -eq 0 ]; then
  green "all cluster health checks passed"
  exit 0
else
  red "$FAIL check(s) failed"
  exit 1
fi
