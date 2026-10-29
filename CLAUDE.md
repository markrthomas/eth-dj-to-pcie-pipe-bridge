# eth-dj <-> PCIe PIPE 7.1 bridge — agent quick-start

802.3dj Ethernet (AXI4-S) to PCIe PIPE 7.1 Gen6 FLIT bridge, SystemVerilog, five DV envs. Read this file and
[`docs/INDEX.md`](docs/INDEX.md) first; open the big docs (`AGENT_HANDOFF` 34 KB, `OPEN_DECISIONS` 53 KB,
`PLAN` 28 KB) only by section (commands in INDEX.md), never whole.

## Commands (WSL/Linux; toolchain: `bash docker/cloud-toolchain.sh` in a bare container, full: docs/TOOLCHAIN.md)
- `make regress` fast gate (lint x3 + Icarus suite) · `make vlt crosscheck` · `make ci` full local mirror of CI (~10 min, JOBS=4)
- Random regression: `make rr-build`, `make rr N=300 JOBS=4 SEED=n`, `make rr-triage RUN=<dir>`, `make rr-replay` (corpus gate),
  `python3 dv/random/rr_iv.py` (Icarus incl. x4). Details: `dv/random/README.md`.
- Swarm status: `make board` (all) / `python3 dv/random/board.py show --brief --active` (cheap). Workers report with `board.py start|update|result|done|fail` then `git push`.

## Rules every agent follows
- Never weaken/skip a checker, scenario or golden-model field. Never edit `rtl/` unless your brief allows it; DUT behaviour changes go on a branch with a
  "Behaviour to review" entry in `docs/OPEN_DECISIONS.md` (the owner decides).
- Branch only (`swarm/<topic>`), never push to `main`, no force-push, PRs only when asked. Merging is allowed only for `rr-manager`, and only
  worker branches into the `swarm/` integration branch; nobody merges into `main` (the owner does). Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Say "not run" and why; never claim a result without its log/command output.

## Gotchas (cost real time before)
- Do NOT set `VERILATOR_ROOT`. Verilator >= 5.03x (5.050 pinned); Icarus >= 12; cocotb 1.8.1.
- Verilator sim binaries abort unless `logs/` exists in the cwd. Icarus: declare before use, no `break`, no array literals.
- Never `pkill -f <pattern>` from a shell whose own command line contains the pattern.
- UVM obj_dir is ~750 MB; a full disk truncates `Vtb_uvm_top__ALL.a` — delete the partial obj_dir.
- Random knobs: non-flow-control builds need `sink_pct >= 50` (D9/D20); the runner already stays inside this.

## Token budget (all agents)
Return findings as: verdict, evidence (file:line / command + 3-10 line excerpt), next step — no full logs, no re-quoting your brief.
Use `grep -n`/`sed -n a,bp` for slices; read a file once. Prefer one batched command over many small ones.
