// ============================================================================
// bridge_ctrl_fsm.sv — pclk domain.  Bridge control plane: converges the PIPE
// link state (powerdown / rate / width / PAM4 Tx control) onto the requested
// state held in bridge_rf, one operation at a time, draining the datapath first.
//
//   reset -> ST_RESET (powerdown = P1, wait PhyStatus low = PHY reset done)
//         -> ST_LOWPWR -> (req P0) ST_PWR_CHG -> ST_DRAIN -> ST_CFG -> ST_DRAIN -> ST_ACTIVE
//
// ST_ACTIVE : P0, tx_en=1, Ethernet ingress open.  Any pending change -> ST_DRAIN.
// ST_DRAIN  : ingress closes at the next frame boundary (tx_ingress_gate), the Tx
//             pipeline keeps running until empty and the Rx capture is idle
//             ("drained").  Then ONE operation is chosen, in priority order:
//             rate change, width change, PAM4 msgbus write (Gen6 only), power
//             down to P1; with nothing pending it returns to ST_ACTIVE.
// ST_RATE_CHG / ST_WIDTH_CHG / ST_PWR_CHG : drive the new value on the PIPE pin
//             and wait for a PhyStatus pulse (or PHY_TIMEOUT -> sticky error,
//             transition treated as complete; docs/OPEN_DECISIONS.md D10).
// ST_CFG    : committed msgbus write of the Tx preset index (PAM4CFG) to MB_ADDR_TX_PRESET.
// ST_LOWPWR : P1/P2, datapath gated.  Steps P1<->P2 and P1->P0 on request
//             (P2->P0 goes via P1).  Rate/width changes wait until back in P0.
// P0s is not supported: a P0s request is flagged (bad_pwr_req) and treated as P0.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module bridge_ctrl_fsm
  import eth_dj_pipe7_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // requested state (bridge_rf)
  input  logic [1:0]  pwr_req,
  input  logic [2:0]  rate_req,
  input  logic [1:0]  width_req,
  input  logic        pam4_wr,          // PAM4CFG register written (re-send it)

  // PIPE pins (as logic vectors; the top casts to the pkg enums)
  output logic [1:0]  powerdown,
  output logic [2:0]  rate,
  output logic [1:0]  width,
  input  logic        phy_status,

  // datapath drain handshake
  output logic        tx_en,            // tx_egress may start flits
  output logic        ingress_stop,     // to tx_ingress_gate (eth_clk, synchronised there)
  input  logic        ingress_stopped,  // from tx_ingress_gate, already synchronised to clk
  input  logic        tx_idle,          // Tx CDC FIFO empty, framer + egress idle
  input  logic        rx_idle,          // rx_ingress not mid-flit and holding nothing

  // message bus master
  output logic        mb_req,
  input  logic        mb_done,
  input  logic        mb_timeout,

  // status / events
  output logic [2:0]  state,
  output logic        ev_op_done,        // pulse: one power/rate/width/cfg op completed
  output logic        ev_phy_timeout     // pulse
);
  localparam int unsigned TW = $clog2(PHY_TIMEOUT + 1);

  logic [2:0]    st_q;
  logic [1:0]    pd_q;
  logic [2:0]    rate_q;
  logic [1:0]    width_q;
  logic          pam4_dirty_q;
  logic [TW-1:0] tmr_q;

  wire [1:0] pwr_eff   = (pwr_req == PWR_P0S) ? PWR_P0 : pwr_req;
  wire       need_rate = (rate_req  != rate_q);
  wire       need_wid  = (width_req != width_q);
  wire       need_cfg  = pam4_dirty_q && (rate_q == RATE_GEN6);
  wire       need_pwr  = (pwr_eff != PWR_P0);
  wire       drained   = ingress_stopped && tx_idle && rx_idle;
  wire       tmo       = (int'(tmr_q) == PHY_TIMEOUT - 1);

  assign powerdown    = pd_q;
  assign rate         = rate_q;
  assign width        = width_q;
  assign state        = st_q;
  assign tx_en        = (st_q == ST_ACTIVE) || (st_q == ST_DRAIN);
  assign ingress_stop = (st_q != ST_ACTIVE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q           <= ST_RESET;
      pd_q           <= PWR_P1;
      rate_q         <= RATE_GEN6;
      width_q        <= 2'b00;
      pam4_dirty_q   <= 1'b1;
      tmr_q          <= '0;
      mb_req         <= 1'b0;
      ev_op_done     <= 1'b0;
      ev_phy_timeout <= 1'b0;
    end else begin
      mb_req         <= 1'b0;
      ev_op_done     <= 1'b0;
      ev_phy_timeout <= 1'b0;
      if (pam4_wr) pam4_dirty_q <= 1'b1;

      case (st_q)
        ST_RESET: begin
          if (!phy_status) st_q <= ST_LOWPWR;
        end

        ST_LOWPWR: begin
          tmr_q <= '0;
          if (pwr_eff == PWR_P0 || (pwr_eff == PWR_P1 && pd_q == PWR_P2)) begin
            pd_q     <= (pd_q == PWR_P2) ? PWR_P1 : PWR_P0;
            st_q     <= ST_PWR_CHG;
          end else if (pwr_eff == PWR_P2 && pd_q == PWR_P1) begin
            pd_q     <= PWR_P2;
            st_q     <= ST_PWR_CHG;
          end
        end

        ST_ACTIVE: begin
          // 4-phase with tx_ingress_gate: leave ACTIVE only once the gate has
          // been seen open, so the `stopped` seen in ST_DRAIN is never stale.
          if ((need_rate || need_wid || need_cfg || need_pwr) && !ingress_stopped)
            st_q <= ST_DRAIN;
        end

        ST_DRAIN: begin
          tmr_q <= '0;
          if (drained) begin
            if (need_rate) begin
              rate_q <= rate_req;
              st_q   <= ST_RATE_CHG;
            end else if (need_wid) begin
              width_q <= width_req;
              st_q    <= ST_WIDTH_CHG;
            end else if (need_cfg) begin
              mb_req <= 1'b1;
              st_q   <= ST_CFG;
            end else if (need_pwr) begin
              pd_q     <= PWR_P1;
              st_q     <= ST_PWR_CHG;
            end else begin
              st_q <= ST_ACTIVE;
            end
          end
        end

        ST_RATE_CHG, ST_WIDTH_CHG, ST_PWR_CHG: begin
          if (phy_status || tmo) begin
            ev_op_done     <= 1'b1;
            ev_phy_timeout <= !phy_status;
            if (st_q == ST_RATE_CHG) pam4_dirty_q <= 1'b1;   // re-send PAM4 ctl at new rate
            if (st_q == ST_PWR_CHG && pd_q != PWR_P0) st_q <= ST_LOWPWR;
            else                                           st_q <= ST_DRAIN;
          end else begin
            tmr_q <= tmr_q + TW'(1);
          end
        end

        default: begin // ST_CFG
          if (mb_done || mb_timeout) begin
            ev_op_done   <= 1'b1;
            if (!pam4_wr) pam4_dirty_q <= 1'b0;   // a write racing the send keeps it dirty
            st_q         <= ST_DRAIN;
          end
        end
      endcase
    end
  end

endmodule : bridge_ctrl_fsm
