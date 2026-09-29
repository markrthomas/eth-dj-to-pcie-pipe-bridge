// ============================================================================
// eth_egress.sv — eth_clk domain.  Presents the Rx CDC FIFO head (FWFT) as the
// eth_rx_* AXI4-Stream master.  FIFO word = {err, last, keep, data};
// eth_rx_tuser[0] = err on the tlast beat of an aborted frame (D9), other bits 0.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module eth_egress
  import eth_dj_pipe7_pkg::*;
(
  input  logic [ETH_DATA_W+ETH_KEEP_W+1:0] fifo_rdata,
  input  logic                            fifo_empty,
  output logic                            fifo_rinc,

  output logic                            eth_rx_tvalid,
  input  logic                            eth_rx_tready,
  output logic [ETH_DATA_W-1:0]           eth_rx_tdata,
  output logic [ETH_KEEP_W-1:0]           eth_rx_tkeep,
  output logic                            eth_rx_tlast,
  output logic [ETH_USER_W-1:0]           eth_rx_tuser
);
  assign eth_rx_tvalid = !fifo_empty;
  assign eth_rx_tdata  = fifo_rdata[ETH_DATA_W-1:0];
  assign eth_rx_tkeep  = fifo_rdata[ETH_DATA_W +: ETH_KEEP_W];
  assign eth_rx_tlast  = fifo_rdata[ETH_DATA_W+ETH_KEEP_W];
  assign eth_rx_tuser  = {{(ETH_USER_W-1){1'b0}}, fifo_rdata[ETH_DATA_W+ETH_KEEP_W+1]};
  assign fifo_rinc     = eth_rx_tvalid && eth_rx_tready;
endmodule : eth_egress
