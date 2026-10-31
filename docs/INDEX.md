# docs/INDEX.md — read selectively

Slice a doc instead of reading it: `sed -n "$(grep -n '^## D9' docs/OPEN_DECISIONS.md | cut -d: -f1),+14p" docs/OPEN_DECISIONS.md`
(or `grep -n -A14 '^## D9\.' docs/OPEN_DECISIONS.md`). Same for PLAN sections (`^## 5\.`).

## Decisions (docs/OPEN_DECISIONS.md) — one line each
| ID | Decision |
|---|---|
| D1 | Lane count vs Ethernet rate: x1 default, `PIPE_NLANES_OVERRIDE` for x2/x4; x8+ refused at elaboration |
| D2 | Flit content: 256 B Gen6 flits, 240 B payload per flit, header + padding rules |
| D3 | Widths / clock plan: eth_clk 200 MHz (256 b), pclk 500 MHz (64 b/lane) |
| D4 | Ethernet side is AXI4-Stream |
| D5/D6 | Missing workspace deps; housekeeping mismatches |
| D7 | pclk-domain CSR port (map in bridge_rf) |
| D8 | PIPE message bus usage/framing (byte-serial, PAM4 preset write) |
| D9 | Rx has no backpressure: overload drops flits (RXCNT0) and aborts a frame in progress (`tuser[0]`); orphan flits dropped, RXCNT1 |
| D10 | PhyStatus / write_ack timeouts |
| D11 | Drain semantics, P0s |
| D12 | DV environments + cross-check contract (`dv/common/scenarios.py` is the golden model) |
| D13 | SVA + formal (SymbiYosys; async_fifo, ingress_gate, ctrl, fc) |
| D14 | Power intent (UPF authored, never run; `pd-emu` emulation) |
| D15 | Infra: CI, Docker, Railway, dashboard |
| D16 | Opt-in two-ended link flow control (`-DFLOW_CTRL_OVERRIDE`; default off) |
| D17 | MAC register file (PIPE 7.1 §7.2), multi-lane message bus |
| D18 | Datapath-local reset is DEFAULT (`-DDP_RESET_DISABLE` opts out) |
| D19 | 2026-10-02 review fixes: null tlast beats, CTRL range check + ERR bits (ERR[2] = P0s flag), saturating counters |
| D20 | Random-regression stimulus contract (x4 sink floor), kill timing; TB only |
| D21 | Silent loss of a dropped-sof frame is kept as specified (counters only); no RTL change |

## PLAN.md sections
0 reference designs · 1 scope · 2 interfaces (2.1 eth, 2.2 PIPE, 2.3 params) · 3 microarchitecture + module list · 4 dir layout ·
5 the five DV envs · 6 coverage · 7 SVA · 8 root Makefile targets · 9 UPF · 10 infra/swarm · 11 phased plan (M0–M8) · 12 open decisions · 13 conventions.

## AGENT_HANDOFF.md
Top block "Current state" (first ~60 lines) is the only part needed to resume; the dated history below it is archaeology — grep it
(`grep -n 'keyword' docs/AGENT_HANDOFF.md`) instead of reading.

## Other
`TOOLCHAIN.md` build recipe · `TUTORIAL.md` user walkthrough · `pam4_notes.md` PAM4 background · `power_intent.md`, `power_state_emulation.md` UPF/PD ·
`railway.md` cloud jobs · `../dv/random/README.md` random regression + status board · `../dv/random/findings/` run write-ups.
