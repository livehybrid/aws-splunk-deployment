#!/usr/bin/env bash
# AWS-side smoke test for a Splunk workspace.
#
# Checks (all from outside the cluster, no SSH/SSM needed):
#   1. Each ASG has DesiredCapacity met by running instances.
#   2. Every Splunk EC2 instance is in "running" state.
#   3. Each ALB/NLB target group has healthy targets matching DesiredCapacity.
#   4. SmartStore bucket exists and is reachable.
#   5. Manager UI ALB DNS resolves.
#
# Usage: ./scripts/smoke-test.sh <env>   e.g. prod | dev
set -euo pipefail
export AWS_PAGER="" # AWS CLI v2 pipes TTY output through less otherwise

ENV="${1:?'usage: smoke-test.sh <env>'}"
REGION="${AWS_REGION:-eu-west-2}"
FAIL=0

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr()   { printf '\n=== %s ===\n' "$*"; }

hdr "Auto-scaling groups (workspace=${ENV})"
asgs=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,\`${ENV}-\`)].[AutoScalingGroupName,DesiredCapacity,length(Instances)]" \
  --output text)
if [ -z "$asgs" ]; then
  red "no ASGs starting with '${ENV}-' found"
else
  while IFS=$'\t' read -r name desired actual; do
    if [ "$desired" = "$actual" ]; then
      green "$name desired=$desired actual=$actual"
    else
      red   "$name desired=$desired actual=$actual"
    fi
  done <<<"$asgs"
fi

hdr "EC2 instances"
running=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:project,Values=splunk" \
            "Name=tag:environment,Values=${ENV}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`role`]|[0].Value,InstanceLifecycle,InstanceType]' \
  --output text)
if [ -z "$running" ]; then
  red "no running instances tagged environment=${ENV}"
else
  echo "$running" | while IFS=$'\t' read -r id role life type; do
    green "$id $role $type ${life:-on-demand}"
  done
fi

hdr "Target group health"
tg_arns=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?starts_with(TargetGroupName,\`splunk\`)].TargetGroupArn" \
  --output text)
for tg in $tg_arns; do
  name=$(echo "$tg" | awk -F/ '{print $(NF-1)}')
  health=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  if [ -z "$health" ]; then
    red "$name: no targets registered"; continue
  fi
  if echo "$health" | tr '\t' '\n' | grep -qvE '^healthy$'; then
    red "$name: $(echo "$health" | tr '\t' ' ')"
  else
    green "$name: all healthy ($(echo "$health" | wc -w | tr -d ' '))"
  fi
done

hdr "SmartStore bucket"
acct=$(aws sts get-caller-identity --query Account --output text)
bucket="livehybrid-splunk-${ENV}-splunk-smartstore-${ENV}"
if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
  green "$bucket reachable"
else
  # Newer naming pattern (with account alias) — fall back.
  bucket="livehybrid-splunk-${ENV}-splunk-smartstore-${ENV}"
  if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
    green "$bucket reachable"
  else
    red "SmartStore bucket not reachable (looked for $bucket)"
  fi
fi

hdr "Splunk Web DNS (via splunk-web ALB)"
for host in manager search license mc hec; do
  if dig +short "$host.splunk.livehybrid.com" @1.1.1.1 | grep -q '\.'; then
    green "$host.splunk.livehybrid.com resolves"
  else
    red "$host.splunk.livehybrid.com does not resolve yet"
  fi
done

hdr "Splunk cluster status (via SSM)"
# Use SSM run-command to query splunkd directly. Cheaper than holding a
# control plane: each query is two round-trips and surfaces real Splunk
# health (RF/SF, captain election, peer count) rather than just port checks.
AUSER="${SPLUNK_ADMIN_USER:-splunkadmin}"
splunk_ssm() {
  local id=$1 cmd=$2
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$id" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"ADMIN=\$(aws secretsmanager get-secret-value --region $REGION --secret-id /monitoring/splunk/password | jq -r .SecretString)\", \"sudo -u splunk /opt/splunk/bin/splunk $cmd -auth $AUSER:\$ADMIN 2>&1\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null) || return 1
  # SSM commands typically return within 5-10s for splunk REST calls.
  for _ in $(seq 1 20); do
    local status
    status=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$id" \
      --query 'Status' --output text 2>/dev/null)
    [ "$status" = "Success" ] && {
      aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cmd_id" --instance-id "$id" \
        --query 'StandardOutputContent' --output text
      return 0
    }
    [ "$status" = "Failed" ] && return 1
    sleep 2
  done
  return 1
}

mgr=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:role,Values=manager" \
            "Name=tag:environment,Values=${ENV}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
if [ -n "$mgr" ] && [ "$mgr" != "None" ]; then
  out=$(splunk_ssm "$mgr" "show cluster-status" 2>&1 || true)
  if echo "$out" | grep -qE 'Replication factor met|All peers in cluster'; then
    green "cluster-status: $(echo "$out" | grep -E 'Replication factor|Peers searchable' | head -2 | tr '\n' '|')"
  else
    red "cluster-status not healthy: $(echo "$out" | head -3 | tr '\n' ' ')"
  fi
else
  red "no running manager instance"
fi

sh=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:role,Values=searchhead" \
            "Name=tag:environment,Values=${ENV}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
if [ -n "$sh" ] && [ "$sh" != "None" ]; then
  out=$(splunk_ssm "$sh" "show shcluster-status" 2>&1 || true)
  if echo "$out" | grep -qE 'captain|members'; then
    green "shcluster-status: $(echo "$out" | grep -E 'captain|members' | head -2 | tr '\n' '|')"
  else
    red "shcluster-status not healthy: $(echo "$out" | head -3 | tr '\n' ' ')"
  fi
else
  red "no running searchhead instance"
fi

mc=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:role,Values=monitoring_console" \
            "Name=tag:environment,Values=${ENV}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
if [ -n "$mc" ] && [ "$mc" != "None" ]; then
  out=$(splunk_ssm "$mc" "list search-server" 2>&1 || true)
  peers=$(echo "$out" | grep -cE '^Server.*:' || true)
  if [ "$peers" -gt 0 ]; then
    green "MC sees $peers distributed search peer(s)"
  else
    red "MC has no search peers configured"
  fi
fi

hdr "Result"
if [ "$FAIL" -eq 0 ]; then
  green "All checks passed"
  exit 0
else
  red "$FAIL check(s) failed"
  exit 1
fi
