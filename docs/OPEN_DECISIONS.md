# OPEN DECISIONS — need owner sign-off before M1 RTL

Status: **ADOPTED 2026-09-29** — owner delegated D1–D6 to the implementing agent
("use your best judgement"); the recommended defaults below were adopted as written
and M1 implements them. The owner may still overrule any item.
Adopted: D1(a) x1 functional-only, lane-parametric; D2(1) opaque byte tunnel with
the flit format in `eth_dj_pipe7_pkg.sv` (2B header, 240B payload, zeroed
DLP/FEC/CRC); D3 256b/64b as sim params; D4 AXI4-S, `eth_tuser` NOT carried in M1;
D5 sibling repos unavailable -> fresh implementations (async FIFO etc.); D6 PRs
are drafts per session rules.
Numbers below are back-of-envelope and must be checked against the PIPE 7.1 and
802.3dj specs before being frozen (marked *verify*).

## D1. Lane count vs. Ethernet rate (highest impact)

`PIPE_NLANES = 1` (pkg default) cannot carry even one 200G Ethernet lane:

| PIPE lanes | Raw Gen6 rate (64 Gb/s/lane) | After 256B-flit overhead (~242/256 max) | Carries |
|---|---|---|---|
| x1  |  64 Gb/s |  ~60 Gb/s | none of 200G |
| x4  | 256 Gb/s | ~242 Gb/s (less DLP/FC overhead) | 200G, marginal |
| x8  | 512 Gb/s | ~484 Gb/s | 400G |
| x16 | 1024 Gb/s | ~968 Gb/s | 800G |

Options: (a) keep x1 and treat it as a **functional-only** bring-up target with
`ETH_*` rate not tied to line rate (rate-mismatched, backpressured by
`eth_tready`); (b) default to **x4** so 200G is at least physically feasible;
(c) add explicit rate-ratio parameters. **Recommend (a) for M1–M3, with the
datapath lane-parametric, and re-decide at M4.** *Needs owner decision.*

## D2. What does the bridge put inside a flit? (semantic decision)

PLAN says "adapt Ethernet frames and frame them onto FLITs" but not *what the
payload is*. Candidates: (1) opaque byte tunnel — Ethernet frame bytes packed into
the 242B TLP payload area, frame boundaries carried in a bridge-defined header;
(2) real PCIe TLPs (MWr/MRd) wrapping the frame; (3) pass-through of the 256B
container only. Also: who generates DLP/FEC/CRC bytes (PLAN says passthrough;
that means the *bridge must still emit* some 14 bytes — filler? zeros? from the
MAC?). **Recommend (1) with zeroed DLP/FEC/CRC placeholders and a documented
frame-delimit header.** *Needs owner decision — changes DUT behaviour and every
scoreboard.*

## D3. Widths / clock plan (*verify* against PIPE 7.1)

- PIPE x1 @ 64b/lane ⇒ PCLK ≈ 64 Gb/s ÷ 64 = **1 GHz** (may exceed what PIPE 7.1
  defines for Gen6 width/PCLK; confirm legal width/PCLK pairs).
- ETH 256b @ 200G payload ⇒ ~781 MHz `eth_clk`.
- Both are aggressive; sim-only is fine, but the gearbox ratio (256:64 = 4:1) and
  FIFO depth (32) are only justified once D1/D2 fix the true rate ratio.

**Recommend:** freeze `ETH_DATA_W=256`, `PIPE_DATA_W=64` for M1 as *simulation
parameters*, mark synthesis timing out of scope (already in PLAN §1).

## D4. Ethernet-side interface: AXI4-Stream vs. raw

PLAN recommends AXI4-S. `tuser` (8b: SOF/err/lane-tag) bit allocation is
unspecified — need a definition before the scoreboard is written. **Recommend
AXI4-S; tuser[0]=err, tuser[1]=SOF(redundant, checked by SVA), tuser[7:4]=lane tag.**

## D5. Workspace dependencies not available in this container

PLAN/README/AGENT_HANDOFF reference `~/proj/CLAUDE.md`, `~/proj/DV_STANDARDS.md`,
`~/proj/dv_env.mk`, and sibling repos (`axi-on-ucie-to-mem`,
`ucie_rdi_to_pcie6_pipe7`, `eth_axi4s_to_pcie_pipe_bypass`). Only this repo is
present in the cloud session, so "port from sibling" tasks (async FIFO, PMU, UPF,
metrics dashboard, swarm) cannot start here. Either add those repos to the session
or accept fresh implementations. *Needs owner decision.*

## D6. Housekeeping mismatches

- Local/PLAN name `eth-dj-pcie-pipe7_1-bridge` vs. GitHub `eth-dj-to-pcie-pipe-bridge`.
- Two identical-purpose plan files: root `PLAN.md` is the original **prompt**, not a
  plan; consider renaming to `docs/ORIGINAL_PROMPT.md` to avoid confusion.
- Plan says PRs are ready-for-review, session rules say draft; follow the session
  (draft) unless told otherwise.

## Proposed next steps (no RTL behaviour needed)

1. Owner answers D1, D2, D5 (D3/D4/D6 can ride on recommended defaults).
2. Then M1/T1.1 can start with a concrete spec: `tx_cdc` async FIFO, `tx_gearbox`
   (256→64), `tx_framer` per the D2 choice — plus `dv/common` BFMs and a directed
   "one frame → one flit" test.
3. Behaviour-neutral prep that can go ahead now: verify `make regress` is still
   green, write `dv/common` flit-scoreboard skeleton and the shared scenario list,
   and draft the SVA property list (`ASSERTIONS.md`) from PLAN §7.
