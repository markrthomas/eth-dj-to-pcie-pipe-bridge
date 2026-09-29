// ============================================================================
// formal/ingress_gate_fv.sv — Ethernet ingress drain gate (tx_ingress_gate),
// black-box, eth_clk domain.  stop_req / fifo_full / eth_tvalid / eth_tlast are
// free (the MAC is constrained to AXI4-S: a beat is held until accepted).
//   F-IG1  never accept a beat while the CDC FIFO is full
//   F-IG2  a frame that has started is never blocked except by fifo_full
//   F-IG3  with stop_req held >= 2 cycles, no new frame is accepted
//   F-IG4  `stopped` is only reported between frames, and only while stopping
// ============================================================================
module ingress_gate_fv (
  input logic clk, rst_n, stop_req, fifo_full, eth_tvalid, eth_tlast
);
  logic eth_tready, stopped;
  tx_ingress_gate dut (
    .eth_clk(clk), .eth_rst_n(rst_n), .stop_req(stop_req), .fifo_full(fifo_full),
    .eth_tvalid(eth_tvalid), .eth_tlast(eth_tlast), .eth_tready(eth_tready), .stopped(stopped));

  logic f_past = 1'b0;
  always @(posedge clk) f_past <= 1'b1;

  // shadow frame state + stop history (from ports only)
  logic       in_frame, vld_q, rdy_q, last_q;
  logic [1:0] stop_hist;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_frame <= 1'b0; stop_hist <= 2'b11; vld_q <= 1'b0; rdy_q <= 1'b0; last_q <= 1'b0;
    end else begin
      if (eth_tvalid && eth_tready) in_frame <= !eth_tlast;
      stop_hist <= {stop_hist[0], stop_req};
      vld_q <= eth_tvalid; rdy_q <= eth_tready; last_q <= eth_tlast;
    end
  end

  always @(*) begin
    if (!f_past) assume (!rst_n); else assume (rst_n);
    // AXI4-S source: a presented beat stays until accepted (tlast stable too)
    if (f_past && vld_q && !rdy_q) assume (eth_tvalid && eth_tlast == last_q);
  end

  always @(*) if (f_past && rst_n) begin
    a_fig1_no_accept_full:  assert (!(eth_tready && fifo_full));
    a_fig2_frame_finishes:  assert (!(in_frame && !fifo_full) || eth_tready);
    a_fig3_no_new_frame:    assert (!(stop_req && (&stop_hist) && !in_frame) || !eth_tready);
  end
  always @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    a_fig4_stopped_between: assert (!stopped || ($past(!in_frame) && $past(stop_hist[1])));
  end

  always @(posedge clk) if (f_past && rst_n) begin
    c_stop_after_frame: cover (stopped && $past(in_frame, 2));
    c_accept_mid_stop:  cover (stop_hist == 2'b11 && in_frame && eth_tvalid && eth_tready);
  end
endmodule
