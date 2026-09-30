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
`ifdef PIPE_NLANES_OVERRIDE
  localparam int unsigned PIPE_NLANES  = `PIPE_NLANES_OVERRIDE;   // compile-time lane count
`else
  localparam int unsigned PIPE_NLANES  = 1;              // default x1 (OPEN_DECISIONS D1)
`endif
  localparam int unsigned PIPE_DATA_W  = 64;             // per-lane parallel bus
  localparam int unsigned PIPE_BUS_W   = PIPE_DATA_W * PIPE_NLANES;

  // Gen6 FLIT: fixed 256-byte flit (242 TLP + 6 DLP + 8 FEC/CRC).  The bridge
  // treats the FEC/CRC bytes as passthrough in the first cut (see pam4_notes).
  localparam int unsigned FLIT_BYTES = 256;

  // ---- Bridge flit format (docs/OPEN_DECISIONS.md D2, adopted) --------------
  // Ethernet frame bytes are tunnelled opaquely in the flit payload area:
  //   byte 0        : {5'b0, eof, sof, valid}   (valid=1 for every emitted flit)
  //   byte 1        : payload byte count in this flit (0..FLIT_PAYLOAD_B)
  //   bytes 2..241  : frame bytes (FLIT_PAYLOAD_B = 240), zero padded
  //   bytes 242..247: DLP placeholder (zero), 248..255: FEC/CRC placeholder (zero)
  // PIPE Tx serialises the flit LSB-byte first, PIPE_BUS_W bits per pclk beat.
  localparam int unsigned FLIT_HDR_B     = 2;
  localparam int unsigned FLIT_PAYLOAD_B = 240;
  localparam int unsigned FLIT_BEATS     = FLIT_BYTES * 8 / PIPE_BUS_W;

  // ---- PIPE 7.x message bus (docs/OPEN_DECISIONS.md D8) --------------------
  // One 8-bit M2P and one 8-bit P2M byte bus (PIPE 7.1 M2P/P2M_MessageBus[7:0]),
  // PCLK-synchronous, idle = 8'h00, any non-idle byte starts a transaction.
  // Framing (cross-checked against the sibling ucie-rdi-to-pcie6-pipe7 model,
  // which cites PIPE 7.1 §6.1.4.2 Tables 6-10..6-14; NOT checked against the
  // spec text itself):
  //   write_committed : byte0 {MB_WR_C, addr[11:8]}, byte1 addr[7:0], byte2 data[7:0]
  //   PHY completes it with one P2M byte {MB_WR_ACK, x}.
  localparam int unsigned MSGBUS_W      = 8;
  localparam int unsigned MB_ADDR_W     = 12;
  localparam logic [3:0] MB_NOP    = 4'h0;
  localparam logic [3:0] MB_WR_UC  = 4'h1;
  localparam logic [3:0] MB_WR_C   = 4'h2;
  localparam logic [3:0] MB_RD     = 4'h3;
  localparam logic [3:0] MB_RD_CPL = 4'h4;
  localparam logic [3:0] MB_WR_ACK = 4'h5;
  // PHY register that receives the PAM4 Tx control byte.  12'h400..12'h40A is the
  // PHY Tx Control block in the sibling model; the exact sub-offset for PAM4 is
  // NOT pinned there either (12'h406 is its working offset for PAM4RestrictedLevels),
  // and the meaning of our PAM4CFG byte (precoding enable / preset) is a
  // bridge-defined placeholder.  *Verify both against the PIPE 7.1 PHY register map.*
  localparam logic [MB_ADDR_W-1:0] MB_ADDR_PAM4_TXCTL = 12'h406;

  // Cycles the control plane waits for PhyStatus / a message-bus write_ack
  // before flagging a timeout (docs/OPEN_DECISIONS.md D10).
  localparam int unsigned PHY_TIMEOUT = 1024;

  // ---- bridge_rf CSR map (pclk domain, docs/OPEN_DECISIONS.md D7) ----------
  localparam int unsigned CSR_ADDR_W = 8;
  localparam logic [7:0] CSR_CTRL    = 8'h00;  // RW  [1:0] pwr_req [4:2] rate_req [6:5] width_req
  localparam logic [7:0] CSR_PAM4CFG = 8'h04;  // RW  [7:0] PAM4 Tx control sent over the msgbus
  localparam logic [7:0] CSR_STATUS  = 8'h08;  // RO  see bridge_rf.sv
  localparam logic [7:0] CSR_ERR     = 8'h0C;  // W1C [0] phystatus timeout [1] msgbus timeout [2] bad pwr req
  localparam logic [7:0] CSR_RXCNT0  = 8'h10;  // RO  [15:0] dropped flits [31:16] lock errors
  localparam logic [7:0] CSR_RXCNT1  = 8'h14;  // RO  [15:0] bad/orphan flits [31:16] aborted frames
  localparam logic [7:0] CSR_PMCNT   = 8'h18;  // RO  [15:0] completed power/rate/width/cfg operations
  localparam logic [7:0] PAM4CFG_RST = 8'h01;  // precoding enabled, preset 0

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
    ST_CFG       = 3'd1,   // send PAM4 Tx control to the PHY over the message bus
    ST_ACTIVE    = 3'd2,   // P0, datapath running
    ST_DRAIN     = 3'd3,   // flush datapath before a PM / rate / width change
    ST_RATE_CHG  = 3'd4,
    ST_WIDTH_CHG = 3'd5,
    ST_LOWPWR    = 3'd6,   // P1/P2
    ST_PWR_CHG   = 3'd7    // powerdown change in flight (waiting for PhyStatus)
  } bridge_state_e;

  /* verilator lint_on UNUSEDPARAM */

endpackage : eth_dj_pipe7_pkg

`endif // ETH_DJ_PIPE7_PKG_SV
