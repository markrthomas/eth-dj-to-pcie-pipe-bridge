# eth-dj-pcie-pipe7_1-bridge

RTL digital design for a **bridge from an IEEE 802.3dj Ethernet MAC/PCS packet
interface to a PCIe PIPE 7.1 MAC-facing parallel interface**, verified in five
independent testbench stacks and wired into CI, a metrics dashboard, and an
optional AI agent swarm.

**Baseline: PAM4.** The PIPE side targets **PCIe Gen6 (64 GT/s, PAM4, FLIT
mode)** and the 802.3dj side is **200G/lane PAM4** — both ends are PAM4-native.
See [`docs/pam4_notes.md`](docs/pam4_notes.md).

> **Status: first cut complete (M0–M7; M8 close-out).** Tx + Rx datapaths and the
> PIPE control plane; five DV environments (Icarus, Verilator C++, SystemC,
> cocotb+PyUVM, UVM-on-Verilator) agree on a shared scenario set; line+branch
> coverage ~95%; bind-based SVA; SymbiYosys PDR proofs; UPF power intent
> (**authored, not run** — no OSS power-aware simulator); GTKWave sessions,
> metrics dashboard, Docker/Railway job and agent-swarm definitions.
> Open owner decisions: [`docs/OPEN_DECISIONS.md`](docs/OPEN_DECISIONS.md).
> Progress: [`docs/PLAN.md`](docs/PLAN.md) §11, [`docs/AGENT_HANDOFF.md`](docs/AGENT_HANDOFF.md).

## What this bridge does

Ingress 802.3dj (PAM4) Ethernet frames (delivered as an AXI4-Stream-style packet
interface off the MAC/PCS) are adapted, clock-domain-crossed, width-geared, and
framed onto a PCIe **PIPE 7.1** MAC-facing datapath in **Gen6 FLIT mode** (256B
flits, parallel TxData/RxData plus the 4-bit PIPE message bus for rate/width/
power-state and PAM4 handshakes). The reverse direction deframes PIPE RxData back
to Ethernet packets. See [`docs/PLAN.md` §2–§3](docs/PLAN.md) for interface and
microarchitecture detail.

## Quick start

```bash
make regress     # lint + Icarus directed tests + shared scenarios — the fast CI gate
make coverage    # Verilator env + SVA -> coverage.info (floor 80% line+branch)
make formal      # SymbiYosys prove + cover (needs the pinned OSS CAD Suite)
make ci          # regress + coverage + formal + all five envs + crosscheck + upf-tb
make stress      # all scenarios x 20 seeds on Verilator
make wave-loop   # run a test with a VCD dump, check + open dv/waves/loop.gtkw
make metrics     # run + time the flows -> metrics/metrics.db; make dashboard renders it
make upf         # prints the "authored, not run" notice (commercial PA tool needed)
```

Tools: the OSS CAD Suite pinned in CI (`2026-04-13`: Verilator 5.047, Icarus,
Yosys+slang, SBY) is needed for `uvm` and `formal`; apt Icarus/Verilator 5.020
run everything else. cocotb env: `pip install -r dv/cocotb/requirements.txt`.
Or use the container: `docker build -t bridge-ci . && docker run --rm bridge-ci`.

## Layout

See [`docs/PLAN.md` §4](docs/PLAN.md). In brief: `rtl/` (design), `dv/`
(five verification environments: `iverilog/`, `vlt/`, `uvm/`, `systemc/`,
`cocotb/`), `dv/sva/` (assertions), `formal/` (SymbiYosys), `lp/` (UPF power
intent), `metrics/` (dashboard), `docker/` + `.claude/agents/` (agent swarm),
`.github/workflows/` (CI), `docs/` (this plan).

## Workspace conventions

This repo lives under `~/proj` and inherits `~/proj/CLAUDE.md` and
`~/proj/DV_STANDARDS.md`. Tool versions are pinned in `~/proj/dv_env.mk`
(`OSS_CAD_SUITE_VERSION`, `cocotb==1.8.1`).
