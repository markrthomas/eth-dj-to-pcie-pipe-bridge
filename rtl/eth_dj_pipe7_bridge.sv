// ============================================================================
// eth_dj_pipe7_bridge.sv — TOP of the 802.3dj Ethernet <-> PCIe PIPE 7.1 bridge.
//
// STATUS: M3 — Tx (eth -> PIPE) and Rx (PIPE -> eth) datapaths plus the control
// plane (bridge_rf CSRs, bridge_ctrl_fsm, pipe_msgbus, tx_ingress_gate).  Ports
// per docs/PLAN.md §2 plus the M3 CSR port (docs/OPEN_DECISIONS.md D7).
// Out of reset the link is in P1; with the reset CSR values the control FSM
// brings it to P0 / Gen6, sends the PAM4 Tx control over the message bus, and
// then opens the Ethernet ingress.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module eth_dj_pipe7_bridge
  import eth_dj_pipe7_pkg::*;
(
  // ---- 802.3dj MAC/PCS side -------------------------------------------------
  input  logic                     eth_clk,
  input  logic                     eth_rst_n,
  // ingress: Ethernet -> bridge (AXI4-Stream)
  input  logic                     eth_tvalid,
  output logic                     eth_tready,
  input  logic [ETH_DATA_W-1:0]    eth_tdata,
  input  logic [ETH_DATA_W/8-1:0]  eth_tkeep,
  input  logic                     eth_tlast,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [ETH_USER_W-1:0]    eth_tuser,     // not carried (OPEN_DECISIONS D4)
  /* verilator lint_on UNUSEDSIGNAL */
  // egress: bridge -> Ethernet (AXI4-Stream)
  output logic                     eth_rx_tvalid,
  input  logic                     eth_rx_tready,
  output logic [ETH_DATA_W-1:0]    eth_rx_tdata,
  output logic [ETH_DATA_W/8-1:0]  eth_rx_tkeep,
  output logic                     eth_rx_tlast,
  output logic [ETH_USER_W-1:0]    eth_rx_tuser,  // [0] = aborted-frame error (D9)

  // ---- PCIe PIPE 7.1 side (Gen6 FLIT / PAM4) --------------------------------
  input  logic                     pclk,
  input  logic                     pipe_rst_n,
  // Tx datapath: bridge -> PHY
  output logic [PIPE_BUS_W-1:0]    pipe_tx_data,
  output logic                     pipe_tx_data_valid,
  output logic                     pipe_tx_start_block,
  // Rx datapath: PHY -> bridge
  input  logic [PIPE_BUS_W-1:0]    pipe_rx_data,
  input  logic                     pipe_rx_data_valid,
  input  logic                     pipe_rx_start_block,
  // per-link control/status
  output pipe_rate_e               pipe_rate,
  output logic [1:0]               pipe_width,
  output pipe_pwr_e                pipe_powerdown,
  input  logic                     pipe_phy_status,
  input  logic                     pipe_rx_valid,
  input  logic                     pipe_rx_elec_idle,
  // 4-bit message bus (rate/width/power/margining handshakes)
  output logic [MSGBUS_W-1:0]      pipe_m2p_msgbus,
  input  logic [MSGBUS_W-1:0]      pipe_p2m_msgbus,

  // ---- CSR port (pclk domain, always ready; D7) ------------------------------
  input  logic                     csr_valid,
  input  logic                     csr_write,
  input  logic [CSR_ADDR_W-1:0]    csr_addr,
  input  logic [31:0]              csr_wdata,
  output logic [31:0]              csr_rdata
);

  // ---- control plane ---------------------------------------------------------
  logic [1:0]  pwr_req, width_req, pd_v, width_v;
  logic [2:0]  rate_req, rate_v, ctrl_state;
  logic [7:0]  pam4cfg;
  logic        pam4_wr, tx_en, ingress_stop, ingress_stopped_eth;
  logic        stp_s1, stp_s2, stp_s3;
  logic        tx_idle, rx_idle, framer_idle, egress_busy;
  logic        rx_ing_idle, rx_dfr_idle;
  logic        mb_req, mb_busy, mb_done, mb_timeout;
  logic        ev_op_done, ev_phy_timeout, ev_bad_pwr_req;

  // ---- Tx path: eth AXI-S -> ingress gate -> async FIFO -> flit framer -> PIPE ----
  logic                                 tx_fifo_full;
  logic [ETH_DATA_W+ETH_KEEP_W:0]       tx_fifo_rdata;
  logic                                 tx_fifo_empty, tx_fifo_rinc;
  logic                                 flit_valid, flit_taken;
  logic [FLIT_BYTES*8-1:0]              flit;

  // ---- Rx path nets --------------------------------------------------------------
  logic                              rx_flit_valid, rx_flit_taken, rx_flit_gap;
  logic [FLIT_BYTES*8-1:0]           rx_flit;
  logic [ETH_DATA_W+ETH_KEEP_W+1:0]  rx_fifo_wdata, rx_fifo_rdata;
  logic                              rx_fifo_winc, rx_fifo_full, rx_fifo_empty, rx_fifo_rinc;
  logic [15:0]                       rx_dropped_flits, rx_lock_errors, rx_bad_flits;  // DV-visible
  logic [15:0]                       rx_aborted_frames;

  bridge_rf u_rf (
    .clk (pclk), .rst_n (pipe_rst_n),
    .csr_valid (csr_valid), .csr_write (csr_write), .csr_addr (csr_addr),
    .csr_wdata (csr_wdata), .csr_rdata (csr_rdata),
    .pwr_req (pwr_req), .rate_req (rate_req), .width_req (width_req),
    .pam4cfg (pam4cfg), .pam4_wr (pam4_wr),
    .st_powerdown (pd_v), .st_rate (rate_v), .st_width (width_v), .st_state (ctrl_state),
    .st_rx_elec_idle (pipe_rx_elec_idle), .st_rx_valid (pipe_rx_valid),
    .ev_op_done (ev_op_done), .ev_phy_timeout (ev_phy_timeout),
    .ev_mb_timeout (mb_timeout), .ev_bad_pwr_req (ev_bad_pwr_req),
    .rx_dropped_flits (rx_dropped_flits), .rx_lock_errors (rx_lock_errors),
    .rx_bad_flits (rx_bad_flits), .rx_aborted_frames (rx_aborted_frames)
  );

  // ingress `stopped` (eth_clk) -> pclk: 3 flops so the Tx FIFO empty flag has
  // settled before the FSM sees it (see tx_ingress_gate.sv).
  always_ff @(posedge pclk or negedge pipe_rst_n) begin
    if (!pipe_rst_n) {stp_s3, stp_s2, stp_s1} <= 3'b111;
    else             {stp_s3, stp_s2, stp_s1} <= {stp_s2, stp_s1, ingress_stopped_eth};
  end

  assign tx_idle = tx_fifo_empty && framer_idle && !egress_busy;
  assign rx_idle = rx_ing_idle;   // Rx frame-level state is not drained (D11)

  bridge_ctrl_fsm u_ctrl (
    .clk (pclk), .rst_n (pipe_rst_n),
    .pwr_req (pwr_req), .rate_req (rate_req), .width_req (width_req), .pam4_wr (pam4_wr),
    .powerdown (pd_v), .rate (rate_v), .width (width_v), .phy_status (pipe_phy_status),
    .tx_en (tx_en), .ingress_stop (ingress_stop), .ingress_stopped (stp_s3),
    .tx_idle (tx_idle), .rx_idle (rx_idle),
    .mb_req (mb_req), .mb_done (mb_done), .mb_timeout (mb_timeout),
    .state (ctrl_state), .ev_op_done (ev_op_done), .ev_phy_timeout (ev_phy_timeout),
    .ev_bad_pwr_req (ev_bad_pwr_req)
  );

  // Local copy of the pkg constant: Icarus turns a bare imported name used
  // directly in a port connection into an implicit 1-bit net.
  wire [MB_ADDR_W-1:0] mb_addr = MB_ADDR_TX_PRESET;

  pipe_msgbus u_msgbus (
    .clk (pclk), .rst_n (pipe_rst_n),
    .req (mb_req), .addr (mb_addr), .wdata (pam4cfg),
    .busy (mb_busy), .done (mb_done), .timeout (mb_timeout),
    .m2p (pipe_m2p_msgbus), .p2m (pipe_p2m_msgbus)
  );

  assign pipe_rate      = pipe_rate_e'(rate_v);
  assign pipe_width     = width_v;
  assign pipe_powerdown = pipe_pwr_e'(pd_v);

  // ---- Tx datapath ---------------------------------------------------------------
  tx_ingress_gate u_tx_gate (
    .eth_clk (eth_clk), .eth_rst_n (eth_rst_n),
    .stop_req (ingress_stop), .fifo_full (tx_fifo_full),
    .eth_tvalid (eth_tvalid), .eth_tlast (eth_tlast),
    .eth_tready (eth_tready), .stopped (ingress_stopped_eth)
  );

  async_fifo #(.W(ETH_DATA_W+ETH_KEEP_W+1), .DEPTH(FIFO_DEPTH)) u_tx_cdc (
    .wclk   (eth_clk),   .wrst_n (eth_rst_n),
    .winc   (eth_tvalid && eth_tready),
    .wdata  ({eth_tlast, eth_tkeep, eth_tdata}),
    .wfull  (tx_fifo_full),
    .rclk   (pclk),      .rrst_n (pipe_rst_n),
    .rinc   (tx_fifo_rinc),
    .rdata  (tx_fifo_rdata),
    .rempty (tx_fifo_empty)
  );

  tx_framer u_tx_framer (
    .clk (pclk), .rst_n (pipe_rst_n),
    .fifo_rdata (tx_fifo_rdata), .fifo_empty (tx_fifo_empty), .fifo_rinc (tx_fifo_rinc),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .idle (framer_idle)
  );

  tx_egress u_tx_egress (
    .clk (pclk), .rst_n (pipe_rst_n),
    .tx_en (tx_en),
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .pipe_tx_data (pipe_tx_data),
    .pipe_tx_data_valid (pipe_tx_data_valid),
    .pipe_tx_start_block (pipe_tx_start_block),
    .busy (egress_busy)
  );

  // ---- Rx datapath: PIPE flit capture -> deframer -> async FIFO -> eth AXI-S ----
  rx_ingress u_rx_ingress (
    .clk (pclk), .rst_n (pipe_rst_n),
    .pipe_rx_data (pipe_rx_data), .pipe_rx_data_valid (pipe_rx_data_valid),
    .pipe_rx_start_block (pipe_rx_start_block),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_gap (rx_flit_gap),
    .flit_taken (rx_flit_taken), .idle (rx_ing_idle),
    .dropped_flits (rx_dropped_flits), .lock_errors (rx_lock_errors)
  );

  rx_deframer u_rx_deframer (
    .clk (pclk), .rst_n (pipe_rst_n),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_gap (rx_flit_gap),
    .flit_taken (rx_flit_taken),
    .fifo_wdata (rx_fifo_wdata), .fifo_winc (rx_fifo_winc), .fifo_full (rx_fifo_full),
    .idle (rx_dfr_idle), .bad_flits (rx_bad_flits), .aborted_frames (rx_aborted_frames)
  );

  async_fifo #(.W(ETH_DATA_W+ETH_KEEP_W+2), .DEPTH(FIFO_DEPTH)) u_rx_cdc (
    .wclk   (pclk),      .wrst_n (pipe_rst_n),
    .winc   (rx_fifo_winc),
    .wdata  (rx_fifo_wdata),
    .wfull  (rx_fifo_full),
    .rclk   (eth_clk),   .rrst_n (eth_rst_n),
    .rinc   (rx_fifo_rinc),
    .rdata  (rx_fifo_rdata),
    .rempty (rx_fifo_empty)
  );

  eth_egress u_eth_egress (
    .fifo_rdata (rx_fifo_rdata), .fifo_empty (rx_fifo_empty), .fifo_rinc (rx_fifo_rinc),
    .eth_rx_tvalid (eth_rx_tvalid), .eth_rx_tready (eth_rx_tready),
    .eth_rx_tdata (eth_rx_tdata), .eth_rx_tkeep (eth_rx_tkeep),
    .eth_rx_tlast (eth_rx_tlast), .eth_rx_tuser (eth_rx_tuser)
  );

  // mb_busy / rx_dfr_idle are observation points for DV/SVA (dv/sva binds).
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_obs = mb_busy ^ rx_dfr_idle;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : eth_dj_pipe7_bridge
