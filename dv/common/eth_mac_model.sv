// ============================================================================
// eth_mac_model.sv — DV-only 802.3dj MAC/PCS source BFM (AXI4-Stream master).
// send_frame(id, len) streams a frame of pattern bytes (eth_dj_pat.svh),
// honouring tready.  gap_pct (0..100) randomly inserts idle cycles between beats.
// Drives with nonblocking assignments after posedge eth_clk (no races).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module eth_mac_model
  import eth_dj_pipe7_pkg::*;
(
  input  logic                     eth_clk,
  output logic                     eth_tvalid,
  input  logic                     eth_tready,
  output logic [ETH_DATA_W-1:0]    eth_tdata,
  output logic [ETH_DATA_W/8-1:0]  eth_tkeep,
  output logic                     eth_tlast,
  output logic [ETH_USER_W-1:0]    eth_tuser
);
  `include "eth_dj_pat.svh"

  int gap_pct = 0;
  int beats_sent = 0;

  initial begin
    eth_tvalid = 1'b0;
    eth_tdata  = '0;
    eth_tkeep  = '0;
    eth_tlast  = 1'b0;
    eth_tuser  = '0;
  end

  task automatic send_frame(input int id, input int len);
    int off, n;
    logic [ETH_DATA_W-1:0]   d;
    logic [ETH_DATA_W/8-1:0] k;
    begin
      off = 0;
      while (off < len) begin
        while (gap_pct > 0 && $urandom_range(99, 0) < gap_pct) begin
          eth_tvalid <= 1'b0;
          @(posedge eth_clk);
        end
        n = len - off;
        if (n > ETH_KEEP_W) n = ETH_KEEP_W;
        d = '0;
        k = '0;
        for (int i = 0; i < n; i++) begin
          d[8*i +: 8] = pat(id, off + i);
          k[i]        = 1'b1;
        end
        eth_tvalid <= 1'b1;
        eth_tdata  <= d;
        eth_tkeep  <= k;
        eth_tlast  <= (off + n == len);
        @(posedge eth_clk);
        while (!eth_tready) @(posedge eth_clk);
        beats_sent++;
        off += n;
      end
      eth_tvalid <= 1'b0;
      eth_tlast  <= 1'b0;
    end
  endtask
endmodule
