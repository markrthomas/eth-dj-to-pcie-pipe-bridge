// ============================================================================
// formal/ctrl_fv.sv — control-plane / Tx flow-control safety (ASSERTIONS.md F-*).
// Composes the real bridge_ctrl_fsm + pipe_msgbus + tx_egress (pclk domain).  Run twice: default
// and -DFLOW_CTRL_OVERRIDE (ctrl.sby tasks *_fc), where credit_ok / cr_req are free inputs so a
// credit-only flit may start at any time tx_en allows (D16).
// Everything else is a free input: CSR requests, PhyStatus, message-bus
// responses, the ingress-stopped handshake, Rx idle and the framer's flit_valid.
// The only environment constraint mirrors the top-level wiring:
//   tx_idle = !egress_busy && !flit_valid && <free>   (framer holds no flit)
// Properties (prove, PDR):
//   F-PP1  Tx data_valid only in P0 and only in ST_ACTIVE / ST_DRAIN
//   F-PP3  flits are FLIT_BEATS contiguous beats; start_block only at a boundary
//   F-PP4  rate / width / powerdown pins change only in their change state
//   F-PP5  a pin-change state is left within PHY_TIMEOUT cycles
//   F-MB1  no msgbus request while one is outstanding
//   F-MB3  m2p byte-bus framing: {WR_C,addr[11:8]}, addr[7:0], data, then idle 8'h00
//   F-MB4  no PIPE pin change while a msgbus write is outstanding
//   F-MB5  the msgbus master is busy for at most PHY_TIMEOUT + 3 cycles
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module ctrl_fv
  import eth_dj_pipe7_pkg::*;
(
  input logic       clk,
  input logic       rst_n,
  input logic [1:0] pwr_req,
  input logic [2:0] rate_req,
  input logic [1:0] width_req,
  input logic       pam4_wr,
  input logic       phy_status,
  input logic       ingress_stopped,
  input logic       rx_idle,
  input logic       other_idle,
  input logic       flit_valid,
  input logic       fc_credit_ok,    // FLOW_CTRL builds only: free (credit / credit-only-flit requests)
  input logic       fc_cr_req,
  input logic [MSGBUS_W-1:0] p2m       // PHY -> MAC byte bus (free)
);
  localparam int BW = $clog2(FLIT_BEATS) + 1;

  logic [1:0] pd, width;
  logic [2:0] rate, state;
  logic       tx_en, ingress_stop, mb_req, mb_busy, mb_done, mb_timeout;
  logic       ev_op_done, ev_phy_timeout;
  logic       flit_taken, egress_busy, tx_valid, tx_sb;
  logic [PIPE_BUS_W-1:0] tx_data;
  logic [MSGBUS_W-1:0] m2p;
  wire  [MB_ADDR_W-1:0] mb_addr = MB_ADDR_TX_PRESET;
  wire  [7:0] mb_wdata = 8'h35;
  // with FLOW_CTRL a wanted credit-only flit counts as Tx activity (eth_dj_pipe7_bridge tx_idle)
  wire        tx_idle = !egress_busy && !flit_valid && other_idle && !(FLOW_CTRL && fc_cr_req);

  bridge_ctrl_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .pwr_req(pwr_req), .rate_req(rate_req), .width_req(width_req),
    .pam4_wr(pam4_wr), .powerdown(pd), .rate(rate), .width(width), .phy_status(phy_status),
    .tx_en(tx_en), .ingress_stop(ingress_stop), .ingress_stopped(ingress_stopped),
    .tx_idle(tx_idle), .rx_idle(rx_idle), .mb_req(mb_req), .mb_done(mb_done),
    .mb_timeout(mb_timeout), .state(state), .ev_op_done(ev_op_done),
    .ev_phy_timeout(ev_phy_timeout));

  pipe_msgbus u_mb (
    .clk(clk), .rst_n(rst_n), .req(mb_req), .addr(mb_addr), .wdata(mb_wdata),
    .busy(mb_busy), .done(mb_done), .timeout(mb_timeout),
    .m2p(m2p), .p2m(p2m));

  tx_egress u_eg (
    .clk(clk), .rst_n(rst_n), .tx_en(tx_en), .flit_valid(flit_valid),
    .credit_ok(fc_credit_ok), .cr_req(fc_cr_req), .seq_now(16'd0), .cl_now(16'd0), .st_any(), .st_data(),
    .flit({FLIT_BYTES*8{1'b0}}), .flit_taken(flit_taken),
    .pipe_tx_data(tx_data), .pipe_tx_data_valid(tx_valid), .pipe_tx_start_block(tx_sb),
    .busy(egress_busy));

  // ---- environment -------------------------------------------------------------
  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;
  always @(*) if (!f_past) assume (!rst_n); else assume (rst_n);

  // ---- auxiliary state ------------------------------------------------------------
  wire in_chg = (state == ST_RATE_CHG) || (state == ST_WIDTH_CHG) || (state == ST_PWR_CHG);
  logic [BW-1:0] beat_q;
  logic [11:0]   chg_cnt_q, busy_cnt_q;
  logic [1:0]    pd_q, width_q;
  logic [2:0]    rate_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      beat_q <= '0; chg_cnt_q <= '0; busy_cnt_q <= '0;
    end else begin
      if (tx_sb)         beat_q <= BW'(1);
      else if (tx_valid) beat_q <= (int'(beat_q) == FLIT_BEATS - 1) ? '0 : beat_q + BW'(1);
      chg_cnt_q  <= in_chg  ? chg_cnt_q + 12'd1  : 12'd0;
      busy_cnt_q <= mb_busy ? busy_cnt_q + 12'd1 : 12'd0;
    end
    pd_q <= pd; rate_q <= rate; width_q <= width;
  end

  // ---- properties ------------------------------------------------------------------
  always @(*) if (f_past && rst_n) begin
    a_fpp1_tx_only_p0:   assert (!tx_valid || (pd == PWR_P0 && (state == ST_ACTIVE || state == ST_DRAIN)));
    a_fpp3_sb_boundary:  assert (!tx_sb || (tx_valid && beat_q == '0));
    a_fpp3_contiguous:   assert (beat_q == '0 || (tx_valid && !tx_sb));
    a_fpp3_no_headless:  assert (!(tx_valid && !tx_sb) || beat_q != '0);
    a_fpp5_chg_bound:    assert (chg_cnt_q <= PHY_TIMEOUT);
    a_fmb5_busy_bound:   assert (busy_cnt_q <= PHY_TIMEOUT + 3);
    // helper invariants (also proven): tie the bound counters to the RTL timers so
    // PDR does not have to discover the 11-bit correlation itself.  yosys-slang
    // resolves these hierarchical references; they are read-only.
    h_chg_tmr:    assert (!in_chg || (chg_cnt_q == 12'(u_ctrl.tmr_q) && int'(u_ctrl.tmr_q) < PHY_TIMEOUT));
    h_mb_addr:    assert (u_mb.st_q != 2'd1 || busy_cnt_q == 12'd0);
    h_mb_data:    assert (u_mb.st_q != 2'd2 || busy_cnt_q == 12'd1);
    h_mb_wait:    assert (u_mb.st_q != 2'd3 || (busy_cnt_q == 12'(u_mb.tmr_q) + 12'd2 &&
                                                 int'(u_mb.tmr_q) < PHY_TIMEOUT));
    a_fmb1_one_outst:    assert (!(mb_req && mb_busy));
    // byte-bus framing, aligned to the msgbus master state (ADDR=1 -> byte0, DATA=2 -> byte1,
    // first WAIT cycle (busy_cnt 2) -> data byte, everything else idle)
    a_fmb3_byte0:        assert (u_mb.st_q != 2'd1 || m2p == {MB_WR_C, mb_addr[MB_ADDR_W-1:8]});
    a_fmb3_byte1:        assert (u_mb.st_q != 2'd2 || m2p == mb_addr[7:0]);
    a_fmb3_data:         assert (!(u_mb.st_q == 2'd3 && busy_cnt_q == 12'd2) || m2p == mb_wdata);
    a_fmb3_idle:         assert ((u_mb.st_q != 2'd0 && !(u_mb.st_q == 2'd3 && busy_cnt_q > 12'd2)) || m2p == 8'h00);
    a_fmb4_no_chg_in_mb: assert (!(in_chg && mb_busy));
  end
  always @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    a_fpp4_rate_pin:  assert (rate  == rate_q  || state == ST_RATE_CHG);
    a_fpp4_width_pin: assert (width == width_q || state == ST_WIDTH_CHG);
    a_fpp4_pd_pin:    assert (pd    == pd_q    || state == ST_PWR_CHG);
  end

  // ---- covers ------------------------------------------------------------------------
  always @(*) if (f_past && rst_n) begin
    c_tx_flit:     cover (tx_sb && state == ST_ACTIVE);
    c_p2:          cover (pd == PWR_P2);
    c_gen5_active: cover (rate == RATE_GEN5 && state == ST_ACTIVE);
    c_cfg_ack:     cover (mb_done);
    c_drain_flit:  cover (state == ST_DRAIN && tx_valid);
  end
endmodule
