// ============================================================================
// eth_sink_model.sv — DV-only 802.3dj MAC sink BFM (AXI4-Stream slave) + checker.
// ready_pct (0..100) randomly throttles tready.  Checks tkeep legality (full
// keep on non-last beats; contiguous low-aligned nonzero keep on the last beat),
// reassembles frames into fbuf[]; frame_done pulses one eth_clk with done_len.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module eth_sink_model
  import eth_dj_pipe7_pkg::*;
#(
  parameter int unsigned MAX_FRAME = 16384
) (
  input  logic                     eth_clk,
  input  logic                     eth_rst_n,
  input  logic                     eth_rx_tvalid,
  output logic                     eth_rx_tready,
  input  logic [ETH_DATA_W-1:0]    eth_rx_tdata,
  input  logic [ETH_KEEP_W-1:0]    eth_rx_tkeep,
  input  logic                     eth_rx_tlast
);
  logic [7:0] fbuf [0:MAX_FRAME-1];
  int          ready_pct  = 100;
  int          fpos       = 0;
  int unsigned frames     = 0;
  int unsigned errors     = 0;
  logic        frame_done = 1'b0;
  int          done_len   = 0;
  int          nb;
  logic        kbad;

  // throttle: drive tready after the clock edge from a random draw
  always @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) eth_rx_tready <= 1'b0;
    else            eth_rx_tready <= ($urandom_range(99, 0) < ready_pct);
  end

  always @(posedge eth_clk or negedge eth_rst_n) begin
    if (!eth_rst_n) begin
      fpos <= 0; frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      if (eth_rx_tvalid && eth_rx_tready) begin
        nb = 0;
        kbad = 1'b0;
        for (int i = 0; i < ETH_KEEP_W; i++) begin
          if (eth_rx_tkeep[i]) begin
            nb++;
            if (i > 0 && !eth_rx_tkeep[i-1]) kbad = 1'b1;   // non-contiguous
          end
        end
        if (nb == 0) kbad = 1'b1;
        if (!eth_rx_tlast && nb != ETH_KEEP_W) kbad = 1'b1;  // partial beat mid-frame
        if (kbad) begin errors++; $display("[%0t] SINK ERROR: bad tkeep %h (last=%b)", $time, eth_rx_tkeep, eth_rx_tlast); end
        for (int i = 0; i < ETH_KEEP_W; i++)
          if (eth_rx_tkeep[i] && fpos + i < MAX_FRAME) fbuf[fpos + i] = eth_rx_tdata[8*i +: 8];
        if (eth_rx_tlast) begin
          frames++;
          done_len   <= fpos + nb;
          frame_done <= 1'b1;
          fpos       = 0;
        end else begin
          fpos = fpos + nb;
        end
      end
    end
  end
endmodule
