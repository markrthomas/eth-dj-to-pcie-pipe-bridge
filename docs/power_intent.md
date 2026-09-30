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

## Not verified (needs a commercial PA simulator)

- That `bridge.upf` parses, and that the element and pin paths resolve. They follow the RTL instance names but have never been elaborated.
- Corruption of PD_DP while it is off, the clamp values in action, and retention save/restore behaviour.
- The legality of the power states / PST.

To run on a PA flow:
1. Compile `lp/tb_pipe7_upf_power.sv` and `lp/pipe7_pmu.sv` with `+define+UPF_SIM`, together with the RTL and `dv/common` BFMs (see `lp/Makefile`).
2. Load `lp/bridge.upf` at `tb_pipe7_upf_power`.
3. Run and look for `UPF-TB PASS`.
