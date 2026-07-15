#!/usr/bin/env bash
###############################################################################
# sok-apply-guard.sh <env> [target ...] — plan+apply the sok layer with a
# LIVE-RESTART GUARDRAIL (invoked by `make sok-apply`).
#
# Terraform happily updates Splunk CRs in place, but the operator reconciles
# those updates into POD RESTARTS: rolling (one member at a time, quorum-safe)
# on the SHC / per-site indexer StatefulSets, and a brief OUTAGE on the
# singleton CRs (CM, LM, MC, deployer — one pod each). This script:
#   1. plans and saves the plan,
#   2. inspects the plan JSON for Splunk-CR changes,
#   3. if the target cluster is LIVE, prints exactly which CRs will roll and
#      what that means, and refuses to continue without CONFIRM=ROLL (or an
#      interactive "ROLL" confirmation),
#   4. applies the SAVED plan (what you reviewed is what runs).
#
# Staged rollout (cross-CR ordering — e.g. SHC first, CM last) is supported by
# passing terraform -target addresses:
#   make sok-apply env=prod target='kubectl_manifest.search_head_cluster[0]'
#   make sok-health env=prod
#   make sok-apply env=prod target='kubectl_manifest.license_manager'
#   ...
# Fresh/absent clusters skip the prompt — nothing is running to disturb.
###############################################################################
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-apply-guard.sh <env> [terraform -target address ...]}"
shift || true
TARGETS=()
for t in "$@"; do TARGETS+=("-target=$t"); done

REGION="${AWS_REGION:-eu-west-2}"
LAYER_DIR="$(cd "$(dirname "$0")/../terraform/layers/sok" && pwd)"
cd "$LAYER_DIR"

export TF_WORKSPACE="$ENV"
terraform init -input=false -reconfigure -backend-config="conf/${ENV}.backend.conf" >/dev/null

PLAN="plan-guard-${ENV}.tfplan"
trap 'rm -f "$PLAN"' EXIT
terraform plan -input=false -lock-timeout=5m -var-file="vars/${ENV}.tfvars" \
  ${TARGETS[@]+"${TARGETS[@]}"} -out="$PLAN" >/dev/null

# Which Splunk CRs does this plan touch (update/replace/delete)?
CHANGED=$(terraform show -json "$PLAN" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hits = []
CRS = {"cluster_manager","license_manager","monitoring_console",
       "search_head","search_head_cluster","indexer_cluster","indexer_cluster_site"}
for rc in d.get("resource_changes", []):
    acts = rc.get("change", {}).get("actions", [])
    if rc.get("type") == "kubectl_manifest" and rc.get("name") in CRS \
       and ("update" in acts or "delete" in acts):
        hits.append(rc["address"])
print(" ".join(sorted(hits)))
')

if [ -n "$CHANGED" ]; then
  # Is the cluster live? (Absent cluster => fresh start, nothing to disturb.)
  LIVE=0
  if aws eks describe-cluster --name "splunk-sok-${ENV}" --region "$REGION" >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "splunk-sok-${ENV}" --region "$REGION" >/dev/null 2>&1 || true
    if kubectl get pods -n splunk --no-headers 2>/dev/null | grep -q Running; then LIVE=1; fi
  fi

  if [ "$LIVE" = "1" ]; then
    echo "⚠  This apply changes LIVE Splunk CRs — the operator will restart pods:"
    for a in $CHANGED; do
      case "$a" in
        *search_head_cluster*) echo "   - $a  (SHC: ROLLING, one member at a time — quorum kept; in-flight searches on the rolling member die; the deployer pod also cycles)";;
        *indexer_cluster*)     echo "   - $a  (indexers: ROLLING per StatefulSet; peers re-register with the CM as they return)";;
        *cluster_manager*)     echo "   - $a  (CM: SINGLETON — brief outage; searches continue, bundle pushes/fixups pause)";;
        *)                     echo "   - $a  (SINGLETON — brief outage of that component)";;
      esac
    done
    echo "   Stage across CRs with: make sok-apply env=${ENV} target='<address>' (SHC first, CM last)."
    if [ "${CONFIRM:-}" = "ROLL" ]; then
      echo "   CONFIRM=ROLL supplied — continuing."
    elif [ -t 0 ]; then
      read -r -p "   Type ROLL to continue (anything else aborts): " ANSWER
      [ "$ANSWER" = "ROLL" ] || { echo "aborted — plan file discarded"; exit 1; }
    else
      echo "   Non-interactive without CONFIRM=ROLL — aborting (plan discarded)."
      exit 1
    fi
  fi
fi

terraform apply -input=false -lock-timeout=5m "$PLAN"
