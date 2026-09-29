// ============================================================================
// dv/uvm/tb_uvm_top.sv — UVM testbench top: clocks, interfaces, the bridge with
// PIPE Tx looped to PIPE Rx, config_db hookup, run_test().
// ============================================================================
`timescale 1ns/1ps
`include "uvm_macros.svh"
`include "eth_dj_pipe7_pkg.sv"

module tb_uvm_top;
  import uvm_pkg::*;
  import eth_dj_pipe7_pkg::*;
  import bridge_uvm_pkg::*;

  logic eth_clk = 1'b0, pclk = 1'b0;
  always #2.5 eth_clk = ~eth_clk;
  always #1.0 pclk    = ~pclk;

  eth_if  eif (eth_clk);
  pipe_if pif (pclk);

  pipe_rate_e rate_e;
  pipe_pwr_e  pd_e;
  assign pif.rate      = rate_e;
  assign pif.powerdown = pd_e;

  eth_dj_pipe7_bridge dut (
    .eth_clk(eth_clk), .eth_rst_n(eif.rst_n),
    .eth_tvalid(eif.tvalid), .eth_tready(eif.tready), .eth_tdata(eif.tdata),
    .eth_tkeep(eif.tkeep), .eth_tlast(eif.tlast), .eth_tuser('0),
    .eth_rx_tvalid(eif.rx_tvalid), .eth_rx_tready(eif.rx_tready), .eth_rx_tdata(eif.rx_tdata),
    .eth_rx_tkeep(eif.rx_tkeep), .eth_rx_tlast(eif.rx_tlast), .eth_rx_tuser(eif.rx_tuser),
    .pclk(pclk), .pipe_rst_n(pif.rst_n),
    .pipe_tx_data(pif.tx_data), .pipe_tx_data_valid(pif.tx_valid), .pipe_tx_start_block(pif.tx_sb),
    .pipe_rx_data(pif.tx_data), .pipe_rx_data_valid(pif.tx_valid), .pipe_rx_start_block(pif.tx_sb),
    .pipe_rate(rate_e), .pipe_width(pif.width), .pipe_powerdown(pd_e),
    .pipe_phy_status(pif.phy_status), .pipe_rx_valid(1'b0), .pipe_rx_elec_idle(1'b1),
    .pipe_m2p_cmd(pif.m2p_cmd), .pipe_m2p_data(pif.m2p_data),
    .pipe_p2m_cmd(pif.p2m_cmd), .pipe_p2m_data(pif.p2m_data),
    .csr_valid(pif.csr_valid), .csr_write(pif.csr_write), .csr_addr(pif.csr_addr),
    .csr_wdata(pif.csr_wdata), .csr_rdata(pif.csr_rdata)
  );

  initial begin
    eif.rst_n = 1'b0;
    pif.rst_n = 1'b0;
    uvm_config_db#(virtual eth_if)::set(null, "*", "eth_vif", eif);
    uvm_config_db#(virtual pipe_if)::set(null, "*", "pipe_vif", pif);
    run_test("scen_test");
  end

  initial begin
    #50ms;
    $display("UVM FAIL: global timeout");
    $finish;
  end
endmodule
