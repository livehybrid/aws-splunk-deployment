#!/usr/bin/env bash
# rf-remediate.sh <env> — one-shot fix for the SmartStore cold-boot RF stall.
#
# After a cold boot against a populated SmartStore bucket, legacy buckets
# (origin GUIDs from a previous instance generation) each get registered by
# a single peer and the CM's RF/SF fixups stall with "No possible srcs for
# replication" / "Missing enough suitable candidates". A rolling restart of
# the cluster peers makes every peer re-scan the remote store and register
# all buckets, after which RF/SF converge. This script triggers that restart
# only when the stall signature is present, so it is safe to call from CI.
set -euo pipefail
export AWS_PAGER=""

ENV_TAG="${1:?usage: rf-remediate.sh <env>}"
REGION="${AWS_REGION:-eu-west-2}"
# Override admin username with SPLUNK_ADMIN_USER (default splunkadmin).
AUSER="${SPLUNK_ADMIN_USER:-splunkadmin}"

MID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${ENV_TAG}_manager*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ -z "$MID" ] || [ "$MID" = "None" ]; then
  echo "no running cluster manager found for env=$ENV_TAG" >&2
  exit 1
fi

run_on_cm() {
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$MID" \
    --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]}" \
    --query Command.CommandId --output text)
  # SSM invocations are eventually consistent; poll until terminal.
  for _ in $(seq 1 20); do
    sleep 5
    local status
    status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$MID" \
      --query Status --output text 2>/dev/null) || continue
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
  done
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$MID" \
    --query StandardOutputContent --output text
}

STATUS=$(run_on_cm 'sudo -u splunk /opt/splunk/bin/splunk show cluster-status 2>/dev/null | head -8')
if ! grep -qi "factor not met" <<<"$STATUS"; then
  echo "RF/SF already met (or cluster-status unavailable); nothing to do"
  exit 0
fi
if grep -qi "rolling restart" <<<"$STATUS"; then
  echo "rolling restart already in progress; letting it finish"
  exit 0
fi

FIXUPS=$(run_on_cm 'P=$(aws secretsmanager get-secret-value --region eu-west-2 --secret-id /monitoring/splunk/password --query SecretString --output text); curl -ks -u "'"$AUSER"':$P" "https://127.0.0.1:8089/services/cluster/manager/fixup?level=replication_factor&output_mode=json&count=100"')
if ! grep -qE "No possible srcs for replication|Missing enough suitable candidates" <<<"$FIXUPS"; then
  echo "RF not met but no stall signature in fixup reasons; not restarting (likely still converging)"
  exit 0
fi

echo "RF fixups stalled on legacy SmartStore buckets; triggering rolling restart of cluster peers"
run_on_cm 'P=$(aws secretsmanager get-secret-value --region eu-west-2 --secret-id /monitoring/splunk/password --query SecretString --output text); sudo -u splunk /opt/splunk/bin/splunk rolling-restart cluster-peers -auth "'"$AUSER"':$P" 2>&1 | grep -v WARNING'
