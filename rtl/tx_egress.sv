// ============================================================================
// tx_egress.sv — pclk domain.  Serialises a completed flit onto the PIPE Tx
// datapath, PIPE_BUS_W bits per beat (LSB byte first), FLIT_BEATS beats, with
// pipe_tx_start_block on the first beat.  A flit is only started while the link
// is in P0 (tx_en); once started it always completes.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module tx_egress
  import eth_dj_pipe7_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        tx_en,

  input  logic                        flit_valid,
  input  logic [FLIT_BYTES*8-1:0]     flit,
  output logic                        flit_taken,

  output logic [PIPE_BUS_W-1:0]       pipe_tx_data,
  output logic                        pipe_tx_data_valid,
  output logic                        pipe_tx_start_block
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic          busy_q;
  logic [CW-1:0] cnt_q;

  wire start = !busy_q && flit_valid && tx_en;

  assign flit_taken = busy_q && (int'(cnt_q) == FLIT_BEATS - 1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q              <= 1'b0;
      cnt_q               <= '0;
      pipe_tx_data        <= '0;
      pipe_tx_data_valid  <= 1'b0;
      pipe_tx_start_block <= 1'b0;
    end else if (start) begin
      busy_q              <= 1'b1;
      cnt_q               <= CW'(1);
      pipe_tx_data        <= flit[PIPE_BUS_W-1:0];
      pipe_tx_data_valid  <= 1'b1;
      pipe_tx_start_block <= 1'b1;
    end else if (busy_q) begin
      pipe_tx_data        <= flit[int'(cnt_q)*PIPE_BUS_W +: PIPE_BUS_W];
      pipe_tx_data_valid  <= 1'b1;
      pipe_tx_start_block <= 1'b0;
      if (flit_taken) busy_q <= 1'b0;
      cnt_q               <= cnt_q + CW'(1);
    end else begin
      pipe_tx_data_valid  <= 1'b0;
      pipe_tx_start_block <= 1'b0;
    end
  end

endmodule : tx_egress
