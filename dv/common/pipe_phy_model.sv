// ============================================================================
// pipe_phy_model.sv — DV-only PIPE PHY sink BFM + Gen6 flit monitor (Tx side).
// Checks on every flit: 32 contiguous valid beats, start_block only on beat 0,
// header valid bit, sof/eof sequencing, payload length <= 240, and zeroed
// padding/DLP/FEC bytes (bridge flit format, eth_dj_pipe7_pkg).  Reassembles
// frames into fbuf[]; frame_done pulses for one pclk with done_len valid.
//
// With FLOW_CTRL (docs/OPEN_DECISIONS.md D16) bytes FLIT_FC_OFF..+3 of every flit carry
// seq/cl and are exempt from the zero check; a flit with count 0, sof = eof = 0 is a
// legal credit-only flit (counted in cr_flits, not in flits/frames); the seq field must
// equal the number of data flits seen before it (fc_seq_err otherwise).  last_cl / last_seq
// expose the most recent fields.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module pipe_phy_model
  import eth_dj_pipe7_pkg::*;
#(
  parameter int unsigned MAX_FRAME = 16384
) (
  input  logic                   pclk,
  input  logic                   pipe_rst_n,
  input  logic [PIPE_BUS_W-1:0]  pipe_tx_data,
  input  logic                   pipe_tx_data_valid,
  input  logic                   pipe_tx_start_block
);
  logic [7:0] fbuf [0:MAX_FRAME-1];
  logic [FLIT_BYTES*8-1:0] fl;

  int          beat      = 0;      // beats received in the current flit
  int          fpos      = 0;      // bytes of the current frame received
  logic        in_frame  = 1'b0;
  int unsigned flits     = 0;
  int unsigned frames    = 0;
  int unsigned errors    = 0;
  int unsigned cr_flits  = 0;      // credit-only flits (FLOW_CTRL)
  int unsigned fc_sent   = 0;      // data flits since the last DUT reset (expected seq field)
  int unsigned fc_seq_err = 0;     // seq field != data flits sent before it
  logic [15:0] last_seq = '0, last_cl = '0;
  logic        frame_done = 1'b0;
  int          done_len   = 0;

  task automatic err(input string msg);
    begin
      errors++;
      $display("[%0t] PHY-MODEL ERROR: %s", $time, msg);
    end
  endtask

  int plen;
  logic hv, hsof, heof, padbad, crflit;

  always @(posedge pclk or negedge pipe_rst_n) begin
    if (!pipe_rst_n) begin
      beat <= 0; fpos <= 0; in_frame <= 1'b0; frame_done <= 1'b0; fc_sent = 0;
    end else begin
      frame_done <= 1'b0;
      if (pipe_tx_start_block && !pipe_tx_data_valid) err("start_block without data_valid");
      if (pipe_tx_data_valid) begin
        if (pipe_tx_start_block && beat != 0) err("start_block mid-flit");
        if (!pipe_tx_start_block && beat == 0) err("flit beat 0 without start_block");
        fl[(beat % FLIT_BEATS)*PIPE_BUS_W +: PIPE_BUS_W] = pipe_tx_data;
        if (beat == FLIT_BEATS - 1) begin
          // ---- complete flit: check + reassemble -----------------------------
          beat  <= 0;
          hv   = fl[0];
          hsof = fl[1];
          heof = fl[2];
          plen = int'(fl[15:8]);
          if (!hv) err("header valid bit clear");
          if (fl[7:3] != 5'b0) err("header reserved bits nonzero");
          if (plen > FLIT_PAYLOAD_B) err("payload length > 240");
          crflit = FLOW_CTRL && (plen == 0) && !hsof && !heof;
          if (plen == 0 && !crflit) err("empty flit emitted");
          if (!crflit && hsof !== !in_frame) err("sof/frame state mismatch");
          padbad = 1'b0;
          for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
            if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl[8*b +: 8] !== 8'h00) padbad = 1'b1;
          if (padbad) err("nonzero padding/DLP/FEC byte");
          if (FLOW_CTRL) begin
            last_seq = fl[8*FLIT_FC_OFF +: 16];
            last_cl  = fl[8*(FLIT_FC_OFF+2) +: 16];
            if (last_seq !== 16'(fc_sent)) begin fc_seq_err++; err("flow-control seq field != data flits sent before"); end
          end
          if (crflit) cr_flits++; else begin flits++; fc_sent++; end
          for (int b = 0; b < plen; b++)
            if (fpos + b < MAX_FRAME) fbuf[fpos + b] = fl[8*(FLIT_HDR_B + b) +: 8];
          fpos = fpos + plen;
          if (crflit) begin
            // credit-only: no frame state change
          end else if (heof) begin
            frames++;
            done_len   <= fpos;
            frame_done <= 1'b1;
            fpos       = 0;
            in_frame  <= 1'b0;
          end else begin
            in_frame  <= 1'b1;
          end
        end else begin
          beat <= beat + 1;
        end
      end else if (beat != 0) begin
        err("data_valid dropped mid-flit");
        beat <= 0;
      end
    end
  end
endmodule
