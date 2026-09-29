// ============================================================================
// formal/async_fifo_fv.sv — CDC FIFO safety (ASSERTIONS.md F-CD1/F-CD2/F-CD4) on
// a small instance (W=4, DEPTH=4), black-box: only the FIFO ports are observed
// (Yosys does not resolve hierarchical references, so shadow counters rebuild
// the true occupancy from the handshakes).
// wclk and rclk are free inputs (sby `multiclock on`): the solver chooses every
// clock edge, so all clock ratios and phases are covered.  Both resets are
// asserted in the first step only.
//   F-CD1  occupancy never exceeds DEPTH        (wfull is never late)
//   F-CD2  !rempty implies data present         (rempty is never early)
//   F-CD4  data integrity: every write number f_idx carries f_val (anyconst);
//          the read with the same number must return f_val, so a lost,
//          overwritten, duplicated or phantom entry is caught.
// ============================================================================
module async_fifo_fv (
  (* gclk *) input logic gclk,
  input logic       wclk, rclk, rst_n,
  input logic       winc, rinc,
  input logic [3:0] wdata
);
  localparam int DEPTH = 4, W = 4;
  logic         wfull, rempty;
  logic [W-1:0] rdata;

  async_fifo #(.W(W), .DEPTH(DEPTH)) dut (
    .wclk(wclk), .wrst_n(rst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
    .rclk(rclk), .rrst_n(rst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty));

  (* anyconst *) logic [3:0]   f_idx;
  (* anyconst *) logic [W-1:0] f_val;

  logic f_past = 1'b0;
  always @(posedge gclk) f_past <= 1'b1;

  // shadow write / read counts (number of accepted beats)
  logic [3:0] wcnt, rcnt;   // mod 16: an overflow past DEPTH=4 shows up long before a wrap
  always @(posedge wclk or negedge rst_n)
    if (!rst_n) wcnt <= '0; else if (winc && !wfull) wcnt <= wcnt + 4'd1;
  always @(posedge rclk or negedge rst_n)
    if (!rst_n) rcnt <= '0; else if (rinc && !rempty) rcnt <= rcnt + 4'd1;
  wire [3:0] fill = wcnt - rcnt;

  always @(*) begin
    if (!f_past) assume (!rst_n);
    else         assume (rst_n);
    if (winc && wcnt == f_idx) assume (wdata == f_val);
  end

  always @(*) if (f_past && rst_n) begin
    a_fcd1_occupancy:  assert (fill <= DEPTH);
    a_fcd2_no_underrun: assert (rempty || fill != 0);
    a_fcd4_integrity:  assert (!(!rempty && rcnt == f_idx) || rdata == f_val);
  end

  always @(*) if (f_past && rst_n) begin
    c_full:         cover (wfull);
    c_wrapped_twice: cover (rempty && wcnt == 4'd9);   // > 2*DEPTH beats through
  end
endmodule
