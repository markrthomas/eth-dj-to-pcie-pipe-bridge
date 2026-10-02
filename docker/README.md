# docker — container image & agent swarm

- `../Dockerfile` — Ubuntu 24.04 + pinned OSS CAD Suite 2026-04-13 (last on PATH)
  + apt Icarus/SystemC + venv with cocotb 1.8.1/pyuvm/pyvsc. `--build-arg
  WITH_CLAUDE=1` also installs the Claude Code CLI for the swarm.
  Optional `--secret id=extra_ca,src=<pem>` for TLS-intercepting proxies.
- `entrypoint.sh` — default: `make metrics` over every flow (incl. uvm, formal),
  `make crosscheck`, `make dashboard`; exits non-zero on any failure. `swarm`
  runs `swarm.sh`; anything else is executed as a command.
- `publish_metrics.sh` — called by `entrypoint.sh` after a run: pushes `metrics.db`, `dashboard.html`
  and a `run.json` to the GitHub branch `metrics-data` (needs a `GITHUB_TOKEN` service variable; no token =
  notice only). `make railway-import` merges them into the dashboard. See `../docs/railway.md`.
- `swarm.sh` / `swarm-task.md` — non-interactive Claude Code run with the
  `.claude/agents/` definitions (`--dry-run` prints the command).
- `../railway.toml` — Railway batch job (DOCKERFILE builder, restart NEVER,
  nightly cron, no startCommand).

Local use: `docker build -t bridge-ci .` then `docker run --rm bridge-ci`.
