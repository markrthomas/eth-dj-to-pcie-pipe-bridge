# lp — UPF power intent (authored, not run)

- `bridge.upf` — IEEE 1801 (UPF 2.1): PD_AON (ctrl FSM, msgbus, CSRs, glue) +
  PD_DP (switchable Tx/Rx datapath, fully retained, isolated). Scoped at the TB top.
- `tb_pipe7_upf_power.sv` — power-aware TB top (bridge + loopback harness + PMU).
- `pipe7_pmu.sv` — DV-only power sequencer (iso -> save -> off; on -> restore -> de-iso).
- `make upf` prints the authored-not-run notice (no OSS power-aware simulator).
- `make upf-tb` runs the TB on Icarus **without** power semantics: checks PMU
  sequencing, the no-handshake timing assumption and traffic across P1/P2.

Details and what is not verified: `../docs/power_intent.md`.
