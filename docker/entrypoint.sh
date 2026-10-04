#!/usr/bin/env bash
# docker/entrypoint.sh — container entrypoint (Railway batch job / local run).
#   (no args) | ci : run + time every flow (make metrics), 5-env crosscheck,
#                    render the dashboard; exit non-zero if anything failed
#   swarm          : run the agent swarm (docker/swarm.sh; needs CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)
#   <cmd...>       : run an arbitrary command inside the image
set -euo pipefail
# the image keeps the repo at /repo; outside the image (a local checkout) use the checkout this script lives in
if [ -d /repo ]; then cd /repo; else cd "$(dirname "$0")/.."; fi

# Build parallelism.  The DV Makefiles default to `JOBS ?= $(nproc)`, and in a container nproc reports the
# HOST's cores (dozens) while the memory limit is a few GB: a UVM / Verilator build then runs that many
# g++ jobs at once and the container sits at its memory limit (thrashing / killed).  Unless JOBS is set,
# derive it from the cgroup memory limit (about 3 GB per job), capped by the visible cores.
if [ -z "${JOBS:-}" ]; then
  cores="$(nproc 2>/dev/null || echo 4)"
  lim="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)"
  if [ "$lim" != "max" ] && [ "$lim" -lt 1099511627776 ] 2>/dev/null; then
    jobs=$(( lim / 1073741824 / 3 ))
  else
    jobs=4                                   # no (usable) memory limit visible
  fi
  [ "$jobs" -lt 1 ] && jobs=1
  [ "$jobs" -gt "$cores" ] && jobs="$cores"
  export JOBS="$jobs"
  echo "entrypoint: JOBS=$JOBS (cores=$cores, memory limit=$lim; set JOBS to override)"
fi
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
