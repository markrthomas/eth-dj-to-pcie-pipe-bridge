// ============================================================================
// dv/waves/wave_dump.sv — optional second top-level module that dumps a test to
// VCD when run with +dumpfile=<path>.  Compiled in only with WAVES=1
// (dv/iverilog/Makefile, lp/Makefile), with -DDUMP_TOP=<tb module>.
// Dumps the TB top scope, the DUT top scope and the control FSM (depth 1 each,
// so the 256-bit FIFO arrays are not dumped).  Scopes match dv/waves/*.gtkw.
// ============================================================================
`ifndef DUMP_TOP
  `define DUMP_TOP tb_loop
`endif
module wave_dump;
  string f;
  initial begin
    if ($value$plusargs("dumpfile=%s", f)) begin
      $dumpfile(f);
      $dumpvars(1, `DUMP_TOP);
      $dumpvars(1, `DUMP_TOP.dut);
      $dumpvars(1, `DUMP_TOP.dut.u_ctrl);
    end
  end
endmodule
