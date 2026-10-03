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
    # crosscheck needs all five envs; with a reduced METRICS_FLOWS (a quick test run) it would always
    # fail on "no results for required env", so it only runs for the default flow list or RUN_CROSSCHECK=1
    if [ "${RUN_CROSSCHECK:-}" = "1" ] || { [ -z "${RUN_CROSSCHECK:-}" ] && [ -z "${METRICS_FLOWS:-}" ]; }; then
      make crosscheck || rc=$?
    else
      echo "entrypoint: crosscheck skipped (METRICS_FLOWS=${METRICS_FLOWS:-}; set RUN_CROSSCHECK=1 to force it)"
    fi
    make dashboard || rc=$?
    cp -f metrics/metrics.db metrics/dashboard.html "${ARTIFACT_DIR:-/tmp}/" 2>/dev/null || true
    # the container is ephemeral: publish the results to the repo's metrics-data branch (docs/railway.md);
    # a publishing problem is reported but does not change the run's exit code
    docker/publish_metrics.sh "$rc" || echo "entrypoint: WARNING: publishing the results failed (see above)"
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
