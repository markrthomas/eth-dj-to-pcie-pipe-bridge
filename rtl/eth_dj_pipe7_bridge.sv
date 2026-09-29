// ============================================================================
// eth_dj_pipe7_bridge.sv — TOP of the 802.3dj Ethernet <-> PCIe PIPE 7.1 bridge.
//
// STATUS: M0 SCAFFOLD.  Ports are frozen per docs/PLAN.md §2 (PAM4/Gen6
// baseline); the body is an intentional stub — all outputs are driven to a
// defined reset value and inputs are not yet consumed.  The lint waivers below
// are M0-ONLY and MUST be removed as the datapath/control modules (see
// docs/PLAN.md §3 module inventory) are filled in (M1+).
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

  assign eth_tready         = 1'b0;

  assign eth_rx_tvalid      = 1'b0;
  assign eth_rx_tdata       = '0;
  assign eth_rx_tkeep       = '0;
  assign eth_rx_tlast       = 1'b0;
  assign eth_rx_tuser       = '0;

  assign pipe_tx_data       = '0;
  assign pipe_tx_data_valid = 1'b0;
  assign pipe_tx_start_block= 1'b0;

  assign pipe_rate          = RATE_GEN6;   // PAM4 baseline
  assign pipe_width         = 2'b00;
  assign pipe_powerdown     = PWR_P1;      // start in low power until brought up

  assign pipe_m2p_cmd       = '0;
  assign pipe_m2p_data      = '0;

endmodule : eth_dj_pipe7_bridge
/* verilator lint_on UNUSEDSIGNAL */
