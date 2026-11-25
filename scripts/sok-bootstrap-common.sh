#!/usr/bin/env bash
# Shared plumbing for sok-stoker-bootstrap.sh and sok-regulator-bootstrap.sh.
#
# PORTABLE BY DESIGN. Nothing here is tied to one environment: no account
# number, no cluster name, no image tag. Every environment-specific value is an
# input with a sensible default discovered from the cluster, so the same scripts
# run unchanged against any deployment of this repo.
#
# Inputs (all optional):
#   SOK_NAMESPACE       Kubernetes namespace          (default: splunk)
#   SOK_KUBE_CONTEXT    kubectl context               (default: current)
#   SOK_HEC_URL         HEC endpoint for generated data
#                       (default: the in-cluster indexer Service, discovered)
#   SOK_HEC_TOKEN       HEC token
#                       (default: read from the operator's global secret)
#   SOK_INDEX           destination index             (default: main)
#
# PRIVATE EKS ENDPOINTS: an estate whose cluster endpoint is private is only
# reachable through a bastion tunnel, and kubectl needs to be told about it:
#
#   ssh -D 1080 -N <bastion> &            # open the SOCKS tunnel
#   export HTTPS_PROXY=socks5://localhost:1080
#
# This is the same tunnel the Terraform kubernetes/helm/kubectl providers dial
# via var.k8s_proxy_url. Without it every kubectl call fails, so these scripts
# check reachability FIRST and say so, rather than blaming a missing deployment.
#
# Sourced, not executed.

set -euo pipefail

SOK_NAMESPACE="${SOK_NAMESPACE:-splunk}"
SOK_INDEX="${SOK_INDEX:-main}"
# NO ARRAYS ANYWHERE IN THIS FILE, deliberately.
#
# macOS still ships Bash 3.2, which under `set -u` treats the expansion of an
# EMPTY array as an unbound variable and aborts. Bash 4.4+ does not. The usual
# ${A[@]+"${A[@]}"} workaround is fiddly to get right at every call site and one
# missed spot breaks only on the Mac, so the context is carried as a plain
# string and applied with an if instead. Nothing here needs an array.

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# Every cluster call goes through this, so the namespace and context are applied
# in exactly one place and cannot be forgotten at a call site.
kube() {
  if [ -n "${SOK_KUBE_CONTEXT:-}" ]; then
    kubectl --context "$SOK_KUBE_CONTEXT" --namespace "$SOK_NAMESPACE" "$@"
  else
    kubectl --namespace "$SOK_NAMESPACE" "$@"
  fi
}

# Cluster-scoped calls: no namespace, same context handling.
kube_raw() {
  if [ -n "${SOK_KUBE_CONTEXT:-}" ]; then
    kubectl --context "$SOK_KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

require_tools() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
}

# The deployment must exist before there is anything to configure. Named as an
# argument so a renamed release still works.
# Prove the API server is reachable BEFORE anything else, and keep kubectl's own
# error. Previously a dead SOCKS tunnel surfaced as "no deployment/<x>, deploy
# the sok layer first", which is a different problem in a different place and
# costs whoever reads it real time.
require_cluster() {
  local err rc
  # Two traps here, both of which made this preflight cry wolf:
  #
  #   * /healthz, NOT /readyz. On an EKS managed control plane /readyz hangs
  #     until the client timeout; /healthz answers immediately.
  #   * a generous timeout. The kubeconfig authenticates through an exec
  #     credential plugin (`aws eks get-token`), and the AWS CLI alone can take
  #     tens of seconds to start on a loaded machine. A tight timeout measures
  #     the credential helper, not the cluster.
  local probe_timeout="${SOK_PROBE_TIMEOUT:-90s}"
  err="$(kube_raw --request-timeout="$probe_timeout" get --raw /healthz 2>&1)" && return 0
  rc=$?
  printf '\033[1;31merror: cannot reach the Kubernetes API server\033[0m\n' >&2
  printf '  kubectl said: %s\n' "$(printf '%s' "$err" | head -2 | tr '\n' ' ')" >&2
  case "$err" in
    *"no such host"*|*"connection refused"*|*timeout*|*"i/o timeout"*|*EOF*|*"dial tcp"*)
      printf '\n  A private EKS endpoint needs the bastion tunnel. Typically:\n' >&2
      printf '    ssh -D 1080 -N <bastion> &\n' >&2
      printf '    export HTTPS_PROXY=socks5://localhost:1080\n' >&2
      printf '  HTTPS_PROXY is currently: %s\n' "${HTTPS_PROXY:-<unset>}" >&2
      ;;
    *Unauthorized*|*forbidden*|*credential*)
      printf '\n  Reached the API but were refused. Refresh your credentials\n' >&2
      printf '  (aws sso login / aws eks update-kubeconfig).\n' >&2
      ;;
  esac
  exit "${rc:-1}"
}

require_deploy() {
  local name="$1" err
  if ! err="$(kube get deploy "$name" 2>&1 >/dev/null)"; then
    die "cannot read deployment/$name in namespace ${SOK_NAMESPACE}: ${err:-unknown error}
  If that is a not-found, deploy the sok layer or set SOK_NAMESPACE."
  fi
  local ready
  ready="$(kube get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 1 ] || die "deployment/$name has no ready replica yet; wait for the rollout"
}

# The operator names its global secret splunk-<namespace>-secret and puts the
# HEC token in it. Discovered rather than passed so this works on any estate.
discover_hec_token() {
  if [ -n "${SOK_HEC_TOKEN:-}" ]; then printf '%s' "$SOK_HEC_TOKEN"; return; fi
  local tok
  tok="$(kube get secret "splunk-${SOK_NAMESPACE}-secret" -o jsonpath='{.data.hec_token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$tok" ] || die "could not read hec_token from splunk-${SOK_NAMESPACE}-secret; set SOK_HEC_TOKEN"
  printf '%s' "$tok"
}

# Prefer whatever Service actually fronts HEC. The estate creates a dedicated
# one; fall back to the operator's indexer Service, whose name changes between
# single-site and multisite, so it is discovered rather than assumed.
discover_hec_url() {
  if [ -n "${SOK_HEC_URL:-}" ]; then printf '%s' "$SOK_HEC_URL"; return; fi
  local svc
  for candidate in splunk-hec-indexers splunk-idxc-indexer-service; do
    if kube get svc "$candidate" >/dev/null 2>&1; then svc="$candidate"; break; fi
  done
  if [ -z "${svc:-}" ]; then
    svc="$(kube get svc -o name 2>/dev/null | sed 's|service/||' | grep -E 'indexer-service$' | head -1 || true)"
  fi
  [ -n "${svc:-}" ] || die "could not find a HEC Service in ${SOK_NAMESPACE}; set SOK_HEC_URL"
  printf 'https://%s.%s.svc:8088' "$svc" "$SOK_NAMESPACE"
}

# Run a python driver INSIDE the control-plane pod. Deliberately not
# kubectl port-forward: the tunnel dies whenever the pod is rescheduled, and on
# a spot-backed node group that is often. kubectl exec has no --env, so values
# ride in as positional args of a shell wrapper that exports them.
exec_driver() {
  local deploy="$1" script="$2"; shift 2
  kube exec -i "deploy/${deploy}" -- \
    sh -c 'export SOK_HEC_TOKEN="$1" SOK_HEC_URL="$2" SOK_INDEX="$3"; shift 3; exec python - "$@"' \
    sh "$(discover_hec_token)" "$(discover_hec_url)" "$SOK_INDEX" "$@" < "$script"
}
