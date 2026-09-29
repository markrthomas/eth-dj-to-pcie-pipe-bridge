// ============================================================================
// tx_ingress_gate.sv — eth_clk domain.  Closes the Ethernet ingress at a frame
// boundary when the control FSM asks to drain (stop_req, from pclk).
//
// eth_tready = !fifo_full && !(stop && !in_frame): a frame already started is
// always allowed to finish; a new frame is not accepted while stopped.
// `stopped` is registered from the PREVIOUS in_frame value so it rises one
// eth_clk after the last accepted beat was written to the CDC FIFO; the FSM
// synchronises it into pclk (3 flops) so the FIFO's own empty flag has settled
// by the time it sees `stopped`.  Out of reset the gate is closed (stop=1).
// ============================================================================
module tx_ingress_gate (
  input  logic eth_clk,
  input  logic eth_rst_n,
  input  logic stop_req,      // async (pclk domain), synchronised here
  input  logic fifo_full,
  input  logic eth_tvalid,
  input  logic eth_tlast,
  output logic eth_tready,
  output logic stopped        // eth_clk domain; synchronise before use in pclk
);
  logic stop_s1, stop_s2, in_frame_q;

  always_ff @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) {stop_s2, stop_s1} <= 2'b11;
    else            {stop_s2, stop_s1} <= {stop_s1, stop_req};
  end

  assign eth_tready = !fifo_full && !(stop_s2 && !in_frame_q);

  always_ff @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) begin
      in_frame_q <= 1'b0;
      stopped    <= 1'b1;
    end else begin
      if (eth_tvalid && eth_tready) in_frame_q <= !eth_tlast;
      stopped <= stop_s2 && !in_frame_q;
    end
  end

endmodule : tx_ingress_gate
