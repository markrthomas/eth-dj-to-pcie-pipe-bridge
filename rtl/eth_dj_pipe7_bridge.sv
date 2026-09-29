// ============================================================================
// eth_dj_pipe7_bridge.sv — TOP of the 802.3dj Ethernet <-> PCIe PIPE 7.1 bridge.
//
// STATUS: M2 — Tx (eth -> PIPE) and Rx (PIPE -> eth) datapaths implemented; control
// FSM and message bus are still M0 stubs (outputs tied off, inputs unconsumed).  Ports are frozen
// per docs/PLAN.md §2 (PAM4/Gen6 baseline).  The UNUSEDSIGNAL waiver below covers
// the still-unconsumed status/msgbus inputs and eth_tuser and MUST be removed as M2/M3 land.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

// M0 scaffold: the stub does not consume its inputs yet.  This UNUSEDSIGNAL
// waiver spans the whole module (it must be in effect at the port declarations)
// and MUST be removed once the datapath/control modules are wired in (M1+).
/* verilator lint_off UNUSEDSIGNAL */
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
  input  logic [ETH_USER_W-1:0]    eth_tuser,
  // egress: bridge -> Ethernet (AXI4-Stream)
  output logic                     eth_rx_tvalid,
  input  logic                     eth_rx_tready,
  output logic [ETH_DATA_W-1:0]    eth_rx_tdata,
  output logic [ETH_DATA_W/8-1:0]  eth_rx_tkeep,
  output logic                     eth_rx_tlast,
  output logic [ETH_USER_W-1:0]    eth_rx_tuser,

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
  output logic [MSGBUS_CMD_W-1:0]  pipe_m2p_cmd,
  output logic [MSGBUS_DATA_W-1:0] pipe_m2p_data,
  input  logic [MSGBUS_CMD_W-1:0]  pipe_p2m_cmd,
  input  logic [MSGBUS_DATA_W-1:0] pipe_p2m_data
);

  // ------------------------------------------------------------------------
  // M0 stub body.  Drive every output to a defined reset value so the design
  // elaborates and lints undriven-clean; consume no inputs yet.
  // TODO(M1+): instantiate ingress/tx_cdc/tx_gearbox/tx_framer/tx_egress and
  //            rx_ingress/rx_cdc/rx_deframer/eth_egress; add bridge_ctrl_fsm,
  //            pipe_msgbus, bridge_rf.  Remove the waiver above when done.

  // ---- M1 Tx path: eth AXI-S -> async FIFO -> flit framer -> PIPE serialiser ----
  logic                                 tx_fifo_full;
  logic [ETH_DATA_W+ETH_KEEP_W:0]       tx_fifo_rdata;
  logic                                 tx_fifo_empty, tx_fifo_rinc;
  logic                                 flit_valid, flit_taken;
  logic [FLIT_BYTES*8-1:0]              flit;

  assign eth_tready = !tx_fifo_full;

  // eth_tuser is not carried in M1 (docs/OPEN_DECISIONS.md D4).
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
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken)
  );

  tx_egress u_tx_egress (
    .clk (pclk), .rst_n (pipe_rst_n),
    .tx_en (1'b1),   // M1: link held in P0; M3 ctrl FSM drives this
    .flit_valid (flit_valid), .flit (flit), .flit_taken (flit_taken),
    .pipe_tx_data (pipe_tx_data),
    .pipe_tx_data_valid (pipe_tx_data_valid),
    .pipe_tx_start_block (pipe_tx_start_block)
  );

  // ---- M2 Rx path: PIPE flit capture -> deframer -> async FIFO -> eth AXI-S ----
  logic                            rx_flit_valid, rx_flit_taken;
  logic [FLIT_BYTES*8-1:0]         rx_flit;
  logic [ETH_DATA_W+ETH_KEEP_W:0]  rx_fifo_wdata, rx_fifo_rdata;
  logic                            rx_fifo_winc, rx_fifo_full, rx_fifo_empty, rx_fifo_rinc;
  logic [15:0]                     rx_dropped_flits, rx_lock_errors, rx_bad_flits;  // DV-visible

  rx_ingress u_rx_ingress (
    .clk (pclk), .rst_n (pipe_rst_n),
    .pipe_rx_data (pipe_rx_data), .pipe_rx_data_valid (pipe_rx_data_valid),
    .pipe_rx_start_block (pipe_rx_start_block),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_taken (rx_flit_taken),
    .dropped_flits (rx_dropped_flits), .lock_errors (rx_lock_errors)
  );

  rx_deframer u_rx_deframer (
    .clk (pclk), .rst_n (pipe_rst_n),
    .flit_valid (rx_flit_valid), .flit (rx_flit), .flit_taken (rx_flit_taken),
    .fifo_wdata (rx_fifo_wdata), .fifo_winc (rx_fifo_winc), .fifo_full (rx_fifo_full),
    .bad_flits (rx_bad_flits)
  );

  async_fifo #(.W(ETH_DATA_W+ETH_KEEP_W+1), .DEPTH(FIFO_DEPTH)) u_rx_cdc (
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

  assign pipe_rate          = RATE_GEN6;   // PAM4 baseline
  assign pipe_width         = 2'b00;
  // M1 PLACEHOLDER: no control FSM yet, so the link is held in P0 to let the Tx
  // path run.  TODO(M3): bridge_ctrl_fsm owns powerdown (reset value P1 -> P0 via
  // the message bus) and must drain flits before leaving P0.
  assign pipe_powerdown     = PWR_P0;

  assign pipe_m2p_cmd       = '0;
  assign pipe_m2p_data      = '0;

endmodule : eth_dj_pipe7_bridge
/* verilator lint_on UNUSEDSIGNAL */
