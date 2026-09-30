// ============================================================================
// bridge_rf.sv — pclk domain.  Config/status register file behind a minimal
// always-ready CSR port (write on csr_valid && csr_write; csr_rdata is the
// combinational read of csr_addr).  Map: eth_dj_pipe7_pkg CSR_* and
// docs/OPEN_DECISIONS.md D7.
//
//   CTRL    RW  [1:0] pwr_req (rst P0)  [4:2] rate_req (rst GEN6)  [6:5] width_req (rst 0)
//   PAM4CFG RW  [5:0] Gen6 Tx preset index = PHY LocalPresetIndex (rst PAM4CFG_RST = 64 GT/s P0);
//                    [7:6] read 0 / write ignored (PHY bit 7 is a coefficient-request strobe);
//                    a write re-sends it to the PHY (CSR name kept for compatibility)
//   STATUS  RO  [1:0] powerdown [4:2] rate [6:5] width [9:7] ctrl state
//               [10] busy (op in flight) [11] link active (ST_ACTIVE)
//               [12] pipe_rx_elec_idle [13] pipe_rx_valid
//   ERR     W1C [0] PhyStatus timeout [1] msgbus timeout [2] P0s requested (unsupported)
//   RXCNT0  RO  [15:0] Rx flits dropped (overflow) [31:16] Rx lock errors
//   RXCNT1  RO  [15:0] Rx bad/orphan flits [31:16] Rx frames aborted (tuser[0] err)
//   PMCNT   RO  [15:0] completed control operations (saturating)
// Unmapped addresses read 0; writes to RO/unmapped addresses are ignored.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module bridge_rf
  import eth_dj_pipe7_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  input  logic                   csr_valid,
  input  logic                   csr_write,
  input  logic [CSR_ADDR_W-1:0]  csr_addr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]            csr_wdata,     // [31:8] reserved
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0]            csr_rdata,

  // config out
  output logic [1:0]             pwr_req,
  output logic [2:0]             rate_req,
  output logic [1:0]             width_req,
  output logic [7:0]             pam4cfg,
  output logic                   pam4_wr,

  // status in
  input  logic [1:0]             st_powerdown,
  input  logic [2:0]             st_rate,
  input  logic [1:0]             st_width,
  input  logic [2:0]             st_state,
  input  logic                   st_rx_elec_idle,
  input  logic                   st_rx_valid,
  input  logic                   ev_op_done,
  input  logic                   ev_phy_timeout,
  input  logic                   ev_mb_timeout,
  input  logic                   ev_bad_pwr_req,
  input  logic [15:0]            rx_dropped_flits,
  input  logic [15:0]            rx_lock_errors,
  input  logic [15:0]            rx_bad_flits,
  input  logic [15:0]            rx_aborted_frames
);
  logic [2:0]  err_q;
  logic [15:0] opcnt_q;

  wire wr = csr_valid && csr_write;

  assign pam4_wr = wr && (csr_addr == CSR_PAM4CFG);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pwr_req   <= PWR_P0;
      rate_req  <= RATE_GEN6;
      width_req <= 2'b00;
      pam4cfg   <= PAM4CFG_RST;
      err_q     <= '0;
      opcnt_q   <= '0;
    end else begin
      if (wr && csr_addr == CSR_CTRL) begin
        pwr_req   <= csr_wdata[1:0];
        rate_req  <= csr_wdata[4:2];
        width_req <= csr_wdata[6:5];
      end
      if (pam4_wr) pam4cfg <= {2'b00, csr_wdata[5:0]};
      // W1C, with set taking priority over a same-cycle clear
      err_q <= (err_q & ~((wr && csr_addr == CSR_ERR) ? csr_wdata[2:0] : 3'b000))
             | {ev_bad_pwr_req, ev_mb_timeout, ev_phy_timeout};
      if (ev_op_done && opcnt_q != 16'hFFFF) opcnt_q <= opcnt_q + 16'd1;
    end
  end

  wire busy = !(st_state == ST_ACTIVE || st_state == ST_LOWPWR);

  always_comb begin
    csr_rdata = '0;
    case (csr_addr)
      CSR_CTRL:    csr_rdata = {25'b0, width_req, rate_req, pwr_req};
      CSR_PAM4CFG: csr_rdata = {24'b0, pam4cfg};
      CSR_STATUS:  csr_rdata = {18'b0, st_rx_valid, st_rx_elec_idle,
                                (st_state == ST_ACTIVE), busy, st_state,
                                st_width, st_rate, st_powerdown};
      CSR_ERR:     csr_rdata = {29'b0, err_q};
      CSR_RXCNT0:  csr_rdata = {rx_lock_errors, rx_dropped_flits};
      CSR_RXCNT1:  csr_rdata = {rx_aborted_frames, rx_bad_flits};
      CSR_PMCNT:   csr_rdata = {16'b0, opcnt_q};
      default:     csr_rdata = '0;
    endcase
  end

endmodule : bridge_rf
