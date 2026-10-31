# docker — container image & agent swarm

- `../Dockerfile` — Ubuntu 24.04, multi-stage: builds Verilator + Yosys+slang +
  SBY from source, plus apt Icarus/SystemC/z3 + yices + a venv with cocotb
  1.8.1/pyuvm/pyvsc (no OSS CAD Suite). `--build-arg WITH_CLAUDE=1` also installs
  the Claude Code CLI for the swarm.
  Optional: put `*.crt` files in `docker/extra_ca/` before building to trust an extra CA
  (TLS-intercepting proxies). No `RUN --mount=type=secret`: Railway's builder rejects it.
- `entrypoint.sh` — default: `make metrics` over every flow (incl. uvm, formal),
  `make crosscheck`, `make dashboard`; exits non-zero on any failure. `swarm`
  runs `swarm.sh`; anything else is executed as a command.
- `publish_metrics.sh` — called by `entrypoint.sh` after a run: pushes `metrics.db`, `dashboard.html`
  and a `run.json` to the GitHub branch `metrics-data` (needs a `GITHUB_TOKEN` service variable; no token =
  notice only). `make railway-import` merges them into the dashboard. See `../docs/railway.md`.
- `swarm.sh` / `swarm-task.md` — non-interactive Claude Code run with the
  `.claude/agents/` definitions (`--dry-run` prints the command).
- `rr-swarm-task.md` — rr-manager brief for the random-regression swarm:
  `docker/swarm.sh --task docker/rr-swarm-task.md` (`--dry-run` prints the command). Weekly Railway job
  recipe (docs only, not deployed): `../docs/railway.md` "Weekly random-regression job". Results ->
  metrics: `make rr-metrics RUN=dv/random/runs/<ts>`.
- `../railway.toml` — Railway batch job (DOCKERFILE builder, restart NEVER,
  weekly cron (Sundays 03:17 UTC), no startCommand).

Local use: `docker build -t bridge-ci .` then `docker run --rm bridge-ci`.
