#!/usr/bin/env bash
# sok-rf-remediate.sh <env>, SOK port of rf-remediate.sh (OPS-10): one-shot fix
# for the SmartStore cold-boot RF stall.
#
# After a cold boot against a populated SmartStore bucket, legacy buckets
# (origin GUIDs from a previous pod generation, every nightly rebuild mints new
# GUIDs) each get registered by a single peer and the CM's RF/SF fixups stall
# with "No possible srcs for replication" / "Missing enough suitable
# candidates". A rolling restart of the cluster peers makes every peer re-scan
# the remote store and register all buckets, after which RF/SF converge. This
# script triggers that restart ONLY when the stall signature is present, so it
# is safe to call from CI after every start.
#
# EC2 original drives the CM over SSM; this drives the CM pod over kubectl exec
# (auth as `admin`, password read in-pod, never on the command line).
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-rf-remediate.sh <env>}"
NS="${SOK_NS:-splunk}"

CM=$(kubectl get pods -n "$NS" -l app.kubernetes.io/name=cluster-manager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$CM" ] || { echo "no ClusterManager pod in $NS, run: make kubeconfig env=$ENV" >&2; exit 1; }

cm_exec() { # run a command in the CM pod with the in-pod admin credential expanded
  kubectl exec -n "$NS" "$CM" -- bash -c "$1" 2>/dev/null || true
}

STATUS=$(cm_exec '/opt/splunk/bin/splunk show cluster-status -auth admin:$(cat /mnt/splunk-secrets/password) 2>/dev/null | head -8')
if ! grep -qi "factor not met" <<<"$STATUS"; then
  echo "RF/SF already met (or cluster-status unavailable); nothing to do"
  exit 0
fi
if grep -qi "rolling restart" <<<"$STATUS"; then
  echo "rolling restart already in progress; letting it finish"
  exit 0
fi

FIXUPS=$(cm_exec 'curl -sk -m 30 -u "admin:$(cat /mnt/splunk-secrets/password)" "https://localhost:8089/services/cluster/manager/fixup?level=replication_factor&output_mode=json&count=100"')
if ! grep -qE "No possible srcs for replication|Missing enough suitable candidates" <<<"$FIXUPS"; then
  echo "RF not met but no stall signature in fixup reasons; not restarting (likely still converging)"
  exit 0
fi

echo "RF fixups stalled on legacy SmartStore buckets; triggering rolling restart of cluster peers"
cm_exec '/opt/splunk/bin/splunk rolling-restart cluster-peers -auth admin:$(cat /mnt/splunk-secrets/password) 2>&1 | grep -v WARNING'
echo "== rolling restart requested; verify with: make sok-health env=$ENV"
