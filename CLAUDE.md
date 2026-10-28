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

GitHub origin: `markrthomas/eth-dj-to-pcie-pipe-bridge`.

---

## Golden rules (do not violate)

1. **Additive DV — never change RTL behaviour to force a test green.** If a
   property exposes a real RTL bug, or an invariant genuinely can't be met, STOP
   and report it in the PR (mark it "PARTIAL — design blocker"). Never weaken an
   SVA, delete a coverage bin, or hack the RTL/golden model to get a green. A
   faithful partial beats a fake pass.
2. **RTL/DUT behaviour changes are the human's call.** Write them up in
   `docs/OPEN_DECISIONS.md` on a branch and open a PR; a human merges. TB,
   harness, golden-model and infra fixes you may apply.
3. **Never commit on `main`.** Branch (`swarm/<date>-<topic>` for swarm work),
   push incrementally, open a PR. Never force-push.
4. **Report results faithfully.** Quote the real banner/log line and its path.
   Never claim green without the actual run. A skip (tool absent, exit 0) is not
   a pass. **Mutation-test** any new DV env (prove a plausible bug makes it fail)
   so the test has teeth.
5. **Update docs in the same PR as the code** — `README.md` (usage/features),
   `docs/PLAN.md` (mark the item done + what shipped), `docs/AGENT_HANDOFF.md`,
   `docs/OPEN_DECISIONS.md`, and the root `Makefile` `help:` lines for any new
   target/knob. Skip a file only with a one-line reason it doesn't apply.

---

## Build & gate essentials

- **Pinned tools, all from the `Dockerfile`; the OSS CAD Suite is NOT used**
  (removed 2026-10-15). `docs/TOOLCHAIN.md` is the hand-build recipe mirroring it.
  CI builds the image (`tools` target), pushes to GHCR, and runs the jobs inside.
- **Don't set `VERILATOR_ROOT`** — it breaks the UVM-on-Verilator flow; the
  Makefile derives it from the `verilator` on `PATH`.
- **UVM needs a from-source Verilator ≥ 5.03x** (apt Verilator can't compile
  uvm-core). The `uvm` env runs in CI / the container image, not necessarily
  locally — before claiming the UVM tier passes, say *where* it ran.
- **Icarus must be ≥ 12.** `dv/cocotb/Makefile` auto-detects the first `iverilog`
  ≥ 12 on `PATH`. Ubuntu 22.04's apt iverilog is 11 (too old — "syntax error / I
  give up"); 24.04's is 12.
- **Formal `cover` uses yices, not z3** (apt z3 OOMs/stalls on deep covers).
  `formal/Makefile` prefers yices when present. It also adapts **native vs plugin
  slang**: upstream Yosys has `read_slang` built in; the committed `.sby` are
  written for the plugin form (`plugin -i slang`) and the Makefile strips that
  line when slang is native. When a new RTL module is instantiated, add it to the
  relevant `formal/*.sby` source list or the proof won't elaborate.
- **Verilator FST traces need `liblz4-dev`** at build time, or the
  `vlt`/`coverage`/`systemc` C++ builds fail with `lz4.h: No such file`.

### The gate (run `make help` for the authoritative list)
- `make regress` = `lint` + `sim` — the fast CI gate.
- `make coverage` — Verilator C++ `--coverage` → `coverage.info`, **floor 80%**.
- `make formal` — SymbiYosys PDR prove + cover on `formal/*.sby`.
- `make ci` runs every CI step: `regress coverage formal envs crosscheck envs-fc
  vlt-nodpr upf-tb lanes4 wave-check-all pd-emu pd-emu-ret dashboard`.

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

## Agent swarms
`.claude/agents/` defines two swarms (loaded when Claude Code runs non-bare via
`docker/swarm.sh`): **Swarm A** end-to-end re-verification (`docker/swarm-task.md`
— swarm-manager + dv-env-tester per env + infra-agent) and **Swarm B** the
random-regression loop (`docker/rr-swarm-task.md` — rr-manager + rr-runner /
rr-triage / rr-debugger / rr-test-author). Doctrine: verify every claim against a
real artifact ("no artifact = not verified"), keep `rtl/` assertion-free (SVA
lives in `dv/sva/`, bound in), RTL/DUT changes to `docs/OPEN_DECISIONS.md`,
branches `swarm/<date>-<topic>`, never force-push, never push to `main`.
