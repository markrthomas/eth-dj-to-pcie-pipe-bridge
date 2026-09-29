// ============================================================================
// dv/cocotb/cocotb_top.sv — structural wrapper for the cocotb env: the bridge with
// PIPE Tx looped back to PIPE Rx.  No behaviour; Python drives everything else.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module cocotb_top
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
  output logic [MSGBUS_CMD_W-1:0]  pipe_m2p_cmd,
  output logic [MSGBUS_DATA_W-1:0] pipe_m2p_data,
  input  logic [MSGBUS_CMD_W-1:0]  pipe_p2m_cmd,
  input  logic [MSGBUS_DATA_W-1:0] pipe_p2m_data,
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata
);
  pipe_rate_e rate_e;
  pipe_pwr_e  pd_e;

  eth_dj_pipe7_bridge dut (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n),
    .eth_tvalid(eth_tvalid), .eth_tready(eth_tready), .eth_tdata(eth_tdata),
    .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast), .eth_tuser('0),
    .eth_rx_tvalid(eth_rx_tvalid), .eth_rx_tready(eth_rx_tready), .eth_rx_tdata(eth_rx_tdata),
    .eth_rx_tkeep(eth_rx_tkeep), .eth_rx_tlast(eth_rx_tlast), .eth_rx_tuser(eth_rx_tuser),
    .pclk(pclk), .pipe_rst_n(pipe_rst_n),
    .pipe_tx_data(pipe_tx_data), .pipe_tx_data_valid(pipe_tx_data_valid),
    .pipe_tx_start_block(pipe_tx_start_block),
    .pipe_rx_data(pipe_tx_data), .pipe_rx_data_valid(pipe_tx_data_valid),
    .pipe_rx_start_block(pipe_tx_start_block),
    .pipe_rate(rate_e), .pipe_width(pipe_width), .pipe_powerdown(pd_e),
    .pipe_phy_status(pipe_phy_status), .pipe_rx_valid(1'b0), .pipe_rx_elec_idle(1'b1),
    .pipe_m2p_cmd(pipe_m2p_cmd), .pipe_m2p_data(pipe_m2p_data),
    .pipe_p2m_cmd(pipe_p2m_cmd), .pipe_p2m_data(pipe_p2m_data),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr),
    .csr_wdata(csr_wdata), .csr_rdata(csr_rdata)
  );

  assign pipe_rate      = rate_e;
  assign pipe_powerdown = pd_e;
endmodule
