#!/usr/bin/env bash
# Configure and drive Regulator in ANY SOK estate.
#
#   sok-regulator-bootstrap.sh configure                  verify the target, list scenarios
#   sok-regulator-bootstrap.sh run <scenario> [opts]      launch a search-load run
#   sok-regulator-bootstrap.sh results <run_id>
#   sok-regulator-bootstrap.sh stop <run_id>
#   sok-regulator-bootstrap.sh ls
#
# Run options: --users N  --duration S  --workers N  --fleet NAME  --wait
#
#   sok-regulator-bootstrap.sh run pack-aws-cloudtrail --users 20 --duration 180 --wait
#
# Regulator differs from Stoker in two ways that matter here:
#
#   * It seeds its own first target from REG_SEED_TARGET_URL, so `configure`
#     usually only verifies and probes it. Pass SOK_REG_MGMT_URL (and
#     SOK_SPLUNK_PASSWORD) only when that seeding is absent or wrong.
#   * There are no spec objects. A run names its scenario directly, so
#     `configure` lists what is available rather than creating anything.
#
# Environment (all optional):
#   SOK_NAMESPACE SOK_KUBE_CONTEXT SOK_REG_TARGET_NAME SOK_REG_MGMT_URL
#   SOK_SPLUNK_USER SOK_SPLUNK_PASSWORD SOK_FLEET SOK_REGULATOR_DEPLOY
#
# A worker fleet needs its node group to tolerate the role taint. If workers sit
# Pending, check `kubectl describe pod` for FailedScheduling before anything
# else: a nodeSelector matches LABELS and a toleration matches TAINTS, and they
# are only the same string by coincidence.

source "$(dirname "${BASH_SOURCE[0]}")/sok-bootstrap-common.sh"

DEPLOY="${SOK_REGULATOR_DEPLOY:-regulator}"
DRIVER="$(dirname "${BASH_SOURCE[0]}")/sok_regulator_driver.py"

[ $# -ge 1 ] || die "usage: $(basename "$0") {configure|run <scenario> [opts]|results <id>|stop <id>|ls}"
require_tools
require_deploy "$DEPLOY"

case "$1" in
  configure) say "configuring Regulator in ${SOK_NAMESPACE}" ;;
  run)       say "launching scenario ${2:-}" ;;
esac

# Regulator talks to Splunk's management port, not HEC, so the HEC discovery in
# the common library is not used; pass the Splunk admin password through for the
# case where a target has to be created.
SPLUNK_PASS="${SOK_SPLUNK_PASSWORD:-}"
if [ -z "$SPLUNK_PASS" ]; then
  SPLUNK_PASS="$(kubectl -n splunk get secret "splunk-${SOK_NAMESPACE}-secret" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi

kubectl -n splunk exec -i "deploy/${DEPLOY}" -- \
  sh -c 'export SOK_SPLUNK_PASSWORD="$1" SOK_REG_MGMT_URL="$2" SOK_REG_TARGET_NAME="$3" SOK_FLEET="$4"; shift 4; exec python - "$@"' \
  sh "$SPLUNK_PASS" "${SOK_REG_MGMT_URL:-}" "${SOK_REG_TARGET_NAME:-splunk-local}" \
  "${SOK_FLEET:-k8s}" "$@" < "$DRIVER"
