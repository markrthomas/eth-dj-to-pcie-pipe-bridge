# dv/sva — SystemVerilog assertions (bind-based)

The DUT stays assertion-free; checkers are bound in from here (docs/PLAN.md §7):

- `bridge_sva.sv` — bound into `eth_dj_pipe7_bridge`: AXI4-Stream legality on the
  Ethernet egress (and the MAC BFM), PIPE Tx legality + flit framing, pin changes
  only in their change state, PhyStatus / message-bus ordering and bounds, CDC
  FIFO push/pop guards, plus cover properties.
- `async_fifo_sva.sv` — bound into every `async_fifo`: true occupancy <= DEPTH,
  no underrun/overrun, Gray pointers change one bit per clock.

Compiled with Verilator `--assert` in `dv/vlt`, `dv/systemc`, `dv/uvm`
(`SVA=0` on those Makefiles builds without them). Icarus (`dv/iverilog`,
`dv/cocotb`) cannot evaluate concurrent SVA, so they are not bound there.
Property list and IDs: `../../ASSERTIONS.md`.
