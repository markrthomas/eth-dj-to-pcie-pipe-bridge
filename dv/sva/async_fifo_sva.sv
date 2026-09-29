// ============================================================================
// dv/sva/async_fifo_sva.sv — bind-based CDC FIFO safety checks for every
// async_fifo instance (Tx and Rx CDC).  Property IDs match ASSERTIONS.md.
// The cross-domain checks (CD1/CD2) compare the true write and read pointers,
// which only a simulator can see at once; formal/async_fifo.sby proves the same
// properties on a small instance (formal/async_fifo_fv.sv).
// ============================================================================
module async_fifo_sva #(
  parameter int unsigned DEPTH = 32,
  parameter int unsigned AW    = $clog2(DEPTH)
) (
  input logic        wclk,
  input logic        wrst_n,
  input logic        winc,
  input logic        wfull,
  input logic [AW:0] wbin,
  input logic [AW:0] wgray,
  input logic        rclk,
  input logic        rrst_n,
  input logic        rinc,
  input logic        rempty,
  input logic [AW:0] rbin,
  input logic [AW:0] rgray
);
  wire [AW:0] fill = wbin - rbin;   // true occupancy (mod 2^(AW+1))

  // CD1: occupancy never exceeds DEPTH (no overwrite of unread data)
  a_cd1_occupancy_w: assert property (@(posedge wclk) disable iff (!wrst_n || !rrst_n)
    fill <= (AW+1)'(DEPTH));
  a_cd1_occupancy_r: assert property (@(posedge rclk) disable iff (!wrst_n || !rrst_n)
    fill <= (AW+1)'(DEPTH));
  // CD2: a read pops only a written entry; a write never lands on unread data
  a_cd2_no_underrun: assert property (@(posedge rclk) disable iff (!wrst_n || !rrst_n)
    rinc && !rempty |-> fill != '0);
  a_cd2_no_overrun: assert property (@(posedge wclk) disable iff (!wrst_n || !rrst_n)
    winc && !wfull |-> fill != (AW+1)'(DEPTH));
  // CD3: Gray pointers change by at most one bit per clock (safe to synchronise)
  a_cd3_wgray_1bit: assert property (@(posedge wclk) disable iff (!wrst_n)
    $countones(wgray ^ $past(wgray)) <= 1);
  a_cd3_rgray_1bit: assert property (@(posedge rclk) disable iff (!rrst_n)
    $countones(rgray ^ $past(rgray)) <= 1);

  c_full:  cover property (@(posedge wclk) disable iff (!wrst_n) wfull);
  c_empty_after_data: cover property (@(posedge rclk) disable iff (!rrst_n) rinc && !rempty);
endmodule : async_fifo_sva

bind async_fifo async_fifo_sva #(.DEPTH(DEPTH)) u_async_fifo_sva (
  .wclk (wclk), .wrst_n (wrst_n), .winc (winc), .wfull (wfull), .wbin (wbin), .wgray (wgray),
  .rclk (rclk), .rrst_n (rrst_n), .rinc (rinc), .rempty (rempty), .rbin (rbin), .rgray (rgray)
);
