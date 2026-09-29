// ============================================================================
// dv/iverilog/tb_smoke.sv — M0 smoke test.
//
// Elaborates the bridge top, applies reset on both clock domains, runs a few
// cycles, and checks the reset-state defaults the M0 stub drives.  This proves
// the port list + package elaborate and gives `make sim`/`make regress`
// something real to pass.  Real directed frame tests arrive at M1 (docs/PLAN.md).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_smoke;
  import eth_dj_pipe7_pkg::*;

  logic eth_clk  = 1'b0;
  logic pclk     = 1'b0;
  logic eth_rst_n;
  logic pipe_rst_n;

  // observed outputs we assert on
  wire                    eth_tready;
  wire                    pipe_tx_data_valid;
  pipe_rate_e             pipe_rate;
  pipe_pwr_e              pipe_powerdown;

  eth_dj_pipe7_bridge dut (
    // 802.3dj side
    .eth_clk       (eth_clk),
    .eth_rst_n     (eth_rst_n),
    .eth_tvalid    (1'b0),
    .eth_tready    (eth_tready),
    .eth_tdata     ('0),
    .eth_tkeep     ('0),
    .eth_tlast     (1'b0),
    .eth_tuser     ('0),
    .eth_rx_tvalid (),
    .eth_rx_tready (1'b1),
    .eth_rx_tdata  (),
    .eth_rx_tkeep  (),
    .eth_rx_tlast  (),
    .eth_rx_tuser  (),
    // PIPE side
    .pclk                (pclk),
    .pipe_rst_n          (pipe_rst_n),
    .pipe_tx_data        (),
    .pipe_tx_data_valid  (pipe_tx_data_valid),
    .pipe_tx_start_block (),
    .pipe_rx_data        ('0),
    .pipe_rx_data_valid  (1'b0),
    .pipe_rx_start_block (1'b0),
    .pipe_rate           (pipe_rate),
    .pipe_width          (),
    .pipe_powerdown      (pipe_powerdown),
    .pipe_phy_status     (1'b0),
    .pipe_rx_valid       (1'b0),
    .pipe_rx_elec_idle   (1'b1),
    .pipe_m2p_cmd        (),
    .pipe_m2p_data       (),
    .pipe_p2m_cmd        ('0),
    .pipe_p2m_data       ('0)
  );

  always #2.5 eth_clk = ~eth_clk;   // 200 MHz-ish
  always #1.0 pclk    = ~pclk;      // faster PIPE domain

  int errors = 0;

  initial begin
    eth_rst_n  = 1'b0;
    pipe_rst_n = 1'b0;
    repeat (10) @(posedge pclk);
    eth_rst_n  = 1'b1;
    pipe_rst_n = 1'b1;
    repeat (20) @(posedge pclk);

    // M0 stub contract: no Tx traffic, PIPE reports Gen6 (PAM4) rate and starts
    // in a low-power state until the control FSM brings the link to P0 (M3).
    if (pipe_tx_data_valid !== 1'b0) begin
      $display("FAIL: pipe_tx_data_valid should be 0 in M0 stub"); errors++;
    end
    if (pipe_rate !== RATE_GEN6) begin
      $display("FAIL: pipe_rate should be RATE_GEN6 (PAM4 baseline)"); errors++;
    end
    if (pipe_powerdown !== PWR_P1) begin
      $display("FAIL: pipe_powerdown should be PWR_P1 in M0 stub"); errors++;
    end

    if (errors == 0)
      $display("SMOKE PASS: eth_dj_pipe7_bridge elaborates; PAM4/Gen6 defaults OK");
    else
      $display("SMOKE FAIL: %0d error(s)", errors);
    $finish;
  end

  // watchdog
  initial begin
    #10000;
    $display("SMOKE FAIL: timeout");
    $finish;
  end
endmodule
