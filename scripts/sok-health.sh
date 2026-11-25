#!/usr/bin/env bash
# SOK-side health checks (deployment_model=sok), the kubectl-exec analogue of
# cluster-health.sh. Auth as `admin` (the operator's hardcoded user, NOT the
# EC2 estate's splunkadmin), password read INSIDE the pod from
# /mnt/splunk-secrets/password so it never lands on the command line.
#
#   ./scripts/sok-health.sh <env>            e.g. dev
#
# SHAPE-AGNOSTIC: discovers whatever CRs exist rather than hardcoding the dev
# single-site names, so it validates both the dev shape (single IndexerCluster +
# Standalone SH) and the prod shape (per-site IndexerClusters + SearchHeadCluster).
#
# Checks: every CR phase Ready; indexer cluster RF/SF + searchable + peers Up
# (via the ClusterManager); Standalone and/or SHC KV store ready (+ the SHC KV
# store captain); licence stack present. REST reads use curl to splunkd, NOT
# `splunk _internal call`, the latter returns EMPTY for some endpoints (e.g.
# licenser/licenses), which faked a "no licence" failure. Needs kubectl pointed
# at the cluster (make kubeconfig env=<env>).
set -uo pipefail
export AWS_PAGER=""

ENV="${1:?usage: sok-health.sh <env>}"
NS="${SOK_NS:-splunk}"
FAIL=0

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
hdr()   { printf '\n=== %s ===\n' "$*"; }

kubectl get ns "$NS" >/dev/null 2>&1 || {
  echo "namespace $NS not reachable, run: make kubeconfig env=$ENV" >&2; exit 1; }

# splunk CLI inside a pod; admin auth resolved from the in-pod secret.
splx() { local pod=$1; shift
  kubectl exec -n "$NS" "$pod" -- bash -c \
    "/opt/splunk/bin/splunk $* -auth admin:\$(cat /mnt/splunk-secrets/password)" 2>/dev/null || true
}
# REST GET inside a pod (JSON) via curl to splunkd, reliable where
# `splunk _internal call` returns empty (e.g. the licenser endpoints).
curlx() { local pod=$1 path=$2
  kubectl exec -n "$NS" "$pod" -- bash -c \
    "curl -sk -u admin:\$(cat /mnt/splunk-secrets/password) 'https://localhost:8089${path}?output_mode=json&count=0'" 2>/dev/null || true
}
# First pod carrying an app.kubernetes.io/name role label (shape-agnostic).
pod_by_name() { kubectl get pods -n "$NS" -l "app.kubernetes.io/name=$1" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# --- CR phases: iterate whatever exists (single-site OR multisite/SHC) ---
hdr "Custom resource phases"
any_cr=0
for kind in clustermanager licensemanager monitoringconsole indexercluster standalone searchheadcluster; do
  for name in $(kubectl get "$kind" -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    any_cr=1
    ph=$(kubectl get "$kind/$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    # OPS-13: the MonitoringConsole is operational-visibility, not data plane, and
    # its readiness depends on the (currently un-wired) Apply automation, so a
    # not-Ready MC is a WARNING, not a health failure. Promote back to red once the
    # MC reliably reaches Ready (Apply automation wired via A1 + SplunkAdmins).
    if [ "$ph" = "Ready" ]; then
      green "$kind/$name Ready"
    elif [ "$kind" = monitoringconsole ]; then
      warn "$kind/$name phase=${ph:-missing} (non-fatal, see OPS-13)"
    else
      red "$kind/$name phase=${ph:-missing}"
    fi
  done
done
[ "$any_cr" = 0 ] && red "no Splunk CRs found in $NS"

# --- Indexer cluster (via the ClusterManager, always named cm, any shape) ---
hdr "Indexer cluster (via ClusterManager)"
CM=$(pod_by_name cluster-manager)
if [ -z "$CM" ]; then red "no ClusterManager pod"; else
  OUT=$(splx "$CM" show cluster-status --verbose)
  echo "$OUT" | grep -qiE 'replication factor met.*yes' && green "replication factor met" || red "replication factor NOT met"
  echo "$OUT" | grep -qiE 'search factor met.*yes'      && green "search factor met"      || red "search factor NOT met"
  echo "$OUT" | grep -qiE 'all data is searchable.*yes' && green "all data searchable"    || red "data NOT fully searchable"
  UP=$(echo "$OUT" | grep -cE '^[[:space:]]*Status[[:space:]]+Up\b' || true)
  [ "$UP" -gt 0 ] && green "indexer peers Up: $UP" || red "no indexer peers Up"
fi

# --- Search tier + KV store: Standalone (dev) and/or SHC (prod) ---
hdr "Search tier + KV store"
SH=$(pod_by_name standalone)
if [ -n "$SH" ]; then
  KV=$(splx "$SH" show kvstore-status)
  echo "$KV" | grep -qE 'status[[:space:]]*:[[:space:]]*ready' && green "Standalone KV store ready" || red "Standalone KV store NOT ready"
fi
# SHC members are named splunk-shc-search-head-N by the operator.
SHC_PODS=$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep -oE 'splunk-shc-search-head-[0-9]+' | sort -u)
if [ -n "$SHC_PODS" ]; then
  cnt=$(echo "$SHC_PODS" | wc -w | tr -d ' ')
  ready=0; captain=""
  for p in $SHC_PODS; do
    st=$(splx "$p" show kvstore-status)
    echo "$st" | grep -qE 'status[[:space:]]*:[[:space:]]*ready' && ready=$((ready+1))
    echo "$st" | grep -i replicationStatus | head -1 | grep -qi 'KV store captain' && captain="$p"
  done
  [ "$ready" = "$cnt" ] && green "SHC KV store ready on all $cnt members" || red "SHC KV store ready on $ready/$cnt members"
  [ -n "$captain" ] && green "SHC KV store captain: $captain" || red "no SHC KV store captain found"
fi
[ -z "$SH$SHC_PODS" ] && red "no Standalone or SHC search-head pods found"

# --- Licence (via LicenseManager, curl REST, asserts an entry) ---
hdr "Licence (via LicenseManager)"
LM=$(pod_by_name license-manager)
if [ -z "$LM" ]; then red "no LicenseManager pod"; else
  LIC=$(curlx "$LM" /services/licenser/licenses)
  if echo "$LIC" | grep -q '"entry"'; then
    N=$(echo "$LIC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("entry",[])))' 2>/dev/null || echo 0)
    [ "${N:-0}" -ge 1 ] && green "licence stack present ($N entr$([ "$N" = 1 ] && echo y || echo ies))" || red "no licence entries"
  else
    red "licence REST returned no entry key (auth failure, the silent-401 trap)"
  fi
fi

# --- App Framework drift (GH #893): removed-but-still-installed apps ---
# The App Framework NEVER uninstalls an app (splunk/splunk-operator#893). When an
# app is dropped from the S3 repo the operator flips its appDeploymentInfo
# repoState to 2 (Deleted) but leaves the bits on the pod, so stale config keeps
# running. Surface those orphans from each app-bearing CR's status so they can be
# retired DELIBERATELY: ship a same-named tombstone package whose
# default/app.conf carries `[install]\nstate = disabled` (the operator redeploys
# on the checksum change and Splunk disables it), then drop the tgz. Non-fatal,
# this is drift to clean up, not a data-plane failure, so it warns, not reds.
hdr "App Framework drift (GH #893)"
drift=0
# Only these CRs carry an appRepo (idx apps ride the CM; LM/IndexerCluster none).
for kind in clustermanager monitoringconsole standalone searchheadcluster; do
  for name in $(kubectl get "$kind" -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    orphans=$(kubectl get "$kind/$name" -n "$NS" -o json 2>/dev/null | python3 -c '
import json,sys
try: st = json.load(sys.stdin)
except Exception: sys.exit(0)
ctx = (st.get("status") or {}).get("appContext") or {}
for src, info in (ctx.get("appSrcDeployStatus") or {}).items():
    for a in (info.get("appDeploymentInfo") or []):
        if a.get("repoState") == 2:  # 2 == RepoStateDeleted
            print("%s/%s" % (src, a.get("appName", "?")))
' 2>/dev/null)
    for o in $orphans; do
      warn "$kind/$name orphaned app still installed (repoState=Deleted): $o, retire via state=disabled tombstone"
      drift=$((drift+1))
    done
  done
done
[ "$drift" = 0 ] && green "no App Framework orphans (nothing removed-from-repo-but-installed)"

hdr "Summary"
if [ "$FAIL" -eq 0 ]; then
  green "all SOK health checks passed"
  [ "$drift" -gt 0 ] && warn "$drift App Framework orphan(s) to retire (non-fatal, see GH #893 above)"
  exit 0
else red "$FAIL check(s) failed"; exit 1; fi
