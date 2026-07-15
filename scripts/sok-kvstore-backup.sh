#!/usr/bin/env bash
# Back up the SOK SHC KV store to S3. Runs from anywhere with kubectl + aws:
#   - `make sok-kvstore-backup env=<env>` (your machine, kubeconfig auth), or
#   - the in-cluster CronJob (kvbackup.tf), which mounts this script and runs
#     with the splunk-kvbackup ServiceAccount (in-cluster auth + IRSA).
#
#   ./scripts/sok-kvstore-backup.sh <env>
#
# The KV store is replicated across all SHC members; we back up from the KV store
# captain (auto-detected, as restore does) so the copy is authoritative and we
# never target a member that is down. Admin password is read INSIDE the pod from
# /mnt/splunk-secrets/password, never on the command line.
#
# Validated end-to-end against a live dev SHC (backup -> S3 SSE-KMS ->
# restore into the KV store captain). Override the target with KVSTORE_POD.
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-kvstore-backup.sh <env>}"
NS="${SOK_NS:-splunk}"
REGION="${AWS_REGION:-eu-west-2}"
BUCKET="livehybrid-splunk-${ENV}-splunk-kvbackup-${ENV}"

# Back up from the KV store captain (auto-detected) rather than a hardcoded
# member, matches restore, and avoids targeting a member that is down. The
# captain is the member whose kvstore-status "This member:" line (the first
# replicationStatus) reports "KV store captain". Override with KVSTORE_POD.
find_kvstore_captain() {
  local p role
  for p in $(kubectl get pods -n "$NS" -o name 2>/dev/null \
               | grep -oE 'splunk-shc-search-head-[0-9]+' | sort -u); do
    role=$(kubectl exec -n "$NS" "$p" -c splunk -- bash -c \
             '/opt/splunk/bin/splunk show kvstore-status -auth admin:$(cat /mnt/splunk-secrets/password) 2>/dev/null | grep -i replicationStatus | head -1' 2>/dev/null || true)
    case "$role" in *"KV store captain"*) echo "$p"; return 0 ;; esac
  done
  return 1
}
POD="${KVSTORE_POD:-$(find_kvstore_captain)}"
[ -n "$POD" ] || { echo "could not find the KV store captain in $NS (set KVSTORE_POD)" >&2; exit 1; }
TS="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="kvstore-${TS}"

kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1 || { echo "pod $POD not found in $NS" >&2; exit 1; }

echo "== backup kvstore on $POD (name=$NAME)"
# Capture the backup's real exit code, the old `... | grep ... || true` masked it.
set +e
OUT=$(kubectl exec -n "$NS" "$POD" -- bash -c \
  "/opt/splunk/bin/splunk backup kvstore -archiveName ${NAME} -auth admin:\$(cat /mnt/splunk-secrets/password)" 2>&1)
rc=$?
set -e
echo "$OUT" | grep -viE "^Defaulted|WARNING" || true
if [ "$rc" -ne 0 ] || echo "$OUT" | grep -qiE 'error|failed|unable|cannot'; then
  echo "backup command FAILED on $POD (rc=$rc)" >&2; exit 1
fi

# splunk writes the archive under var/lib/splunk/kvstorebackup/; find what it made.
REMOTE=$(kubectl exec -n "$NS" "$POD" -- bash -c \
  "ls -1t /opt/splunk/var/lib/splunk/kvstorebackup/*${TS}* 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
[ -n "$REMOTE" ] || { echo "backup archive for ${NAME} not found on $POD" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOCAL="$WORK/$(basename "$REMOTE")"
kubectl cp -n "$NS" "${POD}:${REMOTE}" "$LOCAL"
aws s3 cp "$LOCAL" "s3://${BUCKET}/$(basename "$REMOTE")" --region "$REGION" --only-show-errors

echo "== uploaded s3://${BUCKET}/$(basename "$REMOTE")"
