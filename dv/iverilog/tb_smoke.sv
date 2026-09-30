// ============================================================================
// dv/iverilog/tb_smoke.sv — reset / link-up smoke test (M3 contract).
//
// Out of reset the bridge must hold powerdown = P1, rate = Gen6, Ethernet
// ingress closed (eth_tready = 0) and no Tx traffic.  After the PHY's reset
// PhyStatus handshake the control FSM (reset CSR values) must bring the link to
// P0 via one PhyStatus-acknowledged change, send PAM4CFG over the message bus,
// reach ST_ACTIVE and open the ingress.  CSR reset values are read back.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_smoke;
  import eth_dj_pipe7_pkg::*;

  logic eth_clk  = 1'b0;
  logic pclk     = 1'b0;
  logic eth_rst_n;
  logic pipe_rst_n;

  wire                     eth_tready;
  wire                     pipe_tx_data_valid;
  pipe_rate_e              pipe_rate;
  pipe_pwr_e               pipe_powerdown;
  wire [1:0]               pipe_width;
  wire                     pipe_phy_status;
  wire [MSGBUS_W-1:0]      m2p, p2m;
  logic                    csr_valid = 1'b0, csr_write = 1'b0;
  logic [7:0]              csr_addr  = 8'h00;
  logic [31:0]             csr_wdata = 32'h0;
  wire  [31:0]             csr_rdata;

  eth_dj_pipe7_bridge dut (
    .eth_clk       (eth_clk),   .eth_rst_n (eth_rst_n),
    .eth_tvalid    (1'b0),      .eth_tready (eth_tready), .eth_tdata ('0),
    .eth_tkeep     ('0),        .eth_tlast (1'b0),       .eth_tuser ('0),
    .eth_rx_tvalid (),          .eth_rx_tready (1'b1),   .eth_rx_tdata (),
    .eth_rx_tkeep  (),          .eth_rx_tlast (),        .eth_rx_tuser (),
    .pclk (pclk), .pipe_rst_n (pipe_rst_n),
    .pipe_tx_data (), .pipe_tx_data_valid (pipe_tx_data_valid), .pipe_tx_start_block (),
    .pipe_rx_data ('0), .pipe_rx_data_valid (1'b0), .pipe_rx_start_block (1'b0),
    .pipe_rate (pipe_rate), .pipe_width (pipe_width), .pipe_powerdown (pipe_powerdown),
    .pipe_phy_status (pipe_phy_status), .pipe_rx_valid (1'b0), .pipe_rx_elec_idle (1'b1),
    .pipe_m2p_msgbus(m2p), .pipe_p2m_msgbus(p2m),
    .csr_valid (csr_valid), .csr_write (csr_write), .csr_addr (csr_addr),
    .csr_wdata (csr_wdata), .csr_rdata (csr_rdata)
  );

  pipe_phy_ctrl_model phyc (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .powerdown(pipe_powerdown), .rate(pipe_rate),
    .width(pipe_width), .tx_data_valid(pipe_tx_data_valid), .m2p(m2p),
    .phy_status(pipe_phy_status), .p2m(p2m)
  );

  always #2.5 eth_clk = ~eth_clk;
  always #1.0 pclk    = ~pclk;

  int errors = 0;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("FAIL: %s", msg); errors++; end
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    begin
      @(negedge pclk); csr_addr = a; #0.1; d = csr_rdata;
    end
  endtask

  logic [31:0] d;

  initial begin
    eth_rst_n  = 1'b0;
    pipe_rst_n = 1'b0;
    repeat (10) @(posedge pclk);
    eth_rst_n  = 1'b1;
    pipe_rst_n = 1'b1;
    repeat (5) @(posedge pclk);

    // ---- reset contract (PHY still reporting reset via PhyStatus) -----------
    chk(pipe_powerdown === PWR_P1, "powerdown should be P1 out of reset");
    chk(pipe_rate === RATE_GEN6,   "rate should be RATE_GEN6 (PAM4 baseline)");
    chk(pipe_tx_data_valid === 1'b0, "no Tx traffic out of reset");
    chk(eth_tready === 1'b0,       "Ethernet ingress closed before link-up");
    csr_rd(CSR_CTRL, d);
    chk(d === {25'b0, 2'b00, 3'(RATE_GEN6), 2'(PWR_P0)}, "CTRL reset value");
    csr_rd(CSR_PAM4CFG, d);
    chk(d === {24'b0, PAM4CFG_RST}, "PAM4CFG reset value");

    // ---- link-up ---------------------------------------------------------------
    fork
      begin wait (dut.ctrl_state == ST_ACTIVE); end
      begin repeat (2000) @(posedge pclk); end
    join_any
    repeat (10) @(posedge eth_clk);

    chk(dut.ctrl_state == ST_ACTIVE, "control FSM did not reach ST_ACTIVE");
    chk(pipe_powerdown === PWR_P0,   "powerdown should be P0 after link-up");
    chk(phyc.pd_changes == 1 && phyc.pd_hist[0] == PWR_P0, "exactly one P1->P0 change");
    chk(phyc.mb_writes == 1,         "one message-bus write at link-up");
    chk(phyc.last_mb_addr == MB_ADDR_PAM4_TXCTL && phyc.last_mb_data == PAM4CFG_RST,
        "PAM4 Tx control written to the PHY");
    chk(eth_tready === 1'b1,         "Ethernet ingress open after link-up");
    csr_rd(CSR_STATUS, d);
    chk(d[1:0] == PWR_P0 && d[4:2] == RATE_GEN6 && d[9:7] == ST_ACTIVE && d[11] == 1'b1 && d[10] == 1'b0,
        "STATUS shows P0 / Gen6 / active / not busy");
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "no error flags");
    csr_rd(CSR_PMCNT, d);
    chk(d == 32'd2, "two control ops (P1->P0, PAM4 cfg)");
    chk(phyc.errors == 0, "PHY-ctrl model errors");

    if (errors == 0)
      $display("SMOKE PASS: reset in P1, link-up to P0/Gen6 with PAM4 msgbus cfg, CSRs OK");
    else
      $display("SMOKE FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #50000;
    $display("SMOKE FAIL: timeout");
    $finish;
  end
endmodule
