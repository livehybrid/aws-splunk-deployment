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
# ⚠ The upload MUST send the SSE-KMS headers explicitly. The bucket policy
# (modules/s3_bucket_policy) carries two Deny statements on s3:PutObject:
#   DenyUnencrypted  StringNotEquals s3:x-amz-server-side-encryption      aws:kms
#   DenyWrongKMS     StringNotEquals s3:x-amz-server-side-encryption-aws-kms-key-id <arn>
# StringNotEquals is TRUE when the condition key is ABSENT, and a plain
# `aws s3 cp` sends no encryption headers — it relies on the bucket's default
# encryption, which S3 applies AFTER evaluating the policy. So both Denies fire
# and the put is refused with AccessDenied however correct the IAM role is.
# Send them explicitly, with the FULL key ARN (an alias or bare key id would not
# StringEquals the ARN in the policy and would be denied just the same).
# ---------------------------------------------------------------------------- #
KMS_ARN="${KVBACKUP_KMS_ARN:-}"
if [ -z "$KMS_ARN" ]; then
  KMS_ARN=$(aws s3api get-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
              --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
              --output text 2>/dev/null || true)
  [ "$KMS_ARN" = "None" ] && KMS_ARN=""
fi
[ -n "$KMS_ARN" ] || { echo "FATAL: no KMS key. Set KVBACKUP_KMS_ARN (Terraform passes it on the CronJob)." >&2; exit 1; }
echo "== sse-kms key: ${KMS_ARN}"

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
TS="$(date -u +%Y%m%dT%H%M%SZ)"
# Timestamp FIRST, source pod second. The pod identifies the SHC and the member
# it came from (the old plain "kvstore-<ts>" said nothing about origin, which is
# unreadable once more than one SHC backs up to the same bucket). Order matters:
# restore selects the newest with `sort | tail -1`, and a fixed-width ISO stamp in
# field 2 keeps that lexical sort chronological. Putting the SHC first would have
# sorted by cluster name and silently restored the wrong backup.
NAME="kvstore-${TS}-${POD#splunk-}"

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
aws s3 cp "$LOCAL" "s3://${BUCKET}/$(basename "$REMOTE")" --region "$REGION" \
  --sse aws:kms --sse-kms-key-id "$KMS_ARN" --only-show-errors

echo "== uploaded s3://${BUCKET}/$(basename "$REMOTE")"