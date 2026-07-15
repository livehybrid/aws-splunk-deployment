#!/usr/bin/env bash
# Rotate the splunkadmin password across every running Splunk instance.
#
#   ./scripts/rotate-splunk-admin.sh <env>
#
# The new password NEVER transits the operator's shell:
#   1. The manager instance generates a new value and put-secret-value's it
#      (Secrets Manager keeps the old one as version stage AWSPREVIOUS).
#   2. Every instance then runs `splunk edit user` using AWSPREVIOUS to
#      authenticate and AWSCURRENT as the new password. Idempotent: if a
#      host already rotated, auth with AWSCURRENT is verified instead.
# New boots are consistent automatically (user-seed reads AWSCURRENT).
set -euo pipefail
export AWS_PAGER="" # AWS CLI v2 pipes TTY output through less otherwise

ENV="${1:?usage: rotate-splunk-admin.sh <env>}"
REGION="${AWS_REGION:-eu-west-2}"
AUSER="${SPLUNK_ADMIN_USER:-splunkadmin}"

instances() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:project,Values=splunk" \
              "Name=tag:environment,Values=$ENV" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n'
}

run_ssm() { # run_ssm <instance-id> <script>; prints stdout, rc!=0 on failure
  local id=$1 script=$2 params cmd_id status
  params=$(jq -n --arg c "$script" '{commands: [$c]}')
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
          --instance-id "$id" --query StandardOutputContent --output text
        return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" \
          --instance-id "$id" --query StandardErrorContent --output text >&2
        return 1 ;;
    esac
    sleep 2
  done
  return 1
}

MGR=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:project,Values=splunk" "Name=tag:environment,Values=$ENV" \
            "Name=tag:role,Values=manager" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$MGR" ] && [ "$MGR" != "None" ] || { echo "no running manager in $ENV" >&2; exit 1; }

echo "1/2 Generating new secret version (on $MGR)..."
run_ssm "$MGR" '
set -e
NEW=$(openssl rand -base64 48 | tr -d "/+=" | head -c 24)
aws secretsmanager put-secret-value --region '"$REGION"' \
  --secret-id /monitoring/splunk/password --secret-string "$NEW" >/dev/null
echo "secret rotated (new version is AWSCURRENT)"
'

ROTATE_SCRIPT='
set -e
OLD=$(aws secretsmanager get-secret-value --region '"$REGION"' \
  --secret-id /monitoring/splunk/password --version-stage AWSPREVIOUS \
  --query SecretString --output text 2>/dev/null || true)
NEW=$(aws secretsmanager get-secret-value --region '"$REGION"' \
  --secret-id /monitoring/splunk/password --query SecretString --output text)
if sudo -u splunk /opt/splunk/bin/splunk edit user '"$AUSER"' \
     -password "$NEW" -auth "'"$AUSER"':$OLD" >/dev/null 2>&1; then
  echo "ROTATED $(hostname)"
elif sudo -u splunk /opt/splunk/bin/splunk search "| makeresults | head 1" \
     -auth "'"$AUSER"':$NEW" >/dev/null 2>&1; then
  echo "ALREADY-CURRENT $(hostname)"
else
  echo "FAILED $(hostname)" >&2; exit 1
fi
'

echo "2/2 Applying on every instance..."
FAIL=0
for id in $(instances); do
  printf '%s: ' "$id"
  run_ssm "$id" "$ROTATE_SCRIPT" || { echo "FAILED"; FAIL=$((FAIL+1)); }
done

if [ "$FAIL" -eq 0 ]; then
  echo "Rotation complete on all instances."
else
  echo "$FAIL instance(s) failed — rerun; AWSPREVIOUS is retained until the next rotation." >&2
  exit 1
fi
