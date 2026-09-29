# AGENT_HANDOFF — resume this repo

If a session ended, this is where you pick up. Read this, then
[`PLAN.md`](PLAN.md).

## Where things stand (update this block every session)

- **2026-09-29 (c)** — Pickup session (cloud). Re-read all docs/RTL. Wrote
  [`OPEN_DECISIONS.md`](OPEN_DECISIONS.md): lane count vs. 200G rate (x1 can't carry
  it), flit payload semantics, widths/PCLK, tuser, missing `~/proj` siblings.
  **M1/T1.1 is BLOCKED on owner answers to D1, D2, D5** (it is RTL behaviour).
  `make regress` could not be re-run this session (shell tool unavailable); last
  known state is green per (b).
- **2026-09-29 (b)** — **Baseline set to PAM4 / PCIe Gen6 FLIT mode** (PLAN §12
  resolved) and **M0 scaffold landed**. This is now a **standalone git repo**
  (`git init`; remote `origin` = github.com/markrthomas/**eth-dj-to-pcie-pipe-bridge**
  — note the GitHub repo name differs from this local dir name). Present:
  `rtl/eth_dj_pipe7_pkg.sv` (PAM4/
  Gen6 params + enums), `rtl/eth_dj_pipe7_bridge.sv` (top stub, ports frozen per
  §2), `dv/iverilog/tb_smoke.sv` + Makefile, stub Makefiles for `dv/{vlt,uvm,
  systemc,cocotb}`, placeholder READMEs for `dv/{common,sva,waves}`, `formal/`,
  `lp/`, `metrics/`, `docker/`, `.claude/agents/`, root `Makefile`, `.gitignore`,
  `.github/workflows/ci.yml`, `docs/pam4_notes.md`. **`make regress` (lint +
  Icarus smoke) is GREEN; `make ci` exits 0 (coverage/formal are stubs).**
  **Next action: `PLAN.md` task T1.1** — Tx datapath (eth→pipe) with 256B FLIT
  assembly; remove the M0 lint waivers as signals get consumed.
- **2026-09-29 (a)** — First-cut plan written (`docs/PLAN.md`).

## How to resume in three steps

1. **Read the two reference repos** (do not reinvent):
   - `~/proj/axi-on-ucie-to-mem` — copy the `Makefile` targets, `dv/` five-env
     layout, `dv/sva/`, `formal/`, `metrics/` dashboard, `docker/` + `.claude/agents/`
     swarm, `railway.toml`, `Dockerfile`, GTKWave `dv/waves/*.gtkw`.
   - `~/proj/ucie_rdi_to_pcie6_pipe7` — copy the PIPE 7.1 interface model, the
     `pipe7_pmu`, the message-bus handshakes, and the UPF flow
     (`test/upf/bridge.upf`, `docs/power_intent.md`).
   - Also `~/proj/DV_STANDARDS.md` (mandatory targets/CI) and `~/proj/dv_env.mk`
     (version pins: OSS CAD Suite + `cocotb==1.8.1`).

2. **Find the next unchecked task** in `PLAN.md` §11 (milestones M0→M8). Work
   top-to-bottom; each milestone has a `make` gate that must go green before the
   next.

3. **Verify against the gate**, check the box in `PLAN.md`, update the "Where
   things stand" block above, and commit.

## Environment gotchas (from workspace memory — heed these)

- **cocotb + Icarus:** set `ICARUS_BIN_DIR=/usr/bin` to avoid the OSS CAD Suite
  Python mismatch; drive valid/ready exactly once *after* the clock edge to
  avoid handshake races. (memory `cocotb-apb-slave-timing`,
  `pyvsc-functional-coverage`)
- **PyVSC functional coverage:** install pyvsc into `/usr/bin/python3`.
- **UVM on Verilator:** OSS CAD Suite's Verilator can't run UVM. Use
  `~/verilator` (5.050, UVM-capable) + `~/uvm-verilator` (Accellera UVM
  1800.2-2020 3.2); **keep `VERILATOR_ROOT` unset**. (memory `oss-uvm-verilator`)
- **UPF:** no OSS power-aware simulator exists here; `make upf` is authored +
  documented, run on a commercial tool, OSS-stubbed. (see `PLAN.md` §9)
- **Icarus + SV struct literals:** Icarus-11 can't compile SV struct literals /
  `return` in some forms — keep a plain-Verilog model for anything that must run
  under Icarus or Yosys formal (this bit `IP-ucie-rdi-to-pcie-pipe`).

## Guardrails (from `~/proj/CLAUDE.md`)

- Open PRs **ready for review**, not drafts.
- Finish what you open: CI green + no conflicts → self-review the diff → merge →
  delete branch (remote + local). **Stop and leave the PR for the human** when
  it's an RTL/DUT behavior change, a change to what a regression checks, or
  anything you couldn't verify end-to-end (e.g. UPF, UVM without a license).
- If branch deletion is blocked (git proxy 403), list the leftover branches for
  the user instead of skipping silently.

## Don't

- Don't fabricate coverage/perf numbers — the metrics DB has a `kind` field
  (`measured`/`estimated`/`not_attributable`); record gaps honestly.
- Don't put assertions in `rtl/` — SVA goes in `dv/sva/` via `bind`.
- Don't set `VERILATOR_ROOT`.
