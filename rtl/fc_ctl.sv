// ============================================================================
// fc_ctl.sv — pclk domain.  Link flow-control controller (docs/OPEN_DECISIONS.md D16).
// Elaborates to constants when FLOW_CTRL = 0 (credit_ok = 1, cr_req = 0).
//
// Receive side.  Credit limit advertised to the remote:
//     cl_now = deframed_data_flits + lost_flits + floor(rx_fifo_free_beats / 9)
// i.e. every data flit the remote has sent but we have not yet fully deframed or written
// off must fit, at a worst case of CREDIT_BEATS_PER_FLIT beats each, in the Rx CDC FIFO's
// current free space -> the deframer can never overflow and the (single-slot) Rx ingress
// never has to drop a credited flit.  `lost_flits` (sequence gaps and drops, from
// rx_ingress) gives back the credit of flits that will never be deframed, so a lost flit
// cannot leak credit.  Free space comes from the FIFO's synchronised read pointer, so it is
// conservative (never over-reports).
//
// Transmit side.  A data flit may start only while  cl_remote - data_flits_sent > 0
// (modular).  A credit-only flit is requested whenever the advertised limit has moved
// beyond what any flit already carried (cl_now - cl_last_sent > 0).  Idle links send nothing.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module fc_ctl
  import eth_dj_pipe7_pkg::*;
#(
  parameter int unsigned WFW = $clog2(FIFO_DEPTH) + 1
) (
  input  logic           clk,
  input  logic           rst_n,

  // receive-side accounting
  input  logic           dfr_data_done,    // a data flit was deframed / dropped (rx_deframer)
  input  logic [15:0]    lost_cnt,         // cumulative lost data flits (rx_ingress)
  input  logic [WFW-1:0] rx_wfree,         // Rx CDC FIFO free beats (conservative)
  input  logic [15:0]    cl_remote,        // remote's credit limit (rx_ingress)

  // to / from tx_egress
  input  logic           st_any,           // a flit started this cycle
  input  logic           st_data,          // ... and it was a data flit
  output logic           credit_ok,        // a data flit may start
  output logic           cr_req,           // a credit-only flit is wanted
  output logic [15:0]    seq_now,          // seq field: data flits sent so far
  output logic [15:0]    cl_now            // cl field: credit limit to advertise
);
  logic [15:0] d_cnt_q, s_cnt_q, cl_last_q;

  wire [15:0] free_flits = 16'(int'(rx_wfree) / int'(CREDIT_BEATS_PER_FLIT));
  wire [15:0] cl_adv     = d_cnt_q + lost_cnt + free_flits;
  wire [15:0] left       = cl_remote - s_cnt_q;
  wire [15:0] fresh      = cl_adv - cl_last_q;

  assign seq_now   = s_cnt_q;
  assign cl_now    = cl_adv;
  assign credit_ok = FLOW_CTRL ? (left != 16'd0 && !left[15]) : 1'b1;
  assign cr_req    = FLOW_CTRL ? (fresh != 16'd0 && !fresh[15]) : 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_cnt_q   <= '0;
      s_cnt_q   <= '0;
      cl_last_q <= '0;
    end else begin
      if (dfr_data_done) d_cnt_q <= d_cnt_q + 16'd1;
      if (st_data)       s_cnt_q <= s_cnt_q + 16'd1;
      if (st_any)        cl_last_q <= cl_adv;
    end
  end
endmodule : fc_ctl
