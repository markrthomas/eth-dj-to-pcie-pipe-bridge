# PD_DP power-state emulation (UPF-like, no power tool)

`make pd-emu` (= `make -C lp/cocotb pd`, ~45 s, cocotb 1.8.1 on Icarus, runs in the CI `cocotb` job)
emulates what `lp/bridge.upf` would do in a power-aware simulator, without one:

| UPF intent | Emulation (`lp/cocotb/pd_emu.py`) |
|---|---|
| `PD_DP` supply off | every pclk while `dp_pwr_en = 0`, all PD_DP state registers get random values (random, not X, so Icarus keeps running) |
| `set_retention` save / restore | on the PMU's `dp_save` pulse the retained groups are snapshotted; on `dp_restore` they are written back |
| `set_isolation` (clamp 0 / 1) | while `dp_iso_en = 1` the PD_DP outputs the always-on logic reads (`tx_fifo_empty`, `framer_idle`, `rx_ing_idle`, `ingress_stopped_eth` -> 1; `egress_busy`, Rx counters -> 0) are forced; the models ignore the PD_DP outputs on the DUT ports |
| PMU sequencing | the real DV PMU `lp/pipe7_pmu.sv` inside `lp/cocotb/pd_top.sv` (bridge with Tx->Rx loopback + PMU) |

Test (`lp/cocotb/test_pd.py`): reset, 6 frames, CSR request P1, wait until the PMU powers PD_DP off,
hold 120 pclk, CSR request P0, 6 more frames. Every frame must arrive intact and in order, no Rx
drop/abort, FSM back in P0, exactly one PMU down/up episode. Each configuration runs with 3
corruption seeds and passes only if all pass.

## Results (RTL register bits; the datapath is drained before power-down)

| configuration | result |
|---|---|
| no power cycle (environment check) | PASS |
| retain everything (D14 decision) | PASS |
| retain nothing (negative control) | **FAIL** - P0 wake timeout, the FSM never leaves the power change |
| greedy minimal retained set | PASS with **318 of 31,751 bits (1.0 %)**, 57 registers (`lp/cocotb/retention_min.txt`) |

Groups that **must** be retained: the narrow (< 64 bit) state of `u_tx_gate`, `u_tx_cdc`,
`u_tx_framer`, `u_rx_ingress`, `u_rx_deframer`, `u_rx_cdc` (FIFO pointers / flags / sync flops, frame
and lock state, counters). Groups that need **no** retention (corrupting them still passes): both CDC
FIFO memory arrays (18,528 bits), every wide register (flit buffers, accumulators; 12,864 bits) and
all of `u_tx_egress`; `u_eth_egress` has no state.

Single-group sensitivity is not additive (corrupting `u_tx_gate/ctl` alone already breaks the wake-up),
which is why the minimal set comes from greedy elimination, not from the single-group table.

## What it supports (D14) and what it does not
- The current UPF's *full* retention is a large over-provision: retaining ~300 control bits is
  enough in this scenario, i.e. ~99 % fewer retention flops. A sharper UPF would use `set_retention
  -elements` on that register list (not changed here: the UPF is still authored-not-run).
- The alternative "datapath reset on power-up" is **not testable** here: the RTL has no datapath-local
  reset, and corrupt-then-global-reset would reset the always-on FSM too. It needs the RTL change D14
  already names.
- Limits: RTL registers (VPI) include `always_comb` targets (recomputed; they inflate the 318 bits and
  the register list, so both are upper bounds); one traffic pattern, one power-down depth (parked in
  P1 after the datapath drained, never mid-frame); 3 seeds; random-value corruption, no X propagation,
  no power-up glitches, no supply-ramp or isolation-cell timing; the PMU/UPF correctness itself is not
  checked by this (only the retention requirement and the wake-up behaviour).
