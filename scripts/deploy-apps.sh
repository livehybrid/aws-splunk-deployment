#!/usr/bin/env bash
# Deploy apps from the git repo to the running cluster, scoped by tier:
#
#   ./scripts/deploy-apps.sh <env> [scope]
#
#   scope:
#     idx, sync CM, then validate + apply cluster-bundle   → indexers
#     shc, sync deployer, then apply shcluster-bundle      → SHC members
#     ds, sync CM, then reload deploy-server              → DS clients
#            (license, future UFs, they fetch on next phone-home)
#     cm, sync CM, then restart its splunkd               → CM's own apps
#            (restart is tolerated: peers buffer while the CM bounces)
#     all, idx + shc + ds (default; excludes the disruptive cm restart)
#
# "Sync" = /opt/splunk/bin/sync-apps-from-git.sh on the instance via SSM
# (fresh clone, guarded rsync, splunksecret substitution).
set -euo pipefail
export AWS_PAGER="" # AWS CLI v2 pipes TTY output through less otherwise

ENV="${1:?usage: deploy-apps.sh <env> [idx|shc|ds|cm|all]}"
SCOPE="${2:-all}"
case "$SCOPE" in idx|shc|ds|cm|all) ;; *) echo "invalid scope '$SCOPE' (idx|shc|ds|cm|all)" >&2; exit 2 ;; esac
REGION="${AWS_REGION:-eu-west-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"

instance_for_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:project,Values=splunk" \
              "Name=tag:environment,Values=$ENV" \
              "Name=tag:role,Values=$1" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

run_ssm() { # run_ssm <instance-id> <label> <command>
  local id=$1 label=$2 command=$3 params cmd_id status
  echo "== $label ($id): $command"
  params=$(jq -n --arg c "$command" '{commands: [$c]}')
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$id" \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 60); do
    status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$id" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success)
        aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
          --instance-id "$id" --query StandardOutputContent --output text | tail -5
        return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
          --instance-id "$id" --query '[StandardOutputContent,StandardErrorContent]' \
          --output text | tail -10 >&2
        return 1 ;;
    esac
    sleep 5
  done
  echo "timed out waiting for SSM on $id" >&2
  return 1
}

# The CM serves three scopes (idx bundle, DS content, its own apps) but only
# needs syncing once per invocation.
CM_SYNCED=false
sync_cm() {
  $CM_SYNCED && return 0
  MGR=$(instance_for_role manager)
  [ -n "$MGR" ] && [ "$MGR" != "None" ] || { echo "no running manager in $ENV" >&2; exit 1; }
  run_ssm "$MGR" "cluster manager" "/opt/splunk/bin/sync-apps-from-git.sh"
  CM_SYNCED=true
}

want() { [ "$SCOPE" = "$1" ] || { [ "$SCOPE" = "all" ] && [ "$1" != "cm" ]; }; }

if want idx; then
  sync_cm
  echo "== [idx] pushing cluster bundle to indexers"
  "$HERE/splunk-cmd.sh" "$ENV" manager validate cluster-bundle --check-restart
  "$HERE/splunk-cmd.sh" "$ENV" manager apply cluster-bundle --answer-yes
  "$HERE/splunk-cmd.sh" "$ENV" manager show cluster-bundle-status | head -15
fi

if want shc; then
  DEP=$(instance_for_role deployer)
  [ -n "$DEP" ] && [ "$DEP" != "None" ] || { echo "no running deployer in $ENV" >&2; exit 1; }
  run_ssm "$DEP" "deployer" "/opt/splunk/bin/sync-apps-from-git.sh"
  SH_IP=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:project,Values=splunk" "Name=tag:environment,Values=$ENV" \
              "Name=tag:role,Values=searchhead" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  [ -n "$SH_IP" ] && [ "$SH_IP" != "None" ] || { echo "no running searchhead in $ENV" >&2; exit 1; }
  echo "== [shc] pushing shcluster bundle via https://$SH_IP:8089"
  "$HERE/splunk-cmd.sh" "$ENV" deployer apply shcluster-bundle --answer-yes -target "https://$SH_IP:8089"
fi

if want ds; then
  sync_cm
  echo "== [ds] reloading deploy-server (clients fetch on next phone-home)"
  "$HERE/splunk-cmd.sh" "$ENV" manager reload deploy-server
fi

if want cm; then
  sync_cm
  echo "== [cm] restarting CM splunkd to load its own apps"
  run_ssm "$MGR" "cluster manager" "systemctl restart Splunkd"
fi

echo "deploy-apps complete (scope=$SCOPE)"
