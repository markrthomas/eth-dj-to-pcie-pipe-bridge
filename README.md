# eth-dj-pcie-pipe7_1-bridge

RTL digital design for a **bridge from an IEEE 802.3dj Ethernet MAC/PCS packet
interface to a PCIe PIPE 7.1 MAC-facing parallel interface**, verified in five
independent testbench stacks and wired into CI, a metrics dashboard, and an
optional AI agent swarm.

**Baseline: PAM4.** The PIPE side targets **PCIe Gen6 (64 GT/s, PAM4, FLIT
mode)** and the 802.3dj side is **200G/lane PAM4** — both ends are PAM4-native.
See [`docs/pam4_notes.md`](docs/pam4_notes.md).

> **Status: M0 scaffold complete.** Standalone git repo initialized; RTL package
> + top stub, the five `dv/` environment dirs, root `Makefile`, and CI are in
> place. **`make regress` (lint + Icarus smoke) is green.** No datapath behavior
> yet (M1). Start at [`docs/PLAN.md`](docs/PLAN.md); if you are an AI agent
> picking up the work, start at [`docs/AGENT_HANDOFF.md`](docs/AGENT_HANDOFF.md).

## What this bridge does

Ingress 802.3dj (PAM4) Ethernet frames (delivered as an AXI4-Stream-style packet
interface off the MAC/PCS) are adapted, clock-domain-crossed, width-geared, and
framed onto a PCIe **PIPE 7.1** MAC-facing datapath in **Gen6 FLIT mode** (256B
flits, parallel TxData/RxData plus the 4-bit PIPE message bus for rate/width/
power-state and PAM4 handshakes). The reverse direction deframes PIPE RxData back
to Ethernet packets. See [`docs/PLAN.md` §2–§3](docs/PLAN.md) for interface and
microarchitecture detail.

## Quick start (once RTL lands)

```bash
make regress     # lint + primary sim — the fast CI gate
make ci          # regress + coverage + formal — full local run
make waves       # run the directed sim and open the GTKWave session
make dashboard   # build metrics/dashboard.html from metrics.db
```

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
