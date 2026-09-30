# ASSERTIONS — property inventory

`rtl/` is assertion-free. Simulation properties are bound in from `dv/sva/`;
formal properties live in `formal/*_fv.sv`. See docs/PLAN.md §7 and
docs/OPEN_DECISIONS.md D13.

**Where each kind runs**

| Kind | Files | Runs in | Tool |
|---|---|---|---|
| Sim SVA (`a_*`, `c_*`) | `dv/sva/bridge_sva.sv`, `dv/sva/async_fifo_sva.sv` (bound with `bind`) | `dv/vlt` (`make coverage`), `dv/systemc`, `dv/uvm` | Verilator `--assert` (5.020 and 5.047) |
| Formal (`a_f*`, `h_*`, `c_*`) | `formal/*_fv.sv` + `formal/*.sby` | `make formal` | SymbiYosys: `abc pdr` prove, `smtbmc yices` cover |

A failing sim assertion aborts the run, so the env fails. SVA cover hit counts
are printed by `make coverage` (from `coverage.dat`, not gated). **Not bound:**
`dv/iverilog` and `dv/cocotb`, because Icarus has no concurrent-SVA support.

## Simulation SVA (dv/sva)

| ID | Property (assert name) | Clock | File |
|---|---|---|---|
| AX1 | Egress `eth_rx_*` holds tvalid/tdata/tkeep/tlast/tuser until accepted (`a_ax1_rx_stable`) | eth_clk | bridge_sva.sv |
| AX2 | Egress tkeep is nonzero and contiguous from byte 0; all-ones unless tlast (`a_ax2_rx_keep`) | eth_clk | bridge_sva.sv |
| AX3 | `eth_rx_tuser[0]` (abort, D9) only on tlast; `tuser[7:1]` = 0 (`a_ax3_rx_tuser`) | eth_clk | bridge_sva.sv |
| AX4 | Environment check: the MAC BFM holds its beat until accepted (`a_ax4_src_stable`) | eth_clk | bridge_sva.sv |
| FF1 | Ingress never accepts into a full Tx CDC FIFO (`a_ff1_tx_no_overflow`) | eth_clk | bridge_sva.sv |
| FF2 | The deframer never pushes into a full Rx CDC FIFO (`a_ff2_rx_no_overflow`) | pclk | bridge_sva.sv |
| FF3 | The framer never pops an empty Tx CDC FIFO (`a_ff3_tx_no_underflow`) | pclk | bridge_sva.sv |
| FF4 | Egress never pops an empty Rx CDC FIFO (`a_ff4_rx_no_underflow`) | eth_clk | bridge_sva.sv |
| PP1 | `pipe_tx_data_valid` only in P0 and in ST_ACTIVE/ST_DRAIN (`a_pp1_tx_only_p0`) | pclk | bridge_sva.sv |
| PP2 | `pipe_tx_start_block` only on a valid beat at a flit boundary (`a_pp2_sb_boundary`) | pclk | bridge_sva.sv |
| PP3 | A flit is FLIT_BEATS contiguous valid beats, with no headless beat (`a_pp3_*`) | pclk | bridge_sva.sv |
| PP4 | rate/width/powerdown pins change only in ST_RATE_CHG/ST_WIDTH_CHG/ST_PWR_CHG (`a_pp4_*`) | pclk | bridge_sva.sv |
| PP5 | A pin-change state lasts at most PHY_TIMEOUT cycles (`a_pp5_phystatus_bound`) | pclk | bridge_sva.sv |
| MB1 | No msgbus request while one is outstanding (`a_mb1_one_outstanding`) | pclk | bridge_sva.sv |
| MB2 | write_ack/timeout consumed only in ST_CFG, and never both at once (`a_mb2_done_in_cfg`) | pclk | bridge_sva.sv |
| MB3 | 8-bit byte-bus framing (D8): byte0 `{WR_C, addr[11:8]}`, byte1 `addr[7:0]`, then data; idle 8'h00 outside the frame (`a_mb3_byte0`, `a_mb3_byte1`, `a_mb3_idle`) | pclk | bridge_sva.sv |
| MB4 | No PIPE pin change while a msgbus write is outstanding (`a_mb4_no_pin_chg_during_mb`) | pclk | bridge_sva.sv |
| MB5 | ST_CFG lasts at most PHY_TIMEOUT+3 cycles (`a_mb5_cfg_bound`) | pclk | bridge_sva.sv |
| CD1 | True occupancy (wbin − rbin) ≤ DEPTH, checked on both clocks (`a_cd1_*`) | wclk, rclk | async_fifo_sva.sv |
| CD2 | A read pops only written data; a write never lands on unread data (`a_cd2_*`) | wclk, rclk | async_fifo_sva.sv |
| CD3 | Gray pointers change by at most one bit per clock (`a_cd3_*`) | wclk, rclk | async_fifo_sva.sv |

**Covers:**
- bridge_sva: `c_b2b_flits`, `c_p2`, `c_gen5`, `c_width1`, `c_mb_ack`, `c_phy_timeout`, `c_rx_drop`, `c_rx_fifo_full`, `c_tx_fifo_full`, `c_rx_abort`.
- async_fifo_sva: `c_full`, `c_empty_after_data`.

**Latest run** (`make coverage`, Verilator 5.020): 11 of 12 cover points were hit. **`c_b2b_flits` is never hit.** The Tx framer is single-buffered (M1 limitation), so two flits never go out back to back.

## Formal (formal/)

| ID | Property | Proof | Result (local, OSS CAD Suite 2026-04-13) |
|---|---|---|---|
| F-CD1 | async_fifo occupancy ≤ DEPTH (`a_fcd1_occupancy`) | async_fifo.sby, PDR, multiclock | PASS |
| F-CD2 | async_fifo !rempty ⇒ data present (`a_fcd2_no_underrun`) | async_fifo.sby | PASS |
| F-CD4 | async_fifo data integrity, tracked-word check (`a_fcd4_integrity`) | async_fifo.sby | PASS |
| F-IG1 | Ingress gate never accepts while full (`a_fig1_no_accept_full`) | ingress_gate.sby, PDR | PASS |
| F-IG2 | A started frame is never blocked except by full (`a_fig2_frame_finishes`) | ingress_gate.sby | PASS |
| F-IG3 | With stop held ≥ 2 cycles, no new frame is accepted (`a_fig3_no_new_frame`) | ingress_gate.sby | PASS |
| F-IG4 | `stopped` only between frames and while stopping (`a_fig4_stopped_between`) | ingress_gate.sby | PASS |
| F-PP1 | Tx valid only in P0 and ST_ACTIVE/ST_DRAIN (`a_fpp1_tx_only_p0`) | ctrl.sby, PDR | PASS |
| F-PP3 | Flit framing: contiguous beats, start_block at the boundary (`a_fpp3_*`) | ctrl.sby | PASS |
| F-PP4 | Pins change only in their change state (`a_fpp4_*`) | ctrl.sby | PASS |
| F-PP5 | A pin-change state lasts at most PHY_TIMEOUT cycles (`a_fpp5_chg_bound`) | ctrl.sby | PASS |
| F-MB1 | One msgbus op outstanding (`a_fmb1_one_outst`) | ctrl.sby | PASS |
| F-MB3 | m2p byte-bus framing incl. data byte value and idle (`a_fmb3_byte0`, `a_fmb3_byte1`, `a_fmb3_data`, `a_fmb3_idle`) | ctrl.sby | PASS |
| F-MB4 | No pin change during a msgbus write (`a_fmb4_no_chg_in_mb`) | ctrl.sby | PASS |
| F-MB5 | msgbus busy ≤ PHY_TIMEOUT+3 cycles (`a_fmb5_busy_bound`) | ctrl.sby | PASS |
| helpers | `h_chg_tmr`, `h_mb_addr`, `h_mb_data`, `h_mb_wait`: bound counters equal the RTL timers (proven, so PDR converges) | ctrl.sby | PASS |

All covers were reached in the `cover` tasks:
- async_fifo: `c_full`, `c_wrapped_twice`
- ingress_gate: `c_stop_after_frame`, `c_accept_mid_stop`
- ctrl: `c_tx_flit`, `c_p2`, `c_gen5_active`, `c_cfg_ack`, `c_drain_flit`

**Mutation checks.** Each mutant was applied, the check was run, and the code was restored.

| Mutant | Caught by |
|---|---|
| async_fifo full flag late by one entry | F-CD1 (counterexample at step 10) |
| Ingress gate ignores stop between frames | F-IG3 |
| `tx_en` also high in ST_RATE_CHG | F-PP1 |
| msgbus timeout 8 cycles late | `h_mb_wait` (step 1032) |
| msgbus sends WR_C in the data phase | sim MB3 in `dv/vlt`. The same mutant **passes** with `SVA=0`, because the C++ PHY model does not check it. |
| msgbus swaps the address and data bytes (D8 byte-bus port) | SVA `a_mb3_byte1` (dv/vlt, `--assert`) and formal `a_fmb3_byte1` (ctrl.sby prove fails at step 7); the iverilog smoke test also fails |

## Not covered by any property
- The Rx path internals (`rx_ingress`, `rx_deframer`). These are checked end to end by the scoreboards and `tb_rxovf`.
- Formal proofs that span both clock domains at top level.
- CD3 (Gray code) is checked in simulation only.
- UPF / power-aware behaviour (M6; no OSS tool).
