// ============================================================================
// rx_deframer.sv — pclk domain.  Unpacks a received flit's payload bytes into
// ETH_DATA_W-wide Ethernet beats {tlast, tkeep, tdata} for the Rx CDC FIFO.
// Full beats are emitted as they fill; the eof flit closes the frame with a
// partial low-aligned tkeep and tlast.  Flits with the valid bit clear, a zero
// count, or a count > FLIT_PAYLOAD_B are dropped (bad_flits).  sof is not
// checked here (SVA, M5).
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module rx_deframer
  import eth_dj_pipe7_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst_n,

  input  logic                                flit_valid,
  input  logic [FLIT_BYTES*8-1:0]             flit,
  output logic                                flit_taken,

  output logic [ETH_DATA_W+ETH_KEEP_W:0]      fifo_wdata,
  output logic                                fifo_winc,
  input  logic                                fifo_full,

  output logic [15:0]                         bad_flits
);
  localparam int unsigned OFFW = $clog2(FLIT_PAYLOAD_B + 1);
  localparam int unsigned ACCW = $clog2(ETH_KEEP_W + 1);

  logic [OFFW-1:0]          rd_off_q;
  logic [ETH_DATA_W-1:0]    acc_q;
  logic [ACCW-1:0]          acc_n_q;

  wire        hv   = flit[0];
  wire        heof = flit[2];
  wire [7:0]  plen8 = flit[15:8];
  wire        bad  = !hv || (plen8 == 8'd0) || (int'(plen8) > FLIT_PAYLOAD_B);

  logic [ETH_DATA_W-1:0] acc_n;
  logic [ETH_KEEP_W-1:0] keep_n;
  int                    plen, take, room, left, cnt_n, off_n;
  logic                  done, emit, last, advance;

  always_comb begin
    acc_n      = acc_q;
    keep_n     = '0;
    plen       = int'(plen8);
    left       = plen - int'(rd_off_q);
    room       = ETH_KEEP_W - int'(acc_n_q);
    take       = (left < room) ? left : room;
    cnt_n      = int'(acc_n_q) + take;
    off_n      = int'(rd_off_q) + take;
    done       = (off_n == plen);
    last       = done && heof;
    emit       = (cnt_n == ETH_KEEP_W) || last;
    advance    = 1'b0;
    flit_taken = 1'b0;
    fifo_winc  = 1'b0;

    if (flit_valid) begin
      if (bad) begin
        flit_taken = 1'b1;
      end else if (!(emit && fifo_full)) begin
        advance = 1'b1;
        for (int j = 0; j < ETH_KEEP_W; j++)
          if (j < take)
            acc_n[8*(int'(acc_n_q) + j) +: 8] = flit[8*(FLIT_HDR_B + int'(rd_off_q) + j) +: 8];
        for (int k = 0; k < ETH_KEEP_W; k++)
          keep_n[k] = (k < cnt_n);
        fifo_winc  = emit;
        flit_taken = done;
      end
    end
  end

  assign fifo_wdata = {last, keep_n, acc_n};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_off_q  <= '0;
      acc_q     <= '0;
      acc_n_q   <= '0;
      bad_flits <= '0;
    end else if (flit_valid) begin
      if (bad) begin
        bad_flits <= bad_flits + 16'd1;
      end else if (advance) begin
        acc_q    <= emit ? '0 : acc_n;
        acc_n_q  <= emit ? '0 : ACCW'(cnt_n);
        rd_off_q <= done ? '0 : OFFW'(off_n);
      end
    end
  end

endmodule : rx_deframer
