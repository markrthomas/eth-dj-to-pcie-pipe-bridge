// ============================================================================
// dv/uvm/bridge_if.sv — virtual interfaces for the UVM env (DV env 3).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

interface eth_if (input logic clk);
  import eth_dj_pipe7_pkg::*;
  logic                  rst_n;
  logic                  tvalid, tready, tlast;
  logic [ETH_DATA_W-1:0] tdata;
  logic [ETH_KEEP_W-1:0] tkeep;
  logic                  rx_tvalid, rx_tready, rx_tlast;
  logic [ETH_DATA_W-1:0] rx_tdata;
  logic [ETH_KEEP_W-1:0] rx_tkeep;
  logic [ETH_USER_W-1:0] rx_tuser;
endinterface

interface pipe_if (input logic clk);
  import eth_dj_pipe7_pkg::*;
  logic                     rst_n;
  logic [PIPE_BUS_W-1:0]    tx_data;
  logic                     tx_valid, tx_sb;
  logic [2:0]               rate;
  logic [1:0]               width, powerdown;
  logic                     phy_status;
  logic [MSGBUS_CMD_W-1:0]  m2p_cmd, p2m_cmd;
  logic [MSGBUS_DATA_W-1:0] m2p_data, p2m_data;
  logic                     csr_valid, csr_write;
  logic [CSR_ADDR_W-1:0]    csr_addr;
  logic [31:0]              csr_wdata, csr_rdata;
endinterface
