// ============================================================================
// dv/sva/bridge_sva.sv — bind-based assertions for eth_dj_pipe7_bridge (PLAN §7).
// rtl/ stays assertion-free; this checker is bound into the top from here.
// Property IDs match ASSERTIONS.md.  Verilator (--assert) evaluates these in the
// dv/vlt, dv/systemc and dv/uvm environments; Icarus has no concurrent-SVA
// support, so dv/iverilog and dv/cocotb (Icarus) do not bind them.
// Only simple implication forms + $past/$stable/$changed plus auxiliary counters
// are used, so Verilator 5.020 and 5.047 both handle them.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module bridge_sva
  import eth_dj_pipe7_pkg::*;
(
  input logic                     eth_clk,
  input logic                     eth_rst_n,
  input logic                     pclk,
  input logic                     pipe_rst_n,
  // Ethernet ingress / egress
  input logic                     eth_tvalid,
  input logic                     eth_tready,
  input logic [ETH_DATA_W-1:0]    eth_tdata,
  input logic [ETH_KEEP_W-1:0]    eth_tkeep,
  input logic                     eth_tlast,
  input logic                     eth_rx_tvalid,
  input logic                     eth_rx_tready,
  input logic [ETH_DATA_W-1:0]    eth_rx_tdata,
  input logic [ETH_KEEP_W-1:0]    eth_rx_tkeep,
  input logic                     eth_rx_tlast,
  input logic [ETH_USER_W-1:0]    eth_rx_tuser,
  // PIPE
  input logic                     pipe_tx_data_valid,
  input logic                     pipe_tx_start_block,
  input logic [2:0]               pipe_rate,
  input logic [1:0]               pipe_width,
  input logic [1:0]               pipe_powerdown,
  input logic [MSGBUS_CMD_W-1:0]  pipe_m2p_cmd,
  // internal observation points
  input logic [2:0]               ctrl_state,
  input logic                     mb_req,
  input logic                     mb_busy,
  input logic                     mb_done,
  input logic                     mb_timeout,
  input logic                     ev_phy_timeout,
  input logic                     tx_fifo_full,
  input logic                     tx_fifo_empty,
  input logic                     tx_fifo_rinc,
  input logic                     rx_fifo_full,
  input logic                     rx_fifo_winc,
  input logic                     rx_fifo_empty,
  input logic                     rx_fifo_rinc,
  input logic [15:0]              rx_dropped_flits
);
  localparam int unsigned BW = $clog2(FLIT_BEATS) + 1;

  wire in_chg = (ctrl_state == ST_RATE_CHG) || (ctrl_state == ST_WIDTH_CHG) ||
                (ctrl_state == ST_PWR_CHG);

  // ---- auxiliary state (pclk) ------------------------------------------------
  logic [BW-1:0] beat_q;        // position inside the current Tx flit (0 = between flits)
  logic [11:0]   chg_cnt_q;     // cycles spent in a pin-change state
  logic [11:0]   cfg_cnt_q;     // cycles spent in ST_CFG
  logic          prev_valid_q;

  always_ff @(posedge pclk or negedge pipe_rst_n) begin
    if (!pipe_rst_n) begin
      beat_q       <= '0;
      chg_cnt_q    <= '0;
      cfg_cnt_q    <= '0;
      prev_valid_q <= 1'b0;
    end else begin
      prev_valid_q <= pipe_tx_data_valid;
      if (pipe_tx_start_block)     beat_q <= BW'(1);
      else if (pipe_tx_data_valid) beat_q <= (int'(beat_q) == FLIT_BEATS - 1) ? '0 : beat_q + BW'(1);
      chg_cnt_q <= in_chg ? chg_cnt_q + 12'd1 : 12'd0;
      cfg_cnt_q <= (ctrl_state == ST_CFG) ? cfg_cnt_q + 12'd1 : 12'd0;
    end
  end

  // =========================== eth_clk domain ==================================
  // AX1: egress tvalid/payload held until accepted
  a_ax1_rx_stable: assert property (@(posedge eth_clk) disable iff (!eth_rst_n || !pipe_rst_n)
    eth_rx_tvalid && !eth_rx_tready |=> eth_rx_tvalid &&
      $stable(eth_rx_tdata) && $stable(eth_rx_tkeep) && $stable(eth_rx_tlast) && $stable(eth_rx_tuser));
  // AX2: tkeep nonzero, contiguous from byte 0, all-ones except on tlast
  a_ax2_rx_keep: assert property (@(posedge eth_clk) disable iff (!eth_rst_n || !pipe_rst_n)
    eth_rx_tvalid |-> (eth_rx_tkeep != '0) && ((eth_rx_tkeep & (eth_rx_tkeep + 1'b1)) == '0) &&
                      (eth_rx_tlast || (&eth_rx_tkeep)));
  // AX3: tuser[0] (abort, D9) only on a tlast beat; tuser[7:1] zero
  a_ax3_rx_tuser: assert property (@(posedge eth_clk) disable iff (!eth_rst_n || !pipe_rst_n)
    eth_rx_tvalid |-> (eth_rx_tuser[ETH_USER_W-1:1] == '0) && (!eth_rx_tuser[0] || eth_rx_tlast));
  // AX4 (environment check): the MAC BFM holds its beat until accepted
  a_ax4_src_stable: assert property (@(posedge eth_clk) disable iff (!eth_rst_n)
    eth_tvalid && !eth_tready |=> eth_tvalid &&
      $stable(eth_tdata) && $stable(eth_tkeep) && $stable(eth_tlast));
  // FF1: ingress never accepts a beat into a full Tx CDC FIFO
  a_ff1_tx_no_overflow: assert property (@(posedge eth_clk) disable iff (!eth_rst_n)
    eth_tvalid && eth_tready |-> !tx_fifo_full);
  // FF4: egress never pops an empty Rx CDC FIFO
  a_ff4_rx_no_underflow: assert property (@(posedge eth_clk) disable iff (!eth_rst_n)
    rx_fifo_rinc |-> !rx_fifo_empty);

  // ============================= pclk domain ===================================
  // PP1: Tx data only in P0 and only while the FSM is ACTIVE or DRAINing
  a_pp1_tx_only_p0: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    pipe_tx_data_valid |-> (pipe_powerdown == PWR_P0) &&
                           ((ctrl_state == ST_ACTIVE) || (ctrl_state == ST_DRAIN)));
  // PP2: start_block only on a valid beat, and only at a flit boundary
  a_pp2_sb_boundary: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    pipe_tx_start_block |-> pipe_tx_data_valid && (beat_q == '0));
  // PP3: a flit is FLIT_BEATS contiguous valid beats (no bubble, no headless beat)
  a_pp3_flit_contiguous: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    (beat_q != '0) |-> pipe_tx_data_valid && !pipe_tx_start_block);
  a_pp3_no_headless_beat: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    pipe_tx_data_valid && !pipe_tx_start_block |-> (beat_q != '0));
  // PP4: PIPE rate/width/powerdown pins move only in their change state
  a_pp4_rate_pin: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    $changed(pipe_rate) |-> ctrl_state == ST_RATE_CHG);
  a_pp4_width_pin: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    $changed(pipe_width) |-> ctrl_state == ST_WIDTH_CHG);
  a_pp4_pd_pin: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    $changed(pipe_powerdown) |-> ctrl_state == ST_PWR_CHG);
  // PP5: a PhyStatus handshake completes (or times out, D10) within PHY_TIMEOUT
  a_pp5_phystatus_bound: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    chg_cnt_q <= 12'(PHY_TIMEOUT));
  // MB1: no new message-bus request while one is outstanding
  a_mb1_one_outstanding: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    mb_req |-> !mb_busy);
  // MB2: write_ack / timeout are only consumed in ST_CFG, and never both
  a_mb2_done_in_cfg: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    (mb_done || mb_timeout) |-> (ctrl_state == ST_CFG) && !(mb_done && mb_timeout));
  // MB3: committed write = {WR_C, addr} then {NOP, data}; only NOP/WR_C are driven
  a_mb3_framing: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    pipe_m2p_cmd == MB_WR_C |=> pipe_m2p_cmd == MB_NOP);
  a_mb3_cmds: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    (pipe_m2p_cmd == MB_NOP) || (pipe_m2p_cmd == MB_WR_C));
  // MB4: no PIPE pin change while a message-bus write is outstanding
  a_mb4_no_pin_chg_during_mb: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    in_chg |-> !mb_busy);
  // MB5: the msgbus write completes (ack or timeout) within PHY_TIMEOUT + 3
  a_mb5_cfg_bound: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    cfg_cnt_q <= 12'(PHY_TIMEOUT + 3));
  // FF2: the deframer never pushes into a full Rx CDC FIFO
  a_ff2_rx_no_overflow: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    rx_fifo_winc |-> !rx_fifo_full);
  // FF3: the framer never pops an empty Tx CDC FIFO
  a_ff3_tx_no_underflow: assert property (@(posedge pclk) disable iff (!pipe_rst_n)
    tx_fifo_rinc |-> !tx_fifo_empty);

  // ================================ covers ======================================
  c_b2b_flits:    cover property (@(posedge pclk) disable iff (!pipe_rst_n)
    pipe_tx_start_block && prev_valid_q);
  c_p2:           cover property (@(posedge pclk) disable iff (!pipe_rst_n) pipe_powerdown == PWR_P2);
  c_gen5:         cover property (@(posedge pclk) disable iff (!pipe_rst_n) pipe_rate == RATE_GEN5);
  c_width1:       cover property (@(posedge pclk) disable iff (!pipe_rst_n) pipe_width == 2'd1);
  c_mb_ack:       cover property (@(posedge pclk) disable iff (!pipe_rst_n) mb_done);
  c_phy_timeout:  cover property (@(posedge pclk) disable iff (!pipe_rst_n) ev_phy_timeout);
  c_rx_drop:      cover property (@(posedge pclk) disable iff (!pipe_rst_n) $changed(rx_dropped_flits));
  c_rx_fifo_full: cover property (@(posedge pclk) disable iff (!pipe_rst_n) rx_fifo_full);
  c_tx_fifo_full: cover property (@(posedge eth_clk) disable iff (!eth_rst_n) tx_fifo_full);
  c_rx_abort:     cover property (@(posedge eth_clk) disable iff (!eth_rst_n)
    eth_rx_tvalid && eth_rx_tready && eth_rx_tuser[0]);
endmodule : bridge_sva

bind eth_dj_pipe7_bridge bridge_sva u_bridge_sva (
  .eth_clk (eth_clk), .eth_rst_n (eth_rst_n), .pclk (pclk), .pipe_rst_n (pipe_rst_n),
  .eth_tvalid (eth_tvalid), .eth_tready (eth_tready), .eth_tdata (eth_tdata),
  .eth_tkeep (eth_tkeep), .eth_tlast (eth_tlast),
  .eth_rx_tvalid (eth_rx_tvalid), .eth_rx_tready (eth_rx_tready), .eth_rx_tdata (eth_rx_tdata),
  .eth_rx_tkeep (eth_rx_tkeep), .eth_rx_tlast (eth_rx_tlast), .eth_rx_tuser (eth_rx_tuser),
  .pipe_tx_data_valid (pipe_tx_data_valid), .pipe_tx_start_block (pipe_tx_start_block),
  .pipe_rate (rate_v), .pipe_width (width_v), .pipe_powerdown (pd_v),
  .pipe_m2p_cmd (pipe_m2p_cmd),
  .ctrl_state (ctrl_state), .mb_req (mb_req), .mb_busy (mb_busy), .mb_done (mb_done),
  .mb_timeout (mb_timeout), .ev_phy_timeout (ev_phy_timeout),
  .tx_fifo_full (tx_fifo_full), .tx_fifo_empty (tx_fifo_empty), .tx_fifo_rinc (tx_fifo_rinc),
  .rx_fifo_full (rx_fifo_full), .rx_fifo_winc (rx_fifo_winc), .rx_fifo_empty (rx_fifo_empty),
  .rx_fifo_rinc (rx_fifo_rinc), .rx_dropped_flits (rx_dropped_flits)
);
