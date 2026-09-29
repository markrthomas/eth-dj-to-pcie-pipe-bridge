// ============================================================================
// async_fifo.sv — dual-clock FIFO, Gray-coded pointers, first-word-fall-through.
// DEPTH must be a power of two.  Each side has its own active-low reset.
// ============================================================================
module async_fifo #(
  parameter int unsigned W     = 8,
  parameter int unsigned DEPTH = 32
) (
  input  logic         wclk,
  input  logic         wrst_n,
  input  logic         winc,
  input  logic [W-1:0] wdata,
  output logic         wfull,

  input  logic         rclk,
  input  logic         rrst_n,
  input  logic         rinc,
  output logic [W-1:0] rdata,
  output logic         rempty
);
  localparam int unsigned AW = $clog2(DEPTH);

  logic [W-1:0] mem [0:DEPTH-1];

  // ---- write side ----------------------------------------------------------
  logic [AW:0] wbin, wgray, wbin_n, wgray_n;
  logic [AW:0] rgray_w1, rgray_w2;          // rptr synchronised into wclk

  assign wbin_n  = wbin + (AW+1)'(winc && !wfull);
  assign wgray_n = (wbin_n >> 1) ^ wbin_n;

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_n;
      wgray <= wgray_n;
      // full: next write Gray pointer equals read pointer with top 2 bits inverted
      wfull <= (wgray_n == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    end
  end

  always_ff @(posedge wclk) begin
    if (winc && !wfull) mem[wbin[AW-1:0]] <= wdata;
  end

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) {rgray_w2, rgray_w1} <= '0;
    else         {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
  end

  // ---- read side -----------------------------------------------------------
  logic [AW:0] rbin, rgray, rbin_n, rgray_n;
  logic [AW:0] wgray_r1, wgray_r2;          // wptr synchronised into rclk

  assign rbin_n  = rbin + (AW+1)'(rinc && !rempty);
  assign rgray_n = (rbin_n >> 1) ^ rbin_n;

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_n;
      rgray  <= rgray_n;
      rempty <= (rgray_n == wgray_r2);
    end
  end

  assign rdata = mem[rbin[AW-1:0]];

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) {wgray_r2, wgray_r1} <= '0;
    else         {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
  end

endmodule : async_fifo
