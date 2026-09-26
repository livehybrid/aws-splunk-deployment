#!/usr/bin/env bash
# Configure and drive Stoker in ANY SOK estate.
#
#   sok-stoker-bootstrap.sh configure                    HEC target + the standard specs
#   sok-stoker-bootstrap.sh run <spec-name> [--wait]     launch, optionally wait + report
#   sok-stoker-bootstrap.sh results <run_id>
#   sok-stoker-bootstrap.sh stop <run_id>
#   sok-stoker-bootstrap.sh ls
#
# Specs created by `configure`:
#   smoke-eventgen        1,000 eps, 1 worker,  90 s   sanity check
#   eventgen-20k-5w      20,000 eps, 5 workers,180 s   the headline load test
#   eventgen-1w-ceiling  20,000 eps, 1 worker, 120 s   per-worker capacity probe
#   rawreplay-attack        200 eps, 1 worker, 180 s   byte-for-byte replay
#
# `configure` is idempotent: safe to re-run after any redeploy. It has to be
# run at least once per fresh control-plane database, because nothing in the
# Terraform creates a target or a spec, and Stoker refuses a run without both.
#
# Environment (all optional, discovered from the cluster when unset):
#   SOK_NAMESPACE SOK_KUBE_CONTEXT SOK_HEC_URL SOK_HEC_TOKEN SOK_INDEX
#   SOK_TARGET_NAME SOK_FLEET SOK_STOKER_DEPLOY
#
# Before quoting any throughput figure from this, check the run did not span a
# node replacement: a reclaim mid-run invalidates the measurement.

source "$(dirname "${BASH_SOURCE[0]}")/sok-bootstrap-common.sh"

DEPLOY="${SOK_STOKER_DEPLOY:-stoker}"
DRIVER="$(dirname "${BASH_SOURCE[0]}")/sok_stoker_driver.py"

[ $# -ge 1 ] || die "usage: $(basename "$0") {configure|run <spec> [--wait]|results <id>|stop <id>|ls}"
require_tools
require_deploy "$DEPLOY"

case "$1" in
  configure) say "configuring Stoker in ${SOK_NAMESPACE}" ;;
  run)       say "launching ${2:-} on ${SOK_FLEET:-k8s-local}" ;;
esac
exec_driver "$DEPLOY" "$DRIVER" "$@"
