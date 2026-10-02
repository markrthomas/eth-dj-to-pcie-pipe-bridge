// ============================================================================
// dv/iverilog/tb_edge.sv — edge cases found by the 2026-10-02 swarm review (docs/OPEN_DECISIONS.md D19).
//
//   1. Null tlast beats (tkeep = 0, tlast = 1): a frame ended by a null beat, including frames
//      that exactly fill a flit (240, 480, 720, 960 B) or a beat (32, 64 B), must arrive intact,
//      not aborted, with no bad flits; a lone null tlast beat (empty frame) produces no flit and
//      no frame.
//   2. CTRL range check: a write with a reserved rate (> Gen6) or width (3) is ignored as a whole
//      and flagged in ERR[3]; the pins / CTRL / STATUS do not change.
//   3. P0s request: flagged in ERR[2] once per CTRL write, W1C really clears it while P0s is
//      still requested, the link stays in P0.
//   4. Rx diagnostic counters saturate at 16'hFFFF instead of wrapping (counters deposited just
//      below the limit, then an Rx overload burst as in tb_rxovf).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_edge;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"
  `include "loop_harness.svh"

  localparam int NF = 22;
  localparam logic [31:0] CTRL_RST = 32'h14;   // P0, Gen6 (5 << 2), width 0
  int flen [0:NF-1];
  int fnul [0:NF-1];       // 1: end the frame with a null tlast beat
  int nexp = 0, checked = 0, errors = 0, bad;
  int exp_flits = 0;
  logic phase1 = 1'b1;
  logic [31:0] d;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("[%0t] FAIL: %s", $time, msg); errors++; end
  endtask

  // ---- scoreboard (phase 1): frames in order, byte-exact, never aborted -----------------------
  always @(posedge eth_clk) begin
    if (phase1 && sink.frame_done) begin
      if (checked >= nexp) begin
        $display("FAIL: unexpected extra frame (len %0d)", sink.done_len); errors++;
      end else if (sink.done_err) begin
        $display("FAIL: frame %0d aborted (len %0d, expected %0d)", checked, sink.done_len, flen[checked]); errors++;
        checked++;
      end else begin
        if (sink.done_len != flen[checked]) begin
          $display("FAIL: frame %0d length %0d, expected %0d", checked, sink.done_len, flen[checked]);
          errors++;
        end else begin
          bad = -1;
          for (int i = 0; i < sink.done_len; i++)
            if (bad < 0 && sink.fbuf[i] !== pat(checked, i)) bad = i;
          if (bad >= 0) begin
            $display("FAIL: frame %0d byte %0d = %02x, expected %02x", checked, bad, sink.fbuf[bad], pat(checked, bad));
            errors++;
          end
        end
        checked++;
      end
    end
  end

  int dropped_a, aborted_a, badfl_a;
  initial begin
    flen[0]=1;    flen[1]=32;   flen[2]=64;   flen[3]=100;  flen[4]=239;  flen[5]=240;  flen[6]=241;
    flen[7]=480;  flen[8]=481;  flen[9]=719;  flen[10]=720; flen[11]=721; flen[12]=960; flen[13]=961;
    flen[14]=1440; flen[15]=1500; flen[16]=480; flen[17]=481; flen[18]=240; flen[19]=720; flen[20]=7; flen[21]=64;
    for (int i = 0; i < NF; i++) fnul[i] = (i == 16 || i == 17) ? 0 : 1;   // 16/17: plain control frames
    nexp = NF;
    for (int i = 0; i < NF; i++) exp_flits += (flen[i] + FLIT_PAYLOAD_B - 1) / FLIT_PAYLOAD_B;

    do_reset();
    wait (dut.ctrl_state == ST_ACTIVE);
    repeat (20) @(posedge eth_clk);

    // ---- 1. null tlast beats ------------------------------------------------------------------
    for (int i = 0; i < NF; i++) begin
      mac.gap_pct    = (i < NF/2) ? 0 : 30;
      sink.ready_pct = (i < NF/2) ? 100 : 80;
      mac.null_last  = fnul[i];
      mac.send_frame(i, flen[i]);
      mac.null_last  = 0;
      if (i == 3 || i == 9 || i == 15) begin
        mac.send_null_beat();            // empty frame: no flit, no frame
        mac.send_null_beat();
      end
    end
    wait (checked == nexp);
    repeat (3000) @(posedge pclk);
    chk(checked == nexp, "1: all frames received");
    chk(phy.flits == exp_flits, "1: flit count (a null tlast beat adds no flit, an empty frame none)");
    chk(phy.frames == NF, "1: PHY saw exactly the non-empty frames");
    chk(sink.errors == 0 && sink.err_frames == 0, "1: sink clean, no frame flagged");
    chk(phy.errors == 0 && phyc.errors == 0, "1: PHY models clean");
    chk(dut.rx_dropped_flits == 0 && dut.rx_lock_errors == 0 && dut.rx_bad_flits == 0 &&
        dut.rx_aborted_frames == 0, "1: no Rx drop / bad flit / abort (no empty flit was sent)");

    // ---- 2. CTRL range check ---------------------------------------------------------------------
    csr_rd(CSR_CTRL, d); chk(d == CTRL_RST, "2: CTRL resets to P0 / Gen6 / width 0");
    csr_wr(CSR_CTRL, {25'b0, 2'd0, 3'd6, 2'd0}); repeat (50) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h8, "2: rate 6 write flagged in ERR[3]");
    csr_rd(CSR_CTRL, d); chk(d == CTRL_RST, "2: rate 6 write ignored (CTRL unchanged)");
    chk(pipe_rate == RATE_GEN6 && dut.ctrl_state == ST_ACTIVE, "2: rate pin unchanged, link still active");
    csr_wr(CSR_ERR, 32'h8); csr_rd(CSR_ERR, d); chk(d == 32'h0, "2: ERR[3] W1C clears");
    csr_wr(CSR_CTRL, {25'b0, 2'd0, 3'd7, 2'd2}); repeat (50) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h8, "2: rate 7 + P1 write ignored as a whole, flagged");
    csr_rd(CSR_CTRL, d); chk(d == CTRL_RST, "2: a bad write changes none of its fields (P1 not taken)");
    chk(pipe_powerdown == PWR_P0 && dut.ctrl_state == ST_ACTIVE, "2: no power-down from a rejected write");
    csr_wr(CSR_ERR, 32'h8);
    csr_wr(CSR_CTRL, {25'b0, 2'd3, 3'd5, 2'd0}); repeat (50) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h8, "2: width 3 write flagged");
    csr_rd(CSR_CTRL, d); chk(d == CTRL_RST, "2: width 3 write ignored");
    csr_wr(CSR_ERR, 32'h8);
    csr_wr(CSR_CTRL, CTRL_RST); repeat (50) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h0, "2: a legal write raises no error");

    // ---- 3. P0s: flagged once per write, W1C works while it stays requested --------------------------
    csr_wr(CSR_CTRL, {25'b0, 2'd0, 3'd5, PWR_P0S}); repeat (20) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h4, "3: P0s write flagged in ERR[2]");
    csr_wr(CSR_ERR, 32'h4); repeat (50) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h0, "3: ERR[2] stays cleared while P0s is still requested");
    chk(pipe_powerdown == PWR_P0 && dut.ctrl_state == ST_ACTIVE, "3: link stays in P0");
    csr_wr(CSR_CTRL, {25'b0, 2'd0, 3'd5, PWR_P0S}); repeat (20) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h4, "3: a second P0s write is flagged again");
    csr_wr(CSR_ERR, 32'h4);
    csr_wr(CSR_CTRL, CTRL_RST); repeat (20) @(posedge pclk);
    csr_rd(CSR_ERR, d);  chk(d == 32'h0, "3: back to P0, no error");

    // ---- 4. saturating Rx counters ---------------------------------------------------------------
    phase1 = 1'b0;
    dut.u_rx_ingress.dropped_flits  = 16'hFFFC;
    dut.u_rx_deframer.aborted_frames = 16'hFFFC;
    dut.u_rx_deframer.bad_flits      = 16'hFFFC;
    mac.gap_pct = 0; sink.ready_pct = 4;
    for (int i = 0; i < 80; i++) mac.send_frame(1000 + i, $urandom_range(1500, 60));
    sink.ready_pct = 100;
    repeat (20000) @(posedge pclk);
    csr_rd(CSR_RXCNT0, d); chk(d[15:0] == 16'hFFFF, "4: dropped_flits saturates at FFFF (did not wrap)");
    csr_rd(CSR_RXCNT1, d); chk(d[31:16] == 16'hFFFF, "4: aborted_frames saturates at FFFF");
    chk(d[15:0] == 16'hFFFF, "4: bad_flits saturates at FFFF");

    if (errors == 0)
      $display("EDGE PASS: %0d frames (null tlast beats incl. flit-/beat-aligned), CTRL range check, P0s flag, saturating counters", NF);
    else
      $display("EDGE FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #40000000;
    $display("EDGE FAIL: global timeout (%0d/%0d frames)", checked, nexp);
    $finish;
  end
endmodule
