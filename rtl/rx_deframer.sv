// ============================================================================
// rx_deframer.sv — pclk domain.  Unpacks a received flit's payload bytes into
// ETH_DATA_W-wide Ethernet beats {err, tlast, tkeep, tdata} for the Rx CDC FIFO.
// Full beats are emitted as they fill; the eof flit closes the frame with a
// partial low-aligned tkeep and tlast.
//
// Frame integrity (docs/OPEN_DECISIONS.md D9).  At the start of each flit:
//  * in a frame, and the flit follows a lost flit (flit_gap), has sof set, or has
//    a bad header  -> ABORT: emit the bytes accumulated so far as a tlast beat
//    with err=1 (eth_rx_tuser[0]); if nothing is accumulated a single 0x00 byte
//    is emitted so the tlast beat has a legal nonzero tkeep.  The flit is then
//    re-examined out-of-frame on the next cycle.
//  * bad header (valid clear, count 0 or > FLIT_PAYLOAD_B)  -> dropped, bad_flits++
//  * out of frame and sof clear (orphan continuation)       -> dropped, bad_flits++
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module rx_deframer
  import eth_dj_pipe7_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst_n,

  input  logic                                flit_valid,
  input  logic [FLIT_BYTES*8-1:0]             flit,
  input  logic                                flit_gap,
  output logic                                flit_taken,
  output logic                                data_done,    // a valid-header data flit was consumed (credit accounting)

  output logic [ETH_DATA_W+ETH_KEEP_W+1:0]    fifo_wdata,   // {err, last, keep, data}
  output logic                                fifo_winc,
  input  logic                                fifo_full,

  output logic                                idle,         // no frame in progress
  output logic [15:0]                         bad_flits,
  output logic [15:0]                         aborted_frames
);
  localparam int unsigned OFFW = $clog2(FLIT_PAYLOAD_B + 1);
  localparam int unsigned ACCW = $clog2(ETH_KEEP_W + 1);

  logic [OFFW-1:0]          rd_off_q;
  logic [ETH_DATA_W-1:0]    acc_q;
  logic [ACCW-1:0]          acc_n_q;
  logic                     in_frame_q;

  wire        hv    = flit[0];
  wire        hsof  = flit[1];
  wire        heof  = flit[2];
  wire [7:0]  plen8 = flit[15:8];
  wire        bad   = !hv || (plen8 == 8'd0) || (int'(plen8) > FLIT_PAYLOAD_B);
  wire        fstart = (rd_off_q == '0);
  wire        abort  = flit_valid && fstart && in_frame_q && (flit_gap || hsof || bad);
  wire        drop   = flit_valid && fstart && !in_frame_q && (bad || !hsof);

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

    if (abort) begin
      last = 1'b1;
      for (int k = 0; k < ETH_KEEP_W; k++)
        keep_n[k] = (k < int'(acc_n_q)) || (k == 0);
      fifo_winc = !fifo_full;
    end else if (drop) begin
      flit_taken = 1'b1;
    end else if (flit_valid) begin
      if (!(emit && fifo_full)) begin
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

  assign fifo_wdata = {abort, last, keep_n, abort ? acc_q : acc_n};
  assign idle       = !in_frame_q;
  assign data_done  = flit_taken && !bad;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_off_q       <= '0;
      acc_q          <= '0;
      acc_n_q        <= '0;
      in_frame_q     <= 1'b0;
      bad_flits      <= '0;
      aborted_frames <= '0;
    end else if (abort) begin
      if (!fifo_full) begin
        acc_q          <= '0;
        acc_n_q        <= '0;
        in_frame_q     <= 1'b0;
        aborted_frames <= (&aborted_frames) ? aborted_frames : aborted_frames + 16'd1;
      end
    end else if (drop) begin
      bad_flits <= (&bad_flits) ? bad_flits : bad_flits + 16'd1;
    end else if (advance) begin
      acc_q      <= emit ? '0 : acc_n;
      acc_n_q    <= emit ? '0 : ACCW'(cnt_n);
      rd_off_q   <= done ? '0 : OFFW'(off_n);
      in_frame_q <= !last;
    end
  end

endmodule : rx_deframer
