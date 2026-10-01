// ============================================================================
// lp/cocotb/pd_top.sv — power-state emulation top: dv/cocotb/cocotb_top.sv (the bridge with
// PIPE Tx looped back to Rx) + the DV-only PMU (lp/pipe7_pmu.sv).  Same ports as cocotb_top plus
// the PMU controls, which lp/cocotb/pd_emu.py watches to emulate PD_DP power-off (state
// corruption), isolation clamps and retention save/restore.  No power semantics here: this is
// the "UPF-like without UPF" emulation (docs/power_intent.md, OSS power-state emulation).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module pd_top
  import eth_dj_pipe7_pkg::*;
(
  input  logic                     eth_clk,
  input  logic                     eth_rst_n,
  input  logic                     eth_tvalid,
  output logic                     eth_tready,
  input  logic [ETH_DATA_W-1:0]    eth_tdata,
  input  logic [ETH_KEEP_W-1:0]    eth_tkeep,
  input  logic                     eth_tlast,
  output logic                     eth_rx_tvalid,
  input  logic                     eth_rx_tready,
  output logic [ETH_DATA_W-1:0]    eth_rx_tdata,
  output logic [ETH_KEEP_W-1:0]    eth_rx_tkeep,
  output logic                     eth_rx_tlast,
  output logic [ETH_USER_W-1:0]    eth_rx_tuser,
  input  logic                     pclk,
  input  logic                     pipe_rst_n,
  output logic [PIPE_BUS_W-1:0]    pipe_tx_data,
  output logic                     pipe_tx_data_valid,
  output logic                     pipe_tx_start_block,
  output logic [2:0]               pipe_rate,
  output logic [1:0]               pipe_width,
  output logic [1:0]               pipe_powerdown,
  input  logic                     pipe_phy_status,
  output logic [MSGBUS_W-1:0]      pipe_m2p_msgbus,
  input  logic [MSGBUS_W-1:0]      pipe_p2m_msgbus,
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata,
  // PMU controls (observed by the emulation)
  output logic                     dp_pwr_en,
  output logic                     dp_iso_en,
  output logic                     dp_save,
  output logic                     dp_restore,
  output logic                     dp_off,
  output int                       n_down,
  output int                       n_up
);
  cocotb_top top (.*);

  pipe7_pmu #(.DOWN_DELAY(16), .PWR_UP_CYC(2)) pmu (
    .pclk(pclk), .rst_n(pipe_rst_n), .powerdown(pipe_powerdown),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .dp_pwr_en(dp_pwr_en), .dp_iso_en(dp_iso_en), .dp_save(dp_save), .dp_restore(dp_restore),
    .dp_off(dp_off), .n_down(n_down), .n_up(n_up));
endmodule
