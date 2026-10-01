// lp/oss/gls_dump.sv — second top for the Icarus gate-level run: dumps the DUT's switching
// activity (VCD) for a short window of dv/iverilog/tb_scen.sv, then ends the run.  The window
// (ns) is set with +ton=<ns> +toff=<ns>; defaults: 2 us inside the "random" scenario.
// NOT a checker: functional equivalence of the mapped netlist is `make gls-verify` (Verilator).
`timescale 1ns/1ps
module gls_dump;
  integer ton, toff;
  initial begin
    if (!$value$plusargs("ton=%d", ton))   ton  = 12000;
    if (!$value$plusargs("toff=%d", toff)) toff = 14000;
    $dumpfile("gls.vcd");
    $dumpvars(0, tb_scen.dut);
    $dumpoff;
    #(ton)        $dumpon;
    #(toff - ton) $dumpoff;
    $finish;
  end
endmodule
