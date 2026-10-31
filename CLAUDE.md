# CLAUDE.md — working conventions for this repo

Guidance auto-loaded into every Claude session (including each headless **swarm**
run) that works in this repo. It captures the **non-obvious** conventions and
hard-won gotchas so a run doesn't re-derive or re-trip them. It is not a spec —
`README.md` and `docs/PLAN.md` are; this is the "how we work here" layer.

**This repo:** a digital-only, open-source DV suite for a **bridge from an IEEE
802.3dj Ethernet MAC/PCS packet interface to a PCIe PIPE 7.1 MAC-facing
interface** (Gen6, 64 GT/s, PAM4, 256B FLIT mode; the 802.3dj side is 200G/lane
PAM4). No commercial simulator on the host; every license-gated flow degrades
gracefully (prints a skip, exits 0). Resuming? Read `docs/AGENT_HANDOFF.md` (the
live work queue + handoff) and `docs/OPEN_DECISIONS.md`, then `docs/PLAN.md`.

**Agents: read this file and [`docs/INDEX.md`](docs/INDEX.md) first.** Open the big
docs (`AGENT_HANDOFF` 34 KB, `OPEN_DECISIONS` 53 KB, `PLAN` 28 KB) only by section
(commands in INDEX.md), never whole.

GitHub origin: `markrthomas/eth-dj-to-pcie-pipe-bridge`.

---

## Golden rules (do not violate)

1. **Additive DV — never change RTL behaviour to force a test green.** If a
   property exposes a real RTL bug, or an invariant genuinely can't be met, STOP
   and report it in the PR (mark it "PARTIAL — design blocker"). Never weaken an
   SVA, delete a coverage bin, or hack the RTL/golden model to get a green. A
   faithful partial beats a fake pass. Never weaken or skip a checker, scenario
   or golden-model field.
2. **RTL/DUT behaviour changes are the human's call.** Never edit `rtl/` unless
   your brief allows it. Write DUT changes up in `docs/OPEN_DECISIONS.md`
   ("Behaviour to review") on a branch and open a PR; a human merges. TB,
   harness, golden-model and infra fixes you may apply.
3. **Never commit on `main`.** Branch (`swarm/<date>-<topic>` for swarm work),
   push incrementally, open a PR. Never push to `main`, never force-push.
   Merging is allowed only for `rr-manager`, and only worker branches into the
   `swarm/` integration branch; nobody merges into `main` (the owner does).
   Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
4. **Report results faithfully.** Quote the real banner/log line and its path.
   Never claim green without the actual run. A skip (tool absent, exit 0) is not
   a pass. Say "not run" and why. **Mutation-test** any new DV env (prove a
   plausible bug makes it fail) so the test has teeth.
5. **Update docs in the same PR as the code** — `README.md` (usage/features),
   `docs/PLAN.md` (mark the item done + what shipped), `docs/AGENT_HANDOFF.md`,
   `docs/OPEN_DECISIONS.md`, and the root `Makefile` `help:` lines for any new
   target/knob. Skip a file only with a one-line reason it doesn't apply.

---

## Build & gate essentials

- **Pinned tools, all from the `Dockerfile`; the OSS CAD Suite is NOT used**
  (removed 2026-10-15). `docs/TOOLCHAIN.md` is the hand-build recipe mirroring it;
  in a bare container run `bash docker/cloud-toolchain.sh`.
  CI builds the image (`tools` target), pushes to GHCR, and runs the jobs inside.
- **Don't set `VERILATOR_ROOT`** — it breaks the UVM-on-Verilator flow; the
  Makefile derives it from the `verilator` on `PATH`.
- **UVM needs a from-source Verilator ≥ 5.03x** (5.050 pinned; apt Verilator can't
  compile uvm-core). The `uvm` env runs in CI / the container image, not
  necessarily locally — before claiming the UVM tier passes, say *where* it ran.
- **Icarus must be ≥ 12.** `dv/cocotb/Makefile` auto-detects the first `iverilog`
  ≥ 12 on `PATH`. Ubuntu 22.04's apt iverilog is 11 (too old — "syntax error / I
  give up"); 24.04's is 12. cocotb is pinned to 1.8.1. Icarus RTL/TB code:
  declare before use, no `break`, no array literals.
- **Formal `cover` uses yices, not z3** (apt z3 OOMs/stalls on deep covers).
  `formal/Makefile` prefers yices when present. It also adapts **native vs plugin
  slang**: upstream Yosys has `read_slang` built in; the committed `.sby` are
  written for the plugin form (`plugin -i slang`) and the Makefile strips that
  line when slang is native. When a new RTL module is instantiated, add it to the
  relevant `formal/*.sby` source list or the proof won't elaborate.
- **Verilator FST traces need `liblz4-dev`** at build time, or the
  `vlt`/`coverage`/`systemc` C++ builds fail with `lz4.h: No such file`.
- Verilator sim binaries abort unless `logs/` exists in the cwd.
- UVM `obj_dir` is ~750 MB; a full disk truncates `Vtb_uvm_top__ALL.a` — delete
  the partial `obj_dir`.
- Heavy targets (`make uvm`, `make vlt`, `make rr-build`, `make formal`, `make ci`)
  run one at a time machine-wide, in the background: `make heavy T=<target>`
  (flock inside the recipe; ~5 GB RAM; every worktree gets its own `obj_dir`,
  delete it when done). Don't call `flock` directly: the headless permission
  checker rejects it. Keep the command a plain `make ...` (no `$?`, no redirects
  to or reads of `/tmp`) and read results from the log/results paths the target prints.
- Never `pkill -f <pattern>` from a shell whose own command line contains the
  pattern.

### The gate (run `make help` for the authoritative list)
- `make regress` = `lint` + `sim` — the fast CI gate (lint x3 + Icarus suite).
- `make coverage` — Verilator C++ `--coverage` → `coverage.info`, **floor 80%**.
- `make formal` — SymbiYosys PDR prove + cover on `formal/*.sby`.
- `make vlt crosscheck` — Verilator env + cross-check against the golden model.
- `make ci` runs every CI step (~10 min, JOBS=4): `regress coverage formal envs
  crosscheck envs-fc vlt-nodpr upf-tb lanes4 wave-check-all pd-emu pd-emu-ret
  rr-replay dashboard`.

## DV env map

Five independent environments cross-check against one Python golden model
(`dv/common/scenarios.py`); `make crosscheck` asserts all five agree byte-exact.

| env | target | engine |
|-----|--------|--------|
| iverilog | `make iverilog` (+ directed `make sim`) | Icarus 12 |
| vlt | `make vlt` | Verilator C++ |
| systemc | `make systemc` | SystemC (apt) |
| cocotb | `make cocotb` | cocotb + PyUVM (Icarus) |
| uvm | `make uvm` | UVM-on-Verilator (from-source Verilator; **CI/container**) |

`envs-fc` reruns vlt/systemc/uvm/cocotb with link flow control ON.

## Random regression

- `make rr-build`, `make rr N=300 JOBS=4 SEED=n`, `make rr-triage RUN=<dir>`,
  `make rr-replay` (corpus gate), `python3 dv/random/rr_iv.py` (Icarus incl. x4).
  Details: `dv/random/README.md`.
- Random knobs: non-flow-control builds need `sink_pct >= 50` (D9/D20); the
  runner already stays inside this.

## Adding a new DV env / module (checklist)
1. `dv/<env>/` with its Makefile; add an `<env>:` target to the root `Makefile`
   and fold it into the gate as appropriate.
2. Bump the "N envs" / env-list text wherever it is enumerated (`docker/`,
   `.claude/agents/*.md`, `Dockerfile`, `railway.toml`, README).
3. If the RTL grew a module, add it to the `formal/*.sby` source list.
4. Mutation-test it. Update docs (rule 5).

## Power / UPF
`make upf` runs the UPF TB only on a commercial power-aware simulator if one is on
`PATH`, else prints a missing-tool notice and exits 0 (UPF is **authored, not
run** — no OSS power-aware sim). `make upf-tb` is the functional Icarus run of the
power-aware TB (PMU sequencing, no UPF). `make pd-emu` / `pd-emu-ret` are the OSS
PD_DP power-state emulation.

## Metrics are NOT on the gate
`metrics/` (`make metrics`, `make dashboard`, `make railway-import`) is opt-in and
runs *after* a completed gate. Never fold it into `regress`/`ci`, and never make a
DV env do extra work to produce a number — measurement must not change the thing
it measures.

## Agent swarms (repo notes)
The swarm itself is the shared kit described in the block below; this repo's profile is `.claude/swarm.env`
(5 envs, `crosscheck`, metrics on, random regression present). Repo-specific doctrine: SVA lives in `dv/sva/`, bound
in; DUT behaviour changes go to `docs/OPEN_DECISIONS.md` ("Behaviour to review").

<!-- swarm-kit:begin (managed by markrthomas/dv-swarm-kit sync.sh — edit the kit, not this block) -->
## Agent swarms, run targets and tokens (swarm-kit)

This repo carries the shared **DV swarm kit** (`markrthomas/dv-swarm-kit`, version in `.claude/swarm-kit.version`).
Its repo-specific settings are **`.claude/swarm.env`** (`make swarm-profile` prints them); everything else in the
kit is identical across repos — change it in the kit and re-sync, never fork it here.

- **Swarm A** — end-to-end re-verification: `make swarm` (`docker/swarm-task.md`; swarm-manager + one
  dv-env-tester per `DV_ENVS` entry + infra-agent + dv-runner).
- **Swarm B** — random regression: `make swarm-rr` (`docker/rr-swarm-task.md`; rr-manager + rr-runner / rr-triage /
  rr-debugger / rr-test-author). With `RR_STATUS=bootstrap` it first builds `make rr-build/rr/rr-triage/rr-replay`
  (the `rr-bootstrap` skill), then flips the flag to `present`.
- Status board: `make board`; workers report via `python3 tools/swarm/board.py` (the `board-report` skill).
- Heavy targets (`HEAVY_TARGETS`) run one at a time: `make heavy T=<target>`. Headless Bash is limited to
  `.claude/settings.json`. `make swarm-dry` shows what a swarm run would execute; `make swarm-kit-check` checks drift.

Doctrine (all agents): verify every claim against a real artifact ("no artifact = not verified"); never weaken or skip
a checker to get green; a skip is "not run", not a pass; keep the RTL assertion-free; DUT behaviour changes are the
owner's call (write them up, don't merge them); branches `swarm/<date>-<topic>`; never push to `main`, never force-push.
Return findings as verdict + evidence (file:line / command + 3-10 line excerpt) + next step — no log dumps.

**Where it runs** (same image everywhere: the Dockerfile `tools` stage, plus the repo for `full`):
| where | how | credentials |
|---|---|---|
| GitHub Actions | Actions → **swarm** → Run workflow (task: Swarm A or B) | repo secret `CLAUDE_CODE_OAUTH_TOKEN` |
| Codespaces | open a Codespace (`.devcontainer/`), then `make swarm`, `make swarm-rr` or `make batch` | Codespaces secret `CLAUDE_CODE_OAUTH_TOKEN`; `GITHUB_TOKEN` is injected |
| Railway | batch service built from `railway.toml` (weekly cron); swarm service: start command `docker/entrypoint.sh swarm [--task docker/rr-swarm-task.md]` | service variables `CLAUDE_CODE_OAUTH_TOKEN` (swarm only) and `GITHUB_TOKEN` (fine-grained PAT: this repo, Contents read+write) |

Batch results go to the `metrics-data` branch (`runs/<UTC>-<sha>/`), never to `main`: automatically on Railway
(when `GITHUB_TOKEN` is set), elsewhere only with `PUBLISH_METRICS=1`. Tokens live only in
GitHub/Codespaces/Railway secret stores — never in the repo, the image, a log or a chat.
<!-- swarm-kit:end -->
