// ============================================================================
// pipe_phy_ctrl_model.sv — DV-only PIPE PHY control-plane BFM.
//
// * PhyStatus: held high through reset and for rst_cycles after pipe_rst_n
//   rises (PHY reset handshake); afterwards every change of powerdown, rate or
//   width is completed with a single-cycle PhyStatus pulse `lat` cycles later.
// * Message bus target: a committed write ({MB_WR_C, addr} then {x, data}) is
//   stored in regs[addr] and acknowledged `lat` cycles later with
//   {MB_WR_ACK, addr} for one cycle.
// * Checker: Tx data_valid while powerdown != P0, or while a pin change is
//   waiting for its PhyStatus, is an error (the MAC must drain first).
// Knobs: lat, rst_cycles, mute_status (never pulse PhyStatus), mute_ack.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module pipe_phy_ctrl_model
  import eth_dj_pipe7_pkg::*;
(
  input  logic                      pclk,
  input  logic                      pipe_rst_n,
  input  logic [1:0]                powerdown,
  input  logic [2:0]                rate,
  input  logic [1:0]                width,
  input  logic                      tx_data_valid,
  input  logic [MSGBUS_CMD_W-1:0]   m2p_cmd,
  input  logic [MSGBUS_DATA_W-1:0]  m2p_data,
  output logic                      phy_status,
  output logic [MSGBUS_CMD_W-1:0]   p2m_cmd,
  output logic [MSGBUS_DATA_W-1:0]  p2m_data
);
  int   lat         = 8;
  int   rst_cycles  = 16;
  logic mute_status = 1'b0;
  logic mute_ack    = 1'b0;

  logic [7:0]  regs [0:255];
  int unsigned errors     = 0;
  int unsigned pd_changes = 0, rate_changes = 0, width_changes = 0, mb_writes = 0;
  logic [7:0]  last_mb_addr = 8'h00, last_mb_data = 8'h00;
  // powerdown history (value after each change), for sequence checks
  logic [1:0]  pd_hist [0:255];
  int          pd_hist_n = 0;

  logic [1:0]  pd_q;
  logic [2:0]  rate_q;
  logic [1:0]  width_q;
  int          rst_cnt;
  int          st_cnt;        // >0: a PhyStatus pulse is pending
  int          ack_cnt;       // >0: a write_ack is pending
  logic        mb_addr_ph;    // next cycle carries the write data
  logic [7:0]  mb_addr;

  task automatic err(input string msg);
    begin
      errors++;
      $display("[%0t] PHY-CTRL ERROR: %s", $time, msg);
    end
  endtask

  always @(posedge pclk or negedge pipe_rst_n) begin
    if (!pipe_rst_n) begin
      phy_status <= 1'b1;
      p2m_cmd    <= MB_NOP;
      p2m_data   <= 8'h00;
      pd_q       <= powerdown;
      rate_q     <= rate;
      width_q    <= width;
      rst_cnt    <= 0;
      st_cnt     <= 0;
      ack_cnt    <= 0;
      mb_addr_ph <= 1'b0;
      mb_addr    <= 8'h00;
    end else begin
      // ---- reset handshake ------------------------------------------------
      if (rst_cnt < rst_cycles) begin
        rst_cnt    <= rst_cnt + 1;
        phy_status <= 1'b1;
      end else begin
        phy_status <= 1'b0;
      end

      // ---- pin changes -> PhyStatus pulse ------------------------------------
      if (rst_cnt >= rst_cycles) begin
        if (powerdown != pd_q || rate != rate_q || width != width_q) begin
          if (st_cnt != 0 && !mute_status) err("new PIPE pin change before PhyStatus completed the previous one");
          if (powerdown != pd_q) begin
            pd_changes++;
            if (pd_hist_n < 256) begin pd_hist[pd_hist_n] = powerdown; pd_hist_n++; end
          end
          if (rate  != rate_q)  rate_changes++;
          if (width != width_q) width_changes++;
          st_cnt <= lat;
        end else if (st_cnt == 1) begin
          st_cnt <= 0;
          if (!mute_status) phy_status <= 1'b1;
        end else if (st_cnt > 1) begin
          st_cnt <= st_cnt - 1;
        end
      end
      pd_q    <= powerdown;
      rate_q  <= rate;
      width_q <= width;

      // ---- Tx legality checker -------------------------------------------------
      if (tx_data_valid && powerdown != PWR_P0) err("Tx data_valid while powerdown != P0");
      if (tx_data_valid && (st_cnt != 0 || powerdown != pd_q || rate != rate_q || width != width_q))
        err("Tx data_valid during a rate/width/power change");

      // ---- message bus target ------------------------------------------------
      p2m_cmd  <= MB_NOP;
      p2m_data <= 8'h00;
      if (mb_addr_ph) begin
        regs[mb_addr] = m2p_data;
        last_mb_addr  <= mb_addr;
        last_mb_data  <= m2p_data;
        mb_writes++;
        mb_addr_ph    <= 1'b0;
        ack_cnt       <= lat;
      end else if (m2p_cmd == MB_WR_C) begin
        if (ack_cnt != 0 && !mute_ack) err("msgbus write issued before the previous write_ack");
        mb_addr_ph <= 1'b1;
        mb_addr    <= m2p_data;
      end else if (m2p_cmd != MB_NOP) begin
        err("unsupported M2P message-bus command");
      end
      if (ack_cnt == 1) begin
        ack_cnt <= 0;
        if (!mute_ack) begin
          p2m_cmd  <= MB_WR_ACK;
          p2m_data <= mb_addr;
        end
      end else if (ack_cnt > 1) begin
        ack_cnt <= ack_cnt - 1;
      end
    end
  end
endmodule
