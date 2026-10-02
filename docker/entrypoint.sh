#!/usr/bin/env bash
# docker/entrypoint.sh — container entrypoint (Railway batch job / local run).
#   (no args) | ci : run + time every flow (make metrics), 5-env crosscheck,
#                    render the dashboard; exit non-zero if anything failed
#   swarm          : run the agent swarm (docker/swarm.sh; needs CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)
#   <cmd...>       : run an arbitrary command inside the image
set -euo pipefail
cd /repo
mode="${1:-ci}"
case "$mode" in
  ci)
    rc=0
    make metrics METRICS_FLOWS="${METRICS_FLOWS:-regress,coverage,systemc,cocotb,uvm,formal,upf-tb}" \
                 METRICS_NOTE="${METRICS_NOTE:-container run}" || rc=$?
    make crosscheck || rc=$?
    make dashboard || rc=$?
    cp -f metrics/metrics.db metrics/dashboard.html "${ARTIFACT_DIR:-/tmp}/" 2>/dev/null || true
    echo "entrypoint: done (rc=$rc)"
    exit "$rc"
    ;;
  swarm)
    shift
    exec docker/swarm.sh "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
