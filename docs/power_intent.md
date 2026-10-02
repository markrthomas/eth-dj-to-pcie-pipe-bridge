# Power intent — eth_dj_pipe7_bridge

**Status: authored, not run.** No OSS simulator here models UPF supplies,
isolation, retention or corruption. `lp/bridge.upf` has **not been parsed or
simulated by any tool**. What *has* been run is a functional (not power-aware)
Icarus simulation of the power-aware TB (`make upf-tb`), which checks the PMU
sequencing and the timing assumption below. Nothing in this document is a
power-aware simulation result.

## Files

| File | What |
|---|---|
| `lp/bridge.upf` | IEEE 1801 (UPF 2.1) power intent, scoped at `tb_pipe7_upf_power`. |
| `lp/tb_pipe7_upf_power.sv` | Power-aware TB top: the bridge on the shared loopback harness plus `u_pmu`. `+define+UPF_SIM` turns on `supply_on` calls for a PA simulator. |
| `lp/pipe7_pmu.sv` | DV-only power sequencer. **Not part of the DUT.** Drives `dp_pwr_en`, `dp_iso_en`, `dp_save`, `dp_restore`. |
| `lp/Makefile` | `upf-tb`: functional Icarus run (no power semantics). |

`make upf` prints the "authored, not run" notice and exits 0. `make upf-tb`
runs the functional TB and fails on any error.

## Architecture

| Domain | Supply | Contents | Why |
|---|---|---|---|
| **PD_AON** | SS_AON (VDD) | TB, DUT top glue, `u_ctrl` (bridge_ctrl_fsm), `u_msgbus` (pipe_msgbus; 8-bit M2P/P2M byte bus, 12-bit address), `u_rf` (bridge_rf), `u_pmu` | Sequences P1/P2 entry and exit and must stay alive to wake the link. |
| **PD_DP** | SS_DP (VDD_DP, switched by SW_DP) | `u_tx_gate`, `u_tx_cdc`, `u_tx_framer`, `u_tx_egress`, `u_rx_ingress`, `u_rx_deframer`, `u_rx_cdc`, `u_eth_egress` (both clock domains) | The datapath is idle in P1/P2 after a drain. |

- **`bridge_rf` is in PD_AON**, which changes PLAN §9. That draft placed it in PD_DP with retention, but the AON FSM reads `pwr_req` from it, and a CSR write is the only way to request wake-up. So it cannot be switched off (OPEN_DECISIONS D14).
- **Isolation** (`-location parent`, supplied from SS_AON, enabled by `dp_iso_en` active high):
  - All PD_DP outputs clamp to 0 by default. This covers the Ethernet handshakes and data, PIPE Tx, the egress busy flag and the Rx counters, so CSR RXCNT reads 0 while PD_DP is off.
  - Four drain-status outputs clamp to 1: `u_tx_cdc/rempty`, `u_tx_framer/idle`, `u_rx_ingress/idle`, `u_tx_gate/stopped`. The AON FSM therefore sees an isolated datapath as drained and idle.
- **Retention:** all PD_DP state is retained (save before power-off, restore after power-on).
  - This is needed because the RTL has **no datapath-local reset or power-good input**. Without retention, PD_DP would wake with corrupted pointers or flags and nothing would clear them.
  - Retaining everything is only correct because the ctrl FSM drains the datapath before P1/P2: the FIFOs are empty and no frame is in flight.
  - It is area-expensive. The alternative is an RTL change: a DP reset on power-up, keeping only the Rx diagnostic counters. That needs an owner decision.
- **Level shifters:** none, since both domains run at the same voltage when on.

## PMU sequence (lp/pipe7_pmu.sv)

1. **Arm:** a CSR CTRL write requests P1 or P2. The PMU never powers down during the reset link-up, even though that also starts in P1.
2. **Power down:** once `pipe_powerdown` has been P1/P2 for `DOWN_DELAY` (16) pclk, the PMU does `iso_en=1`, then pulses `save`, then sets `pwr_en=0`.
3. **Power up:** on a CSR CTRL write that requests P0/P0s, the PMU sets `pwr_en=1`, waits `PWR_UP_CYC` (2), pulses `restore`, then sets `iso_en=0`. This takes about 6 pclk in total.

**No handshake with the FSM:** `bridge_ctrl_fsm` does not know about the PMU.
- After the wake-up CSR write, the FSM goes LOWPWR → PWR_CHG (pin to P0). It waits for PhyStatus, then enters DRAIN, which reads the datapath idle flags.
- This works only if power-up finishes within the PhyStatus latency of the P1→P0 change. That latency is 8 pclk in the DV PHY model.
- A real implementation should add a power-good input so the FSM waits for it. That is an RTL change; it is listed as an open item.

## What `make upf-tb` checks (functional only)

- **Sequence order:**
  - `save` happens only while isolated.
  - Power goes off only after isolation and save.
  - `restore` happens only while powered.
  - Isolation is released only after power-on and restore.
- **Timing assumption:** whenever the FSM is outside `ST_RESET`, `ST_LOWPWR` or `ST_PWR_CHG`, PD_DP is powered and not isolated. There is also no Tx data while isolated.
- **Low-power episodes:** it runs one P1 episode and one P2 episode, and PD_DP really powers down and up twice.
- **Traffic:** frames sent before, between and after the episodes arrive byte-exact and in order.
- **Negative checks:** each mutant was applied, the TB was run, and the code was restored.
  - With `PWR_UP_CYC=20`, the timing check fires.
  - Powering off in the same step as `save` makes the sequence-order check fire.

## Not verified (needs a commercial power-aware simulator; none available, none planned)

- That `bridge.upf` parses, and that the element and pin paths resolve. They follow the RTL instance names but have never been elaborated.
- Corruption of PD_DP while it is off, the clamp values in action, and retention save/restore behaviour.
- The legality of the power states / PST.

`make upf` automates this when vcs / xrun / vsim is on PATH (command lines untested); otherwise it reports the missing tool and exits 0. By hand:
1. Compile `lp/tb_pipe7_upf_power.sv` and `lp/pipe7_pmu.sv` with `+define+UPF_SIM`, together with the RTL and `dv/common` BFMs (see `lp/Makefile`).
2. Load `lp/bridge.upf` at `tb_pipe7_upf_power`.
3. Run and look for `UPF-TB PASS`.

## OSS power flow (zero-cost; area + power estimates, NOT power-aware simulation)

`lp/oss/` (README there) maps the bridge to the Nangate45 liberty with Yosys, checks the gate-level
netlist with the existing Verilator harness (7 scenarios, golden-model crc32s identical to the RTL),
runs an Icarus gate-level window for switching activity and reports power with OpenSTA (pip
`openroad` wheel). Numbers re-measured on the default build with the datapath-local reset (D18, 2026-10-01; first numbers were 373,634 um2 / 154.5 mW on the pre-D18 RTL; also on the metrics dashboard, kind=estimated; 2 us of the `random`
scenario, pclk 500 MHz / eth_clk 200 MHz, Nangate45 45 nm typical, no clock tree / parasitics):

| | |
|---|---|
| area | 378,070 um2, 32.8 % sequential; PD_DP instances 361,760 (95.7 %), the rest 16,310 |
| biggest | `u_tx_framer` 139,000; the two CDC FIFOs 75,000 + 74,800; `u_rx_deframer` 39,900; `u_rx_ingress` 29,700; `u_msgbus_tgt` 14,800 |
| power | **154.1 mW** = 137.4 internal + 9.0 switching + 7.6 leakage |
| by domain | PD_DP 150.4 mW (97.6 %), always-on + glue 3.6 mW; leakage in PD_DP 7.29 of 7.64 mW |
| by block | `u_rx_cdc` 62.5, `u_tx_cdc` 50.2, `u_tx_framer` 17.3, `u_rx_ingress` 10.9, `u_rx_deframer` 5.1, `u_tx_egress` 4.5, `u_msgbus_tgt` 3.2 mW |

Effect of the D18 flip (new vs the earlier run): area +1.2 % (+4,436 um2), power -0.3 %. The reset
itself adds almost nothing: the datapath flops already had an async reset, only the net driving it
changed, plus `dp_low_q`, a 2-flop synchroniser and the Rx-drain hold counter. The only large per-block
change is `u_tx_framer` (+3.7 % area, +7.6k cells) although `tx_framer.sv` has not changed since M3 -
not isolated (possibly the earlier run used an older netlist or mapping variation); `u_msgbus_tgt`
shrank by 314 cells. Treat sub-5 % differences as inside the noise of this flow.

What this tells us: the datapath (PD_DP) is ~96 % of the area and ~98 % of the power, so gating or
shrinking it is where the savings are; the CDC FIFO arrays alone are ~73 % of the power (flop arrays -
SRAM/latch macros or clock gating would cut this a lot, so treat it as pessimistic);
`msgbus_mac_tgt` (the new MAC register file + write buffer, D17) costs ~4 % of the area for
registers nothing in the bridge reads - candidate to shrink or make optional.
What it does **not** tell us: retention area (Nangate45 has no retention flops), the saving from
power gating beyond an upper bound (PD_DP leakage), isolation / header-switch overhead, and whether
`bridge.upf` is correct - the UPF is still authored-not-run. A UPF-like *power-state* simulation
(random corruption of PD_DP state at power-off, isolation clamps, retention, driven from cocotb)
is **not built**; D14's "full retention vs DP reset" question therefore remains unmeasured.

