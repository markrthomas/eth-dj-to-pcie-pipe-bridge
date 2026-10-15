# formal — SymbiYosys

`make formal` (root) runs `make -C formal`: each `*.sby` has a **prove** task
(`abc pdr`, unbounded) and a **cover** task (`smtbmc yices`). Property modules are
`*_fv.sv`; the property IDs (`F-*`) are listed in `../ASSERTIONS.md`.

| .sby | Design under proof | What |
|---|---|---|
| `async_fifo.sby` | `async_fifo` (W=4, DEPTH=4), `multiclock on`, free wclk/rclk | occupancy <= DEPTH, no underrun, data integrity (black-box, shadow counters) |
| `ingress_gate.sby` | `tx_ingress_gate` | no accept while full, started frame finishes, no new frame once stopped, `stopped` only between frames |
| `ctrl.sby` | `bridge_ctrl_fsm` + `pipe_msgbus` + `tx_egress` | Tx only in P0/ACTIVE/DRAIN, flit framing, pins change only in their change state, PhyStatus/msgbus bounds, one msgbus op outstanding |

Tooling (no OSS CAD Suite): SBY + a slang-capable Yosys + yices/z3, built from
source in the `Dockerfile`. `ctrl.sby` uses the yosys-slang frontend; upstream
Yosys has it built in (`read_slang`), while the OSS CAD Suite shipped it as a
loadable plugin (`plugin -i slang`) — `formal/Makefile` adapts to either. apt
Yosys does not ship it. `ctrl_fv.sv` also contains four `h_*` helper
invariants that read RTL timers through hierarchical references (slang resolves
them); they are proven like the other assertions and exist so PDR converges in
seconds instead of searching the 1024-cycle timeout space.
Not proven formally: CDC Gray-code single-bit change (sim SVA CD3 only), the Rx
path (rx_ingress / rx_deframer), and anything spanning both clock domains at the
top level.
