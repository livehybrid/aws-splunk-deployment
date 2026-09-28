#!/usr/bin/env bash
###############################################################################
# unblock.sh <env> [--delete], recover EKS node groups stuck in DELETE_FAILED
# so `terraform destroy` of the eks layer can complete.
#
# SYMPTOM
#   Error: waiting for EKS Node Group (splunk-sok-dev:general-b-...) delete:
#   unexpected state 'DELETE_FAILED', wanted target ''. last error:
#     AccessDenied: Your worker nodes do not have access to the cluster. Verify
#       if the node instance role is present and correctly configured in the
#       aws-auth ConfigMap.
#     AutoScalingGroupInvalidConfiguration: Couldn't terminate instances in ASG
#       as Terminate process is suspended
#
# WHAT ACTUALLY BLOCKS THE DELETE is the SECOND issue. EKS suspends the backing
# ASG's scaling processes while draining a node group; a delete that fails
# partway leaves them suspended, so every retry fails identically. A bare
# `terraform destroy` retry can never recover on its own, which is why this
# needs a manual (or pre-destroy) resume.
#
# THE AccessDenied LINE IS A RED HERRING as worded. This cluster runs
# authentication_mode = "API" and has no aws-auth ConfigMap at all; that string
# is EKS's generic phrasing for "the node role lost its cluster permissions".
# It happens because terraform-aws-eks puts no ordering edge between
# aws_eks_node_group.this and aws_iam_role_policy_attachment.this (both merely
# reference the node role), so on destroy Terraform can detach
# AmazonEKSWorkerNodePolicy while the node group is still deleting. To avoid the
# race entirely, destroy in two phases (see the advice this script prints).
#
# ⚠ RESUME ONLY `Terminate`. A blanket `aws autoscaling resume-processes` with no
# --scaling-processes resumes ALL of them ("If you omit this property, all
# processes are specified" — ResumeProcesses API reference), and that includes
# `Launch`. EKS suspends `Launch` during a node group delete precisely to stop
# the ASG replacing instances; resume it and the ASG relaunches to desired
# capacity, the new nodes join, and the in-flight drain cordons them on arrival.
# You then get brand new nodes all "Ready,SchedulingDisabled" and nothing able to
# schedule, recycling forever. This script did exactly that once. Do not widen it.
#
# Idempotent and safe to re-run.
#
#   ./scripts/unblock.sh dev             # report, pin Launch down, resume Terminate
#   ./scripts/unblock.sh dev --delete    # also re-issue delete and wait
#
# Then re-run: cd terraform/layers/eks && terraform destroy -var-file=vars/<env>.tfvars
###############################################################################
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: unblock.sh <env> [--delete]}"
MODE="${2:-}"
CLUSTER="splunk-sok-${ENV}"
REGION="${AWS_REGION:-eu-west-2}"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "cluster ${CLUSTER} not found in ${REGION}, nothing to unblock"
  exit 0
fi

NGS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
        --query 'nodegroups[]' --output text 2>/dev/null || true)
if [ -z "$NGS" ]; then
  echo "no node groups on ${CLUSTER}, nothing to unblock"
  exit 0
fi

RESUMED=0
NEEDS_DELETE=0

for NG in $NGS; do
  echo "=== node group: ${NG}"

  STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
             --region "$REGION" --query 'nodegroup.status' --output text 2>/dev/null || echo UNKNOWN)
  echo "    status: ${STATUS}"

  # Health issues explain WHY a delete failed; print them before changing anything.
  ISSUES=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
             --region "$REGION" --query 'nodegroup.health.issues[].code' --output text 2>/dev/null || true)
  [ -n "$ISSUES" ] && echo "    health issues: ${ISSUES}"

  ASGS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
           --region "$REGION" --query 'nodegroup.resources.autoScalingGroups[].name' \
           --output text 2>/dev/null || true)

  for ASG in $ASGS; do
    SUSPENDED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
                  --region "$REGION" --query 'AutoScalingGroups[0].SuspendedProcesses[].ProcessName' \
                  --output text 2>/dev/null || true)
    if [ -n "$SUSPENDED" ]; then
      echo "    ASG ${ASG}: suspended [${SUSPENDED}]"
    else
      echo "    ASG ${ASG}: no suspended processes"
    fi

    # Pin Launch down first on a group that is mid-delete, so the ASG cannot
    # replace instances into the drain (and to undo an earlier blanket resume
    # that already did). Harmless on a group that is not being deleted, but
    # only applied there so a healthy group is never left unable to scale.
    case "$STATUS" in
      DELETING | DELETE_FAILED)
        echo "    ASG ${ASG}: suspending Launch (group is ${STATUS}, must not relaunch)"
        aws autoscaling suspend-processes --auto-scaling-group-name "$ASG" \
          --scaling-processes Launch --region "$REGION" 2>/dev/null || true
        ;;
    esac

    # ONLY Terminate: that is the process named in the
    # AutoScalingGroupInvalidConfiguration error that blocks the delete.
    echo "    ASG ${ASG}: resuming Terminate"
    aws autoscaling resume-processes --auto-scaling-group-name "$ASG" \
      --scaling-processes Terminate --region "$REGION" 2>/dev/null || true
    RESUMED=$((RESUMED + 1))
  done

  if [ "$MODE" = "--delete" ] && { [ "$STATUS" = "DELETE_FAILED" ] || [ "$STATUS" = "DELETING" ]; }; then
    echo "    re-issuing delete for ${NG}"
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
      --region "$REGION" >/dev/null 2>&1 || true
  elif [ "$STATUS" = "DELETE_FAILED" ] || [ "$STATUS" = "DELETING" ] || [ "$STATUS" = "UPDATING" ]; then
    # Resuming without finishing the operation is a trap: the ASG's desired
    # capacity is still non-zero, so it relaunches instances, they join, and
    # EKS's in-flight drain cordons them on arrival. You end up with brand new
    # nodes all "Ready,SchedulingDisabled" and nothing able to schedule.
    echo "    WARNING: ${NG} is ${STATUS} and was left mid-operation. Launch is pinned"
    echo "             down so nothing will relaunch, but the delete is NOT finished."
    echo "             Re-run with --delete to drive it to completion."
    NEEDS_DELETE=$((NEEDS_DELETE + 1))
  fi
done

if [ "$MODE" = "--delete" ]; then
  for NG in $NGS; do
    echo "waiting for ${NG} to reach deleted..."
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
      --region "$REGION" 2>/dev/null \
      || echo "  WARNING: ${NG} did not reach deleted; check its health issues above"
  done
fi

cat <<EOF

resumed Terminate on ${RESUMED} ASG(s). Launch is left suspended on any group
that is mid-delete, so nothing replaces the instances being drained.

Now re-run the destroy IN TWO PHASES, from terraform/layers/eks. Doing the node
groups on their own removes the IAM-detach race that causes this in the first
place: phase 1 has nothing else to run in parallel with, so the node role keeps
its policies until the groups are gone.

  terraform destroy -auto-approve -var-file=vars/${ENV}.tfvars \\
    -target='module.eks.module.eks_managed_node_group'
  terraform destroy -auto-approve -var-file=vars/${ENV}.tfvars

A single-phase destroy works too, it is just the one that keeps losing the race.

If instances still refuse to terminate, force the ASG down first:
  aws autoscaling set-desired-capacity --auto-scaling-group-name <asg> \\
    --desired-capacity 0 --region ${REGION}
EOF

