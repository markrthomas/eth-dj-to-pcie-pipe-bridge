// ============================================================================
// formal/fc_fv.sv — link flow-control controller (fc_ctl, built with FLOW_CTRL on,
// docs/OPEN_DECISIONS.md D16), pclk domain.  Everything but the reset is a free input;
// environment (mirrors tx_egress / rx_ingress):
//   * a data flit starts only when credit_ok (tx_egress start_data), st_data implies st_any
//   * the remote credit limit only moves forward (modular, < 2^15 per step) from 0, and an
//     update never lands more than 2^14 flits ahead of the flits sent
//   F-FC1  the sender never runs past the remote's advertised limit: cl_remote - sent >= 0
//   F-FC2  credit_ok implies at least one credit is left
//   F-FC3  a credit-only flit is requested only when the advertised limit is stale
//   F-FC4  the advertised seq field is the count of data flits actually started
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module fc_fv
  import eth_dj_pipe7_pkg::*;
(
  input logic                    clk,
  input logic                    rst_n,
  input logic                    dfr_data_done,
  input logic [15:0]             lost_cnt,
  input logic [$clog2(FIFO_DEPTH):0] rx_wfree,
  input logic [15:0]             cl_remote,
  input logic                    st_any,
  input logic                    st_data
);
  logic        credit_ok, cr_req;
  logic [15:0] seq_now, cl_now;
  fc_ctl dut (.clk(clk), .rst_n(rst_n), .dfr_data_done(dfr_data_done), .lost_cnt(lost_cnt),
              .rx_wfree(rx_wfree), .cl_remote(cl_remote), .st_any(st_any), .st_data(st_data),
              .credit_ok(credit_ok), .cr_req(cr_req), .seq_now(seq_now), .cl_now(cl_now));

  logic        f_past = 1'b0;
  logic [15:0] cl_prev, sent_q;
  always @(posedge clk) begin
    f_past  <= 1'b1;
    cl_prev <= cl_remote;
    if (!rst_n) sent_q <= '0; else if (st_data) sent_q <= sent_q + 16'd1;
  end

  always @(*) begin
    if (!f_past) assume (!rst_n); else assume (rst_n);
    assume (!st_data || st_any);
    assume (!st_data || credit_ok);
    if (f_past) begin
      assume ((cl_remote - cl_prev) < 16'h8000);       // forward only
      // an update never advertises more than 2^14 flits ahead of what was sent (the remote's
      // window is one Rx FIFO); a stale limit is left alone
      assume (cl_remote == cl_prev || (cl_remote - dut.s_cnt_q) < 16'h4000);
    end else begin
      assume (cl_remote == 16'd0);                      // rx_ingress resets it to 0
    end
  end

  always @(*) if (f_past && rst_n) begin
    a_fc1_no_overrun: assert (!(cl_remote - dut.s_cnt_q > 16'h7FFF));
    a_fc2_credit:     assert (!credit_ok || (cl_remote != dut.s_cnt_q));
    a_fc3_cr_stale:   assert (!cr_req || (cl_now != dut.cl_last_q));
    a_fc4_seq:        assert (seq_now == sent_q);
    c_send:           cover (st_data);
    c_cr:             cover (cr_req && st_any && !st_data);
  end
endmodule
