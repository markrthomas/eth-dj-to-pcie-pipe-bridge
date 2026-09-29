# OPEN DECISIONS — design decisions and their status

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

---

# M3+ decisions (adopted by the implementing agent under the owner's standing
# "use your best judgement" delegation — each is listed for owner sign-off in the
# PR that introduced it; overrule any of them and the listed tests change)

## D7. Control/config access: a pclk-domain CSR port (M3)

The PLAN port list (§2) had no way to program `bridge_rf`. **Adopted:** a minimal
always-ready CSR port on the top, `csr_valid/csr_write/csr_addr[7:0]/csr_wdata[31:0]/
csr_rdata[31:0]`, in the **pclk** domain (write on `csr_valid && csr_write`;
`csr_rdata` is a combinational read). Map in `rtl/bridge_rf.sv` / `CSR_*` in the pkg:
CTRL (pwr/rate/width request), PAM4CFG, STATUS, ERR (W1C), RXCNT0/1, PMCNT.
Reset CTRL = {P0, Gen6, width 0}, so with no software the link comes up on its own
(keeps the M1/M2 tests' "link runs after reset" behaviour).
*Caveat:* PIPE lets the PHY stop PCLK in P2; a real integration would clock the AON
control plane from an always-on clock. The model assumes pclk keeps running.

## D8. Message-bus usage and framing (M3)

PowerDown / Rate / Width stay on their **PIPE pins** with the **PhyStatus**
completion handshake (as in PIPE). The 4-bit message bus carries the **PAM4 Tx
control** (precoding enable / preset) as one **committed write** of `PAM4CFG` to
PHY register `MB_ADDR_PAM4_TXCTL` (8'h01, **placeholder — verify against the PIPE
7.1 PHY register map**). Framing on this repo's split `cmd[3:0]`/`data[7:0]` port:
cycle 0 `{MB_WR_C, addr}`, cycle 1 `{MB_NOP, wdata}`; the PHY answers with one cycle
of `{MB_WR_ACK, addr}`. Command codes are the PIPE 5+ encodings (NOP=0, WR_UC=1,
WR_C=2, RD=3, RD_CPL=4, WR_ACK=5). The write is sent at link-up, after every rate
change that lands on Gen6, and whenever software rewrites PAM4CFG — never at Gen1–5.
Datapath framing is unchanged across rates (PCIe 6 flit mode applies at every rate
once negotiated); **width change is a PHY handshake only** — the datapath width is a
compile-time parameter (`PIPE_DATA_W`).

## D9. Rx flow control: drop + abort the damaged frame (M3)

PIPE Rx has no backpressure; if the Ethernet sink is slower than the PIPE rate
something must give. **Adopted:** keep the M2 flit drop (now counted in RXCNT0), but
never deliver a silently corrupted frame: any lost flit (overflow drop or lock error)
marks the next flit (`flit_gap`); at a flit boundary the deframer **aborts** the frame
in progress if the flit follows a gap, carries `sof`, or has a bad header — it emits
the bytes collected so far as a `tlast` beat with **`eth_rx_tuser[0]=1`** (a single
0x00 byte if none were collected, so `tkeep` stays nonzero). Orphan continuation flits
(no `sof`, not in a frame) are dropped (RXCNT1 bad/orphan). End-to-end credit flow
control toward the far-end transmitter is out of scope (it belongs to the link layer
of the peer bridge). Also: a flit that completes in the same cycle the held flit is
taken is now stored, not dropped (M2 dropped it).

## D10. PhyStatus / write_ack timeout (M3)

The FSM waits `PHY_TIMEOUT` (1024) pclk for PhyStatus (or write_ack). On timeout it
**sets a sticky ERR bit and treats the operation as complete** so a dead PHY cannot
wedge the control plane; software sees ERR[0]/ERR[1]. Alternative (hold in an error
state until reset) is safer for a real PHY; owner to confirm.

## D11. Drain semantics and P0s (M3)

"Drain" = close the Ethernet ingress **at the next frame boundary** (a frame already
started is always allowed to finish — so a MAC that stalls mid-frame stalls the
drain), let the Tx CDC FIFO / framer / serialiser empty, and wait for `rx_ingress` to
be between flits with nothing held. Frame-level Rx state (a partially deframed frame,
bytes still in the Rx CDC FIFO) is **not** drained: the PHY is expected not to present
Rx data outside P0, and the Rx CDC FIFO keeps draining to Ethernet in any state.
Rx capture is not gated by power state. P0s is **not supported**: a P0s request sets
ERR[2] and is treated as P0. After reset the Ethernet ingress is closed
(`eth_tready=0`) until the FSM reaches ST_ACTIVE.

## D12. DV environments and the cross-check contract (M4)

No DUT behaviour changes in M4; these are verification-method decisions.

- **Golden model.** `dv/common/scenarios.py` defines the five shared scenarios
  (`single`, `corners`, `random`, `pm_cycle`, `rate_change`): frame lengths (fixed
  lists or a 31-bit LCG, identical constants in SV/C++/Python), the control op, and
  the expected `frames/bytes/flits/crc32/pmcnt/errors`. Every env writes a
  `results.json`; `dv/common/crosscheck.py` compares each one with `expected()`.
  Expected PMCNT = 2 after every reset (P1->P0 + PAM4 msgbus write) + 2 for
  `pm_cycle` (P0->P1, P1->P0) + 3 for `rate_change` (Gen6->Gen5, Gen5->Gen6, PAM4
  re-send). This pins down current M3 behaviour; if D8/D10/D11 change, update
  `scenarios.py`, not the envs.
- **Harness shape.** All envs use PIPE Tx looped to PIPE Rx, a PHY control model
  (PhyStatus + msgbus target), a DUT reset before each scenario, 10% MAC gaps and a
  90%-ready Ethernet sink. The randomness for gaps/ready differs per env (it is not
  part of the contract); only the end results must match.
- **`make regress` gains `scen`** (Icarus run of the shared set, ~2 s). No existing
  regress check was changed or removed.
- **Coverage metric.** "Line coverage" for the PLAN §6 80% floor = Verilator
  `v_line` + `v_branch` points hit / total over `rtl/` (from `dv/vlt`, which also
  runs two coverage-only scenarios: `pm_full` and `rxovf`). Toggle coverage is
  reported, not gated. `eth_egress.sv` is pure `assign`s and has no line points.
  `coverage.info` is written by `verilator_coverage --write-info` from the
  line/branch points only.
- **vlt + SystemC share one C++ harness** (`dv/common/cpp/bridge_bfm.h`), so the
  SystemC env mainly cross-checks SystemC kernel scheduling against plain Verilator
  C++; it is not an independent checker implementation. iverilog, cocotb and UVM
  have their own scoreboards.
- **UVM runs in CI** (its own job), overriding PLAN §12's "local-only" default: with
  the pinned OSS CAD Suite (Verilator 5.047) the build + run takes ~2 min. Accellera
  `uvm-core` is cloned by `dv/uvm/Makefile` at a pinned commit (not vendored).
  apt Verilator 5.020 cannot compile uvm-core (`PKGNODECL`), so `make uvm` needs the
  pinned suite (or any Verilator >= 5.03x) on PATH.
- **cocotb** runs on apt Icarus (`ICARUS_BIN_DIR=/usr/bin`), cocotb 1.8.1, pyuvm
  5.0.0, pyvsc. PyVSC functional coverage is exported to `dv/cocotb/fcov.json` and
  reported, **not gated** (no floor was specified).
