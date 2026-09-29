// ============================================================================
// eth_dj_pipe7_pkg.sv — parameters, typedefs, and enums for the
// 802.3dj Ethernet <-> PCIe PIPE 7.1 bridge.
//
// BASELINE: PCIe Gen6 (64 GT/s, PAM4, FLIT mode) on the PIPE side; 802.3dj
// 200G/lane PAM4 on the Ethernet side.  See docs/PLAN.md and docs/pam4_notes.md.
//
// STATUS: M0 scaffold — parameter values are the first-cut targets and are
// marked [OPEN] in docs/PLAN.md §2.3 / §12 until frozen against the rate ratio.
// ============================================================================
`ifndef ETH_DJ_PIPE7_PKG_SV
`define ETH_DJ_PIPE7_PKG_SV

package eth_dj_pipe7_pkg;

  // Several params below are defined now for the frozen interface/microarch but
  // are not consumed until the datapath/control modules land (M1+); waive the
  // "unused parameter" lint until then.
  /* verilator lint_off UNUSEDPARAM */

  // ---- PAM4 signaling (both sides are PAM4) --------------------------------
  // A PAM4 symbol carries 2 bits (4 amplitude levels).  The bridge is a DIGITAL
  // adapter: it never sees analog levels, but the datapath widths and the
  // Gen6 FLIT framing below are chosen to match PAM4-rate parallel buses.
  localparam int unsigned PAM4_BITS_PER_SYM = 2;

  // ---- 802.3dj (Ethernet MAC/PCS) side, AXI4-Stream packet interface -------
  localparam int unsigned ETH_DATA_W = 256;              // [OPEN] §2.3
  localparam int unsigned ETH_KEEP_W = ETH_DATA_W / 8;
  localparam int unsigned ETH_USER_W = 8;                // SOF/err/lane-tag

  // ---- PCIe PIPE 7.1 side (Gen6 FLIT mode) ---------------------------------
  localparam int unsigned PIPE_NLANES  = 1;              // [OPEN] lane-parametric
  localparam int unsigned PIPE_DATA_W  = 64;             // per-lane parallel bus
  localparam int unsigned PIPE_BUS_W   = PIPE_DATA_W * PIPE_NLANES;

  // Gen6 FLIT: fixed 256-byte flit (242 TLP + 6 DLP + 8 FEC/CRC).  The bridge
  // treats the FEC/CRC bytes as passthrough in the first cut (see pam4_notes).
  localparam int unsigned FLIT_BYTES = 256;

  // ---- PIPE 7.x message bus (4-bit command interface) ----------------------
  localparam int unsigned MSGBUS_CMD_W  = 4;
  localparam int unsigned MSGBUS_DATA_W = 8;

  // ---- Elastic / CDC buffering --------------------------------------------
  localparam int unsigned FIFO_DEPTH = 32;               // [OPEN] size vs burst

  // ---- PIPE data rate (rate[2:0] on the PIPE interface) --------------------
  typedef enum logic [2:0] {
    RATE_GEN1 = 3'd0,   //  2.5 GT/s NRZ
    RATE_GEN2 = 3'd1,   //  5.0 GT/s NRZ
    RATE_GEN3 = 3'd2,   //  8.0 GT/s NRZ
    RATE_GEN4 = 3'd3,   // 16.0 GT/s NRZ
    RATE_GEN5 = 3'd4,   // 32.0 GT/s NRZ
    RATE_GEN6 = 3'd5    // 64.0 GT/s PAM4  <-- baseline
  } pipe_rate_e;

  // ---- PIPE power state (powerdown[1:0]) -----------------------------------
  typedef enum logic [1:0] {
    PWR_P0  = 2'd0,     // active
    PWR_P0S = 2'd1,     // active standby
    PWR_P1  = 2'd2,     // low power, PLL on
    PWR_P2  = 2'd3      // lowest power
  } pipe_pwr_e;

  // ---- bridge control FSM --------------------------------------------------
  typedef enum logic [2:0] {
    ST_RESET     = 3'd0,
    ST_CFG       = 3'd1,   // program rf via message bus
    ST_ACTIVE    = 3'd2,   // P0, datapath running
    ST_DRAIN     = 3'd3,   // flush datapath before a PM / rate / width change
    ST_RATE_CHG  = 3'd4,
    ST_WIDTH_CHG = 3'd5,
    ST_LOWPWR    = 3'd6    // P1/P2
  } bridge_state_e;

  /* verilator lint_on UNUSEDPARAM */

endpackage : eth_dj_pipe7_pkg

`endif // ETH_DJ_PIPE7_PKG_SV
