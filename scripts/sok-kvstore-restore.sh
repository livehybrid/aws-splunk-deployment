#!/usr/bin/env bash
# Restore the SOK SHC KV store from the latest S3 backup (or a named one).
#   ./scripts/sok-kvstore-restore.sh <env> [archive-basename]
#
# Used after a fresh SHC comes up (start workflow / cutover) to re-seat the KV
# store content. Pulls the archive from S3, copies it into the SHC member, and
# runs `splunk restore kvstore` there. Password read INSIDE the pod.
#
# Validated against a live dev SHC: `splunk restore kvstore` must run
# on the **KV store captain**, which is NOT necessarily the SHC captain, on the
# test SHC the SHC captain was search-head-0 while the KV store captain was
# search-head-2, and restore only succeeds on the latter (it replicates to the
# other members). So we auto-detect the KV store captain rather than hardcode a
# member. Override with KVSTORE_POD to force a specific pod.
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-kvstore-restore.sh <env> [archive-basename]}"
NS="${SOK_NS:-splunk}"
REGION="${AWS_REGION:-eu-west-2}"
# ---------------------------------------------------------------------------- #
# Bucket. NOT derived from a hardcoded prefix any more: the account layer names
# it "${local.account_name}-splunk-kvbackup-<env>" and sok/kvbackup.tf grants IAM
# on exactly that, but both scripts had a stale pre-fork "livehybrid-..." literal,
# so the upload targeted a bucket the role has no policy for (and which may not
# exist). Terraform passes the real name in as KVBACKUP_BUCKET; the CLI fallback
# keeps `make` usable. Wrong here = AccessDenied at the very last step, after the
# backup has already run.
# ---------------------------------------------------------------------------- #
BUCKET="${KVBACKUP_BUCKET:-}"
if [ -z "$BUCKET" ]; then
  echo "== KVBACKUP_BUCKET unset, discovering the kvbackup bucket in ${REGION}" >&2
  BUCKET=$(aws s3api list-buckets --region "$REGION" \
             --query "Buckets[?contains(Name, 'splunk-kvbackup-${ENV}')].Name | [0]" \
             --output text 2>/dev/null || true)
  [ "$BUCKET" = "None" ] && BUCKET=""
fi
[ -n "$BUCKET" ] || { echo "FATAL: no kvbackup bucket. Set KVBACKUP_BUCKET (Terraform passes it on the CronJob)." >&2; exit 1; }
echo "== bucket: s3://${BUCKET}"

# ---------------------------------------------------------------------------- #
# Find the KV store captain.
#
# ⚠ WAS BROKEN AND SILENT. The old discovery grepped pod names for
# 'splunk-shc-search-head-[0-9]+', which only matches a SearchHeadCluster CR
# literally named "shc". Since the multi-SHC refactor the CRs are shc-<key>, so
# the pods are splunk-shc-<key>-search-head-N and NOTHING matched. Worse, the
# result fed `POD="${KVSTORE_POD:-$(find_kvstore_captain)}"`, and under `set -e`
# an assignment inherits its command substitution's exit status — so the script
# died ON THAT LINE, before the "could not find the captain" echo below it could
# ever run. A failing CronJob with completely empty logs.
#
# Now: select by the operator's own label, which is shape-independent, and never
# let a discovery failure exit without saying why.
# ---------------------------------------------------------------------------- #
list_sh_pods() {
  if [ -n "${KVSTORE_SHC:-}" ]; then
    kubectl get pods -n "$NS" \
      -l "app.kubernetes.io/instance=splunk-shc-${KVSTORE_SHC}-search-head" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
  else
    kubectl get pods -n "$NS" \
      -l "app.kubernetes.io/name=search-head" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
  fi
}

find_kvstore_captain() {
  local p role
  for p in $(list_sh_pods); do
    echo "   probing $p" >&2
    role=$(kubectl exec -n "$NS" "$p" -c splunk -- bash -c \
             '/opt/splunk/bin/splunk show kvstore-status -auth admin:$(cat /mnt/splunk-secrets/password) 2>/dev/null | grep -i replicationStatus | head -1' 2>/dev/null || true)
    case "$role" in *"KV store captain"*) echo "$p"; return 0 ;; esac
  done
  return 1
}

if [ -n "${KVSTORE_POD:-}" ]; then
  POD="$KVSTORE_POD"
  echo "== using KVSTORE_POD override: $POD"
else
  echo "== searching for the KV store captain in ns=${NS}${KVSTORE_SHC:+ (shc=${KVSTORE_SHC})}"
  SH_PODS=$(list_sh_pods || true)
  if [ -z "$SH_PODS" ]; then
    echo "FATAL: no search-head pods matched in ns=${NS}." >&2
    echo "       Pods present:" >&2
    kubectl get pods -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name >&2 2>/dev/null || true
    echo "       Set KVSTORE_SHC=<shc-key> or KVSTORE_POD=<pod> to target explicitly." >&2
    exit 1
  fi
  echo "== candidates:"; echo "$SH_PODS" | sed 's/^/   /'
  # set +e so a non-zero return CANNOT kill the script before the message below.
  set +e
  POD="$(find_kvstore_captain)"
  set -e
fi
[ -n "$POD" ] || {
  echo "FATAL: none of the search-head pods reported 'KV store captain'." >&2
  echo "       Check: kubectl exec -n ${NS} <pod> -- /opt/splunk/bin/splunk show kvstore-status" >&2
  echo "       Then force one with KVSTORE_POD=<pod>." >&2
  exit 1
}
echo "== KV store captain: $POD"

ARCHIVE="${2:-}"
if [ -z "$ARCHIVE" ]; then
  # Archives are kvstore-<ISO-ts>-<pod>. The timestamp is field 2 and fixed
  # width, so a lexical sort is chronological. With more than one SHC in the
  # bucket, KVSTORE_SHC narrows to that cluster's own backups — without it you
  # would restore whichever SHC happened to run last.
  ARCHIVE=$(aws s3 ls "s3://${BUCKET}/" --region "$REGION" 2>/dev/null \
              | awk '{print $4}' | grep '^kvstore-' \
              | { [ -n "${KVSTORE_SHC:-}" ] && grep -- "-shc-${KVSTORE_SHC}-" || cat; } \
              | sort | tail -1)
  [ -n "$ARCHIVE" ] || { echo "no kvstore-* backups in s3://${BUCKET}/" >&2; exit 1; }
fi
echo "== restoring $ARCHIVE onto $POD"

kubectl get pod "$POD" -n "$NS" >/dev/null 2>&1 || { echo "pod $POD not found in $NS" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
aws s3 cp "s3://${BUCKET}/${ARCHIVE}" "$WORK/${ARCHIVE}" --region "$REGION" --only-show-errors
kubectl exec -n "$NS" "$POD" -- bash -c 'mkdir -p /opt/splunk/var/lib/splunk/kvstorebackup' 2>/dev/null || true
kubectl cp -n "$NS" "$WORK/${ARCHIVE}" "${POD}:/opt/splunk/var/lib/splunk/kvstorebackup/${ARCHIVE}"

# Capture the restore's real exit code, the old `... | grep ... || true` masked
# it, so a failed restore reported success.
set +e
OUT=$(kubectl exec -n "$NS" "$POD" -- bash -c \
  "/opt/splunk/bin/splunk restore kvstore -archiveName ${ARCHIVE} -auth admin:\$(cat /mnt/splunk-secrets/password)" 2>&1)
rc=$?
set -e
echo "$OUT" | grep -viE "^Defaulted|WARNING" || true
if [ "$rc" -ne 0 ] || echo "$OUT" | grep -qiE 'error|failed|unable|cannot'; then
  echo "== restore FAILED on $POD (rc=$rc), inspect 'splunk show kvstore-status'" >&2
  exit 1
fi
echo "== restore OK on $POD; verify with 'splunk show kvstore-status'"