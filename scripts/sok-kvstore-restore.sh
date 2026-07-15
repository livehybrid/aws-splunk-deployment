#!/usr/bin/env bash
# Restore the SOK SHC KV store from the latest S3 backup (or a named one).
#   ./scripts/sok-kvstore-restore.sh <env> [archive-basename]
#
# Used after a fresh SHC comes up (start workflow / cutover) to re-seat the KV
# store content. Pulls the archive from S3, copies it into the SHC member, and
# runs `splunk restore kvstore` there. Password read INSIDE the pod.
#
# Validated against a live dev SHC: `splunk restore kvstore` must run
# on the **KV store captain**, which is NOT necessarily the SHC captain — on the
# test SHC the SHC captain was search-head-0 while the KV store captain was
# search-head-2, and restore only succeeds on the latter (it replicates to the
# other members). So we auto-detect the KV store captain rather than hardcode a
# member. Override with KVSTORE_POD to force a specific pod.
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-kvstore-restore.sh <env> [archive-basename]}"
NS="${SOK_NS:-splunk}"
REGION="${AWS_REGION:-eu-west-2}"
BUCKET="livehybrid-splunk-${ENV}-splunk-kvbackup-${ENV}"

# The member whose kvstore-status reports "KV store captain" — restore targets
# it (Splunk replicates the restored collections to the other SHC members).
find_kvstore_captain() {
  local p role
  for p in $(kubectl get pods -n "$NS" -o name 2>/dev/null \
               | grep -oE 'splunk-shc-search-head-[0-9]+' | sort -u); do
    # `splunk show kvstore-status` lists EVERY member's replicationStatus (the
    # "KV store members:" section), and the captain always appears there — so
    # match only the FIRST line, which is the "This member:" section (i.e. THIS
    # pod's own role). head -1 is what distinguishes the captain from a member.
    role=$(kubectl exec -n "$NS" "$p" -c splunk -- bash -c \
             '/opt/splunk/bin/splunk show kvstore-status -auth admin:$(cat /mnt/splunk-secrets/password) 2>/dev/null | grep -i replicationStatus | head -1' 2>/dev/null || true)
    case "$role" in *"KV store captain"*) echo "$p"; return 0 ;; esac
  done
  return 1
}
POD="${KVSTORE_POD:-$(find_kvstore_captain)}"
[ -n "$POD" ] || { echo "could not find the KV store captain in $NS (set KVSTORE_POD)" >&2; exit 1; }

ARCHIVE="${2:-}"
if [ -z "$ARCHIVE" ]; then
  ARCHIVE=$(aws s3 ls "s3://${BUCKET}/" --region "$REGION" 2>/dev/null | awk '{print $4}' | grep '^kvstore-' | sort | tail -1)
  [ -n "$ARCHIVE" ] || { echo "no kvstore-* backups in s3://${BUCKET}/" >&2; exit 1; }
fi
echo "== restoring $ARCHIVE onto $POD"

kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1 || { echo "pod $POD not found in $NS" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
aws s3 cp "s3://${BUCKET}/${ARCHIVE}" "$WORK/${ARCHIVE}" --region "$REGION" --only-show-errors
kubectl exec -n "$NS" "$POD" -- bash -c 'mkdir -p /opt/splunk/var/lib/splunk/kvstorebackup' 2>/dev/null || true
kubectl cp -n "$NS" "$WORK/${ARCHIVE}" "${POD}:/opt/splunk/var/lib/splunk/kvstorebackup/${ARCHIVE}"

# Capture the restore's real exit code — the old `... | grep ... || true` masked
# it, so a failed restore reported success.
set +e
OUT=$(kubectl exec -n "$NS" "$POD" -- bash -c \
  "/opt/splunk/bin/splunk restore kvstore -archiveName ${ARCHIVE} -auth admin:\$(cat /mnt/splunk-secrets/password)" 2>&1)
rc=$?
set -e
echo "$OUT" | grep -viE "^Defaulted|WARNING" || true
if [ "$rc" -ne 0 ] || echo "$OUT" | grep -qiE 'error|failed|unable|cannot'; then
  echo "== restore FAILED on $POD (rc=$rc) — inspect 'splunk show kvstore-status'" >&2
  exit 1
fi
echo "== restore OK on $POD; verify with 'splunk show kvstore-status'"
