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

**Resolution (owner delegated, 2026-09-29): keep x1 as the default; x4 is the minimum
for one 200G lane and is now CI-checked.** The lane count is a compile-time bump:
`-DPIPE_NLANES_OVERRIDE=N` (pkg) gives `PIPE_BUS_W = 64*N` and `FLIT_BEATS = 32/N`.
`make lanes4` runs Verilator lint at x4 plus the whole iverilog suite (smoke, tx, loop,
pm, rxovf, scen + golden cross-check) at 4 lanes — all pass, with identical frame/flit
counts and CRCs to x1. It runs in the CI `regress` job; `make regress` itself is
unchanged and stays x1. Not covered at x4: the vlt/systemc/uvm/cocotb envs, formal, and
SVA (the x4 check is Icarus + lint only). N must divide 32 (8 beats at x4, 4 at x8,
2 at x16); other values are not checked. Throughput at x1 stays functional-only (the
single-buffered framer also halves it). Re-decide the default when a real rate target
is fixed.

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
completion handshake (as in PIPE). The message bus (**8-bit** M2P/P2M byte buses — see the 2026-09-30 resolution below; the earlier "4-bit" wording and split cmd/data framing in this paragraph are superseded) carries the **PAM4 Tx
control** (now: the Gen6 **Tx preset index**, see the 2026-09-30 register resolution below) as one **committed write** of `PAM4CFG` to
PHY register `MB_ADDR_TX_PRESET` (8'h01, **placeholder — verify against the PIPE
7.1 PHY register map**). Framing on this repo's split `cmd[3:0]`/`data[7:0]` port:
cycle 0 `{MB_WR_C, addr}`, cycle 1 `{MB_NOP, wdata}`; the PHY answers with one cycle
of `{MB_WR_ACK, addr}`. Command codes are the PIPE 5+ encodings (NOP=0, WR_UC=1,
WR_C=2, RD=3, RD_CPL=4, WR_ACK=5). The write is sent at link-up, after every rate
change that lands on Gen6, and whenever software rewrites PAM4CFG — never at Gen1–5.
Datapath framing is unchanged across rates (PCIe 6 flit mode applies at every rate
once negotiated); **width change is a PHY handshake only** — the datapath width is a
compile-time parameter (`PIPE_DATA_W`).

**Resolution (2026-09-30, supersedes the "not verified" note above): interface changed
to a spec-shaped 8-bit byte bus; verified against a sibling model, still NOT against the
spec text.** The PIPE 7.1 spec is unreachable from this environment (intel.com and
community.cadence.com are blocked by the network proxy). With the owner's approval the
sibling repo `markrthomas/ucie-rdi-to-pcie6-pipe7` was read; its
`src/pipe7_msgbus_master.sv` / `pipe7_pkg.sv` cite PIPE 7.1 §6.1.4.2 Tables 6-10..6-14 and
implement: **one 8-bit M2P and one 8-bit P2M byte bus, idle 8'h00, any non-idle byte
starts a transaction, 12-bit register addresses, 8-bit data**; write_committed =
`{cmd, addr[11:8]}`, `addr[7:0]`, `data[7:0]`; write_ack = one P2M byte `{WRITE_ACK, x}`.
Findings vs what this repo had:
- **Command opcodes matched** (NOP 0, WR_UNCOMMIT 1, WR_COMMIT 2, READ 3, READ_COMPLETION 4,
  WRITE_ACK 5) — unchanged.
- **Interface was wrong:** the top-level had separate `pipe_m2p_cmd[3:0]`/`data[7:0]`
  ports and an 8-bit address, and PLAN called it "the 4-bit message bus". **Changed:**
  the four ports became `pipe_m2p_msgbus[7:0]` / `pipe_p2m_msgbus[7:0]`; `pipe_msgbus`
  now sends the 3-byte frame above and accepts a write_ack when `p2m[7:4] == MB_WR_ACK`;
  addresses are 12-bit (`MB_ADDR_W`); the DV PHY models decode the byte-serial framing.
- **PAM4 register — CORRECTED against the spec (2026-09-30).** From PIPE 7.1 (ref 643108)
  Table 7-1 and Tx Control tables 7-12..7-22: the address space is 12-bit; TX1 "PHY Tx Control0..10"
  live at 12'h400..12'h40A. **`12'h406` is Tx Control6 = FS[5:0]** (the link partner's FS value),
  *not* a PAM4 register, so the previous choice (a `PAM4CFG` byte written to 12'h406 at every Gen6
  link-up) wrote a bogus FS value. **No PAM4 precoding-enable register exists in Tx Control0..10**
  (the sibling repo's "PAM4RestrictedLevels at 12'h406" had the right field name but the wrong address — see below). The registers are: 400/401
  SATA/USB (N/A SerDes), 402 TxDeemph_Cminus1, 403 TxDeemph_Czero, 404 TxDeemph_Cplus1,
  **405 GetLocalPresetCoefficients[7] + LocalPresetIndex[5:0]**, 406 FS, 407 LF, 408 TxSwing/TxMargin,
  409 TxDeemph_Cminus2 (64 GT/s+), 40A TxLaneEnable (USB4/DP). Also: RX1 Rx Margin 0/1 at 0/1,
  TX2 at 600..7FF, CMN1 at 800/801, CMN2 at A00..BFF, vendor C00..FFF.
- **Decision (owner, 2026-09-30): write the Gen6 Tx preset index.** `MB_ADDR_TX_PRESET = 12'h405`
  (renamed from `MB_ADDR_PAM4_TXCTL`); the byte is `{2'b00, LocalPresetIndex[5:0]}`; the `PAM4CFG`
  CSR keeps its name but is now the 6-bit preset index (reset **6'b100001 = 64 GT/s Preset P0**,
  Table 7-17; bits [7:6] read 0 / are ignored on write because bit 7 of 12'h405 is the
  one-cycle `GetLocalPresetCoefficients` strobe and must never be set by accident). **Precoding
  enable is dropped** — no register for it has been found. The write is still sent at link-up,
  after a rate change landing on Gen6, and on a PAM4CFG rewrite; never below Gen6.
  Caveats: the spec table lists 64 GT/s P1 as `100011b` (skipping `100010b`), likely a typo —
  only P0 (`100001b`) is used; per the spec LocalPresetIndex "is only used with a PHY that
  requires dynamic preset coefficient updates".
- **Alternatives not taken:** writing the four Gen6 coefficients (C-2/C-1/C0/C+1 at 409/402/403/404,
  three write_uncommitted + one write_committed) — larger, and no spec-derived default values; or
  no message-bus write at all.
- **Framing and opcodes — VERIFIED against the spec text (2026-09-30).** The owner pasted
  PIPE 7.1 (ref 643108) §6.1.4 (Tables 6-9..6-14, Figure 6-1, §6.1.4.2). Confirmed exactly:
  `M2P_MessageBus[7:0]`/`P2M_MessageBus[7:0]` (Table 6-9); command encodings NOP 0000,
  write_uncommitted 0001, write_committed 0010, read 0011, read_completion 0100, write_ack 0101
  (Table 6-10); write = `{Cmd[3:0],Addr[11:8]}`, `Addr[7:0]`, `Data[7:0]` (Table 6-14);
  write_ack is one cycle `{Cmd[3:0],0000b}` (Table 6-11); idle = all zeros; an idle->non-idle
  byte starts a transaction whose length comes from its command; a new transaction may follow
  with no idle; cycles of one transaction are contiguous; after a write_committed no new write
  may be sent until its write_ack. Our master already did all of this.
- **Bug found by that reading, fixed:** `pipe_msgbus` decoded *every* P2M byte as a possible
  command while waiting, so a P2M `read_completion` (`{RD_CPL,0}`, data) or a PHY-initiated
  write whose payload byte had a `5_` high nibble would have been taken as a write_ack.
  Now a P2M framer tracks the transaction length (write 3, read/read_completion 2, others 1)
  and only the first byte of a transaction is a command. Covered by `dv/iverilog/tb_msgbus.sv`
  (T2/T3 fail if the old decode is restored; T4 checks back-to-back transactions).
- **MAC-side message-bus target — IMPLEMENTED (2026-09-30), with limits.** The spec lets the PHY
  initiate reads/writes to MAC registers and requires responses on M2P. `rtl/msgbus_mac_tgt.sv` (+ an
  M2P arbiter; the master `pipe_msgbus` is unchanged apart from a `tx_active` output) now: answers a PHY
  `write_committed` with one `write_ack`; answers a PHY `read` with `read_completion` (`{RD_CPL,0}`, data);
  discards PHY `write_uncommitted` payloads (no response, as specified); ignores the PHY's own
  `write_ack`/`read_completion` (responses to us). Arbitration: the master's 3-byte frame is never
  interrupted and a response is never started while a request is pending or a frame is in flight; **the
  master has priority** over a pending response (so a flooding PHY cannot starve the bridge's write);
  at most one write_ack and one read_completion are pending, and a further PHY request while one is pending
  is dropped and counted (`drop_cnt`). The FSM's request is now latched by the arbiter (+1 cycle), so
  ST_CFG can last a few cycles longer (SVA bound PHY_TIMEOUT+8).
  **Limits (design decisions, not spec-derived):** *no MAC register map is implemented* (PIPE 7.1 §7.2 was
  not available): every MAC register reads `8'h00` and PHY writes are accepted and discarded (the last
  is exposed for DV: `last_wr_addr/data`, `phy_wr_cnt`, `phy_rd_cnt`). So Rx-margining status etc. is
  NOT actually provided; the target only stops the PHY from hanging on an unanswered request. Not
  formally proven (the proofs cover the master + FSM only); covered by `dv/iverilog/tb_msgbus_mac.sv`
  (scenarios A-H, mutation-checked) and SVA `a_mb6_tgt_no_overlap`.
- **PAM4RestrictedLevels located; bridge does NOT drive it (owner decision, 2026-09-30, "document
  only").** From PIPE 7.1 Table 7-6 (PHY Rx Control1, **12'h004**, RX1 region): **bit 2
  `PAM4RestrictedLevels`** (PCIe, optional; only at 64 GT/s and higher). Timing rules: the MAC sets it
  to 1 to say the link partner is / will soon be sending TS0s at >= 64 GT/s; **set after a rate change
  to 64 GT/s+ only if a Tx Equalization procedure is expected** (never for NoEq), **after the rate
  change's PhyStatus and before RxStandby is deasserted**; the MAC **clears it when it asks the link
  partner to go from TS0 to TS1** (Phase 2 upstream / Phase 3 downstream; if Phases 2/3 are bypassed,
  during Recovery.RcvrLock); **the PHY autonomously clears it on every rate change to >= 64 GT/s before
  returning PhyStatus**; the PHY advertises whether it needs it (PAM4RestrictedLevelsRequirement).
  This is link-training (LTSSM) timing and the bridge has no LTSSM and no RxStandby pin, so it cannot be
  driven correctly here. **Integration requirement:** whatever runs link training must own
  `12'h004`. Do not let this bridge write it: a full-byte write would also clear the other Rx Control1
  fields (`RxInPhase01Equalization` [4], `RxPAM3Mode` [3], `IORecal` [1] strobe,
  `RxEqTraining` [0]).
- **No PAM4 precoding-enable register exists in the PHY register map.** With Table 7-1 (both sheets) and
  Tables 7-2..7-22 pasted, the PHY registers are Rx Margin 0/1, Elastic Buffer Control, Rx Control0..5,
  Elastic Buffer Location Update, Tx Control0..10, CMN Control0 (N/A SerDes) and near-end loopback —
  none is a precoding enable. So the earlier `PAM4CFG` "precoding enable" bit had no home and stays
  dropped; PAM4 precoding is not controllable over the message bus (it is presumably PHY-internal or
  negotiated in-band).
- **Rx Control registers (for reference):** 12'h2 Elastic Buffer Depth and 12'h3 Rx Control0 (RxPolarity),
  12'h7 EB update frequency, 12'h8 Rx Control4 and 12'h9 Rx Control5 (`RxLaneEnable`, USB4/DP) — N/A or
  irrelevant for SerDes/PCIe here; 12'h5 Rx Control2 is entirely reserved; 12'h6 Rx Control3
  (`InvalidRequest`, `RxEqInProgress`, `RxEqEval`) is also link-training territory.
- **Still unverified:** how the message bus scales to more than one lane (TX1/RX1 vs TX2/RX2 regions);
  whether the LocalPresetIndex-only write is sufficient for a given PHY.
- **Port-list change:** this alters the frozen top-level interface (2 ports replace 4).
  Integrators using the old split ports must update.
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

**Resolution: keep "sticky ERR and proceed"; do not change the RTL.** Holding in an
error state would need a new FSM state, a recovery path and re-proving formal + all five
envs, and it is unverifiable without a real PHY (the DV model is the only PHY). The
present behaviour never wedges the control plane and is visible (ERR[0]/ERR[1], W1C,
plus `ev_phy_timeout`). Accepted risk: after a PhyStatus timeout the bridge continues as
if the PHY had complied, so a truly dead PHY would receive flits into the void until
software reads ERR. **Also noted:** `PHY_TIMEOUT = 1024` pclk is a *simulation* value.
A vendor PIPE document (Efinix, not the spec) describes a controller waiting on the
order of **10 ms** for a WriteAck; at ~1 GHz that is ~10^7 cycles. The integrator should
raise `PHY_TIMEOUT` (the pkg constant) to the spec/PHY figure; the timeout tests use the
small value to stay fast. Revisit the hold-in-error alternative when a real PHY exists.

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

## D13. Assertions and formal (M5)

No DUT behaviour changes; verification-method decisions only.

- **SVA runs in the Verilator envs only.** `dv/sva` checkers are bound (`bind`) in
  `dv/vlt`, `dv/systemc`, `dv/uvm` with `--assert`. PLAN T5.1 said "vlt + cocotb";
  cocotb runs on Icarus, which cannot evaluate concurrent SVA, so cocotb is not a
  SVA host. (Moving cocotb to Verilator would change that; not done.)
- **Sim SVA covers are reported, not gated.** `c_b2b_flits` is currently unhit
  because the Tx framer is single-buffered (M1 limitation) — kept as a visible
  gap rather than removed.
- **Coverage accounting:** `cov_summary.py` now counts only `rtl/` line/branch/
  toggle points (the bound checkers add their own points, which must not inflate
  the 80% floor). Numbers are unchanged from M4.
- **Formal = PDR prove + BMC cover**, not BMC-only as PLAN §8 says: `abc pdr` gives
  unbounded proofs in seconds (whole `make formal` ~75 s), so there was no reason to
  settle for a bounded result. Every `.sby` also has a `cover` task.
- **Formal frontend:** `ctrl.sby` uses the yosys-slang plugin (native Yosys cannot
  parse module-header package imports). It needs the pinned OSS CAD Suite; apt
  Yosys cannot run `make formal`. The CI `formal` job now installs the suite.
- **Hierarchical references in `ctrl_fv.sv`:** four `h_*` helper invariants read the
  RTL timers (`u_ctrl.tmr_q`, `u_mb.st_q`, `u_mb.tmr_q`). They are proven like any
  other assertion; they only exist so PDR converges (without them the two
  PHY_TIMEOUT-bound properties did not finish in 10+ minutes). If the RTL renames
  those registers, the proof fails to elaborate — intended.
- **FIFO proof is black-box** (shadow counters from the handshakes, small W=4 /
  DEPTH=4 instance). Gray single-bit change is simulation-only (CD3).

## D14. Power intent (M6)

UPF is authored, not run (no OSS power-aware simulator). No RTL changes.

- **`bridge_rf` in PD_AON** (PLAN §9 had it in PD_DP, retained): the AON control FSM
  reads `pwr_req` from it and the CSR port is the only wake-up path, so it cannot be
  powered off. With rf always-on, it needs no retention.
- **PD_DP fully retained.** The RTL has no datapath-local reset / power-good, so
  non-retained state would wake up corrupted with nothing to clear it. Retaining all
  PD_DP state is correct because the FSM drains the datapath before P1/P2; it costs
  retention area. **Owner decision needed** for the alternative (RTL: DP reset on
  power-up + power-good into the FSM; retain only Rx counters).
- **Isolation clamps:** 0 by default; 1 for the drain/idle flags the FSM reads
  (`tx_cdc.rempty`, `tx_framer.idle`, `rx_ingress.idle`, `tx_gate.stopped`), so an
  isolated datapath reads as drained. Rx counters read 0 over CSR while PD_DP is off.
- **No FSM<->PMU handshake** (the DUT has no power ports): the DV-only PMU's
  power-up (~6 pclk) must complete within the PHY's PhyStatus latency for P1->P0
  (8 pclk in the DV model). `make upf-tb` checks this; a real design should add a
  power-good input to the FSM (RTL change, open).
- **PMU arming:** power-down only after a CSR request for P1/P2 (the post-reset
  link-up also starts in P1 and must not power the datapath down).
- `make upf-tb` (functional Icarus run of the power-aware TB) is added as a step in
  the CI `regress` job; `make regress` itself is unchanged.

**Resolution: accept the current design — full PD_DP retention, `bridge_rf` in PD_AON,
no FSM<->PMU handshake; no RTL change.** Rationale: the alternative (datapath reset on
power-up + a power-good input into the FSM) changes the frozen top-level port list,
the FSM, the PMU, the power TB and the formal proofs, and its only benefit is retention
area, which cannot be measured without a power-aware tool that is not available here.
Full retention is always correct given that the FSM drains the datapath before P1/P2,
and the PMU-latency assumption (power-up within the PhyStatus latency) is checked by
`make upf-tb`. **Revisit when the UPF can be run on a commercial tool** and area is
measurable; at that point a power-good input is the recommended RTL change. The UPF
remains authored-not-run.

## D15. Infra (M7)

No DUT changes.

- **Waves:** tests dump **VCD** only when built with `WAVES=1` (an extra top,
  `dv/waves/wave_dump.sv`, depth 1 on `<tb>`, `<tb>.dut`, `<tb>.dut.u_ctrl`, so the
  FIFO arrays are not dumped; pm = 15 MB). `.gtkw` files are generated by
  `wave_check.py gen`. `wave-check-all` runs in the CI regress job (static check:
  every session signal exists in the dump and clocks/reset/state toggle); locally,
  with gtkwave + xvfb installed, it also loads each session headless. No `.gtkw` for
  the Verilator FST trace.
- **Metrics:** throughput is a *whole-run average in simulated time* from the vlt
  run (includes resets/control/idle): labelled measured with that caveat.
  Resource numbers are **estimated** from a Yosys coarse elaboration (flop/memory
  bits, word-level cells), because a full `synth` of the 256-bit datapath took
  > 10 min. Latency, Fmax, area and per-agent swarm usage are **not_attributable**.
  `metrics.db` / `dashboard.html` are committed with the real bring-up run (run 1,
  recorded on an uncommitted tree — the dirty flag says so).
- **Docker/Railway:** Ubuntu 24.04; OSS CAD Suite goes **last** on PATH so
  `python3`/`iverilog` resolve to the venv/apt copies (the suite ships its own
  python + cocotb 2.x). The entrypoint runs every flow incl. uvm and formal via
  `make metrics`, then crosscheck + dashboard. Railway: DOCKERFILE builder,
  restart NEVER, nightly cron `17 3 * * *` (UTC) — drop the cron to run on deploy only.
- **Swarm:** `docker/swarm.sh` runs `claude -p` non-bare with the task file;
  another Anthropic-compatible provider can be used via `ANTHROPIC_BASE_URL` +
  `ANTHROPIC_AUTH_TOKEN`. The CLI JSON gives tokens per model, not per agent, so
  the agent column is "all". `swarm.yml` is `workflow_dispatch` only.

## D16. Two-ended link flow control (opt-in)
- **Problem:** D9 (drop + abort on Rx overload) is a one-ended remedy; the sender never learns of it.
- **Decision:** credit-based flow control, **compile-time opt-in** (`-DFLOW_CTRL_OVERRIDE`, both ends must agree; default off, default behaviour bit-identical to before). Every flit carries, in the DLP area (bytes 242..245), `seq` (data flits sent, 16b) and `cl` (cumulative credit limit, 16b). A flit with count 0 and sof=eof=0 is a credit-only flit, sent when the advertised limit is stale and there is no data to carry it.
- **Credits:** one credit = `CREDIT_BEATS_PER_FLIT`=9 Rx CDC FIFO beats (worst case per flit); `INIT_CREDITS`=FIFO_DEPTH/9 = **3** at depth 32 (small; raise FIFO_DEPTH to trade area for throughput).
- **Loss repair:** Rx tracks the expected `seq`; a gap aborts the affected frame (`eth_rx_tuser[0]`), and the lost flits are added back to the advertised limit so credit is not leaked. At most one frame lost per lost flit.
- **Caveats:** DLP bytes 242..245 are no longer zero when enabled (DLP is a placeholder anyway); loss of consecutive credit-only flits is repaired by the next flit; 16-bit modular counters assume < 32768 flits in flight (always true).
- **Verification:** `dv/iverilog/tb_link.sv` (two bridges cross-connected, flit killer): bidirectional, stalled sink (back-pressure, zero drops), slow sinks, 5 killed flits (no silent corruption), post-loss credit restored to INIT_CREDITS. Mutation: removing credit gating fails P2. Removing loss repair: run did not terminate (credit leak -> stall, caught only by the global timeout), not a clean FAIL line. Not run with flow control on: UVM/cocotb/SystemC/vlt envs, formal (tie-offs only), lanes4.
- **D16 follow-up (verification):** single-ended runs with flow control ON (`make -C dv/iverilog fc`, in regress): `loop`, `pm` and the five shared scenarios (identical frames/bytes/flits/crc/pmcnt to the golden model; the DUT sees its own advertisements through the loopback). **Bug found and fixed:** PM failed with FC on ("Tx data_valid during a rate/width/power change") because a credit-only flit could start in the same cycle the FSM left DRAIN; `tx_idle` now includes `!fc_cr_req` (a wanted credit-only flit counts as Tx activity; constant 0 with FC off, so default behaviour is unchanged). `rxovf` is not run with FC on (it forces overload; with FC on the same stimulus gives good 110 / aborted 0 / dropped 0). `tb_link` now fails cleanly (global timeout 2 ms sim) if credit leaks: removing loss repair -> "LINK FAIL: global timeout" in ~25 s. **Still not run with FC on:** vlt/systemc/uvm/cocotb (their PHY BFMs do not source credits; need a credit-advertising peer model).
- **D16 follow-up 2 (vlt/systemc/uvm/cocotb with FC on):** these envs loop `pipe_tx` back into `pipe_rx` (like iverilog's `loop_harness`), so the DUT sees its own credit advertisements; hypothesis confirmed, **no peer model added**. Changes: `-DFLOW_CTRL_OVERRIDE` `fc` targets per env (separate build/result dirs) and FC-aware flit checkers (`dv/common/cpp/bridge_bfm.h` for vlt+systemc, `bridge_uvm_pkg.sv`, `bridge_env.py`), mirroring `pipe_phy_model.sv`: credit-only flits (count 0, sof=eof=0) are legal and not counted as flits, bytes 242..245 exempt from the zero check, `seq` must equal data flits sent since reset. The checks also apply with FC off (nothing was checked there before; default results unchanged and still match the golden model). Flit counts are taken at flit completion. Shared-scenario crosscheck passes with FC on in all four (identical frames/bytes/flits/crc/pmcnt to the golden model). Every FC run fails if zero credit-only flits were seen. `rxovf` (vlt/systemc/cocotb, coverage-only) flips: with FC on the overload stimulus must give 60 good frames and no aborted frame. **Mutation evidence:** `seq_now = s_cnt_q + 1` fails all four envs ("flow-control seq field != data flits sent before"); `credit_ok = 1` fails vlt, systemc, cocotb (rxovf: frame aborted although credit flow control is on) but **is not caught by UVM** (no overload scenario; only seq/format checks and crosscheck apply there). No RTL change was needed. Still not run with FC on: formal beyond `fc.sby`, iverilog `rxovf`, lanes4 with FC.
