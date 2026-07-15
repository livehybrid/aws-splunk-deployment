#!/usr/bin/env bash
# Run a Splunk CLI command on the first running instance of a role, via SSM.
#
#   ./scripts/splunk-cmd.sh <env> <role> <splunk subcommand...>
#   ./scripts/splunk-cmd.sh prod manager show cluster-status --verbose
#   ./scripts/splunk-cmd.sh prod searchhead show shcluster-status
#
# Auth: the admin password is resolved from Secrets Manager ON the instance,
# so it never appears in SSM command parameters, shell history, or transit.
# Override the admin username with SPLUNK_ADMIN_USER (default: splunkadmin).
set -euo pipefail
export AWS_PAGER="" # AWS CLI v2 pipes TTY output through less otherwise

ENV="${1:?usage: splunk-cmd.sh <env> <role> <splunk subcommand...>}"
ROLE="${2:?usage: splunk-cmd.sh <env> <role> <splunk subcommand...>}"
shift 2
[ $# -gt 0 ] || { echo "no splunk subcommand given" >&2; exit 2; }

REGION="${AWS_REGION:-eu-west-2}"
AUSER="${SPLUNK_ADMIN_USER:-splunkadmin}"

instance_for_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:project,Values=splunk" \
              "Name=tag:environment,Values=$1" \
              "Name=tag:role,Values=$2" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

ID=$(instance_for_role "$ENV" "$ROLE")
if [ -z "$ID" ] || [ "$ID" = "None" ]; then
  echo "no running '$ROLE' instance in env=$ENV" >&2
  exit 1
fi

# Build the remote script. $ADMIN is resolved remotely; splunk CLI args are
# passed through verbatim.
REMOTE=$(printf '%s' "
ADMIN=\$(aws secretsmanager get-secret-value --region $REGION \
  --secret-id /monitoring/splunk/password --query SecretString --output text)
sudo -u splunk /opt/splunk/bin/splunk $* -auth \"$AUSER:\$ADMIN\" 2>&1
")

PARAMS=$(jq -n --arg c "$REMOTE" '{commands: [$c]}')
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$ID" \
  --document-name AWS-RunShellScript --parameters "$PARAMS" \
  --comment "splunk-cmd: $ROLE $1" \
  --query 'Command.CommandId' --output text)

for _ in $(seq 1 60); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Success)
      aws ssm get-command-invocation --region "$REGION" \
        --command-id "$CMD_ID" --instance-id "$ID" \
        --query 'StandardOutputContent' --output text
      exit 0 ;;
    Failed|Cancelled|TimedOut)
      echo "SSM command $STATUS on $ID ($ROLE):" >&2
      aws ssm get-command-invocation --region "$REGION" \
        --command-id "$CMD_ID" --instance-id "$ID" \
        --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
      exit 1 ;;
  esac
  sleep 2
done
echo "timed out waiting for SSM command $CMD_ID on $ID" >&2
exit 1
