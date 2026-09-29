// ============================================================================
// dv/iverilog/tb_rxovf.sv — Rx overload policy test (docs/OPEN_DECISIONS.md D9).
//
// PIPE Rx has no backpressure.  Phase A streams frames back-to-back through the
// loopback while the Ethernet sink accepts only ~4% of cycles, so the Rx CDC
// FIFO fills and rx_ingress must drop flits.  Required behaviour:
//   * no silent corruption: every received frame is either flagged with
//     eth_rx_tuser[0] (aborted) or is byte-exact equal to a sent frame, and the
//     good frames appear in send order (frames may be missing entirely);
//   * drops really happened (dropped_flits > 0) and the aborted-frame counter
//     equals the number of err-flagged frames the sink saw;
// Phase B restores a full-rate sink, lets the Rx side drain, then sends more
// frames, which must all arrive intact and in order (recovery).
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_rxovf;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"
  `include "loop_harness.svh"

  localparam int NA = 80;          // overload phase
  localparam int NB = 30;          // recovery phase
  localparam int N  = NA + NB;

  int exp_len [0:N-1];
  int errors = 0, good = 0, errf = 0, next_id = 0, last_good = -1, bad, match;
  int b_first = -1;
  logic [31:0] d;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("[%0t] FAIL: %s", $time, msg); errors++; end
  endtask

  // ---- scoreboard: good frames must match a sent frame, in order --------------
  always @(posedge eth_clk) begin
    if (sink.frame_done) begin
      if (sink.done_err) begin
        errf++;
      end else begin
        match = -1;
        for (int k = next_id; k < N; k++) begin
          if (match < 0 && sink.done_len == exp_len[k]) begin
            bad = 0;
            for (int i = 0; i < sink.done_len; i++)
              if (sink.fbuf[i] !== pat(k, i)) bad = 1;
            if (!bad) match = k;
          end
        end
        if (match < 0) begin
          $display("[%0t] FAIL: unflagged frame (len %0d) matches no sent frame >= id %0d",
                   $time, sink.done_len, next_id);
          errors++;
        end else begin
          good++;
          if (match >= NA && b_first < 0) b_first = match;
          last_good = match;
          next_id = match + 1;
        end
      end
    end
  end

  int dropped_after_a;
  initial begin
    for (int i = 0; i < N; i++) exp_len[i] = $urandom_range(1500, 60);
    do_reset();
    wait (dut.ctrl_state == ST_ACTIVE);
    repeat (20) @(posedge eth_clk);

    // Phase A: back-to-back source, ~4%-ready sink -> Rx overload
    mac.gap_pct    = 0;
    sink.ready_pct = 4;
    for (int i = 0; i < NA; i++) mac.send_frame(i, exp_len[i]);

    // let the Rx side drain at full rate
    sink.ready_pct = 100;
    repeat (20000) @(posedge pclk);
    dropped_after_a = dut.rx_dropped_flits;

    // Phase B: gapped source, full-rate sink -> must be clean
    mac.gap_pct = 30;
    for (int i = NA; i < N; i++) mac.send_frame(i, exp_len[i]);
    repeat (20000) @(posedge pclk);

    chk(dropped_after_a > 0, "phase A produced Rx flit drops (overload exercised)");
    chk(dut.rx_dropped_flits == dropped_after_a, "no drops in recovery phase B");
    chk(errf > 0, "at least one frame flagged aborted");
    chk(dut.rx_aborted_frames == errf, "aborted_frames counter == err-flagged frames at the sink");
    chk(b_first == NA && last_good == N - 1 && good >= NB, "every phase-B frame received intact and in order");
    chk(sink.errors == 0, "sink tkeep/tuser legality");
    chk(phy.errors == 0 && phyc.errors == 0, "PHY models clean");
    csr_rd(CSR_RXCNT0, d);
    chk(d[15:0] == dut.rx_dropped_flits, "RXCNT0 dropped count visible via CSR");
    csr_rd(CSR_RXCNT1, d);
    chk(d[31:16] == dut.rx_aborted_frames, "RXCNT1 aborted count visible via CSR");

    if (errors == 0)
      $display("RXOVF PASS: %0d frames sent, %0d good, %0d flagged aborted, %0d flits dropped, %0d orphan flits, recovery clean",
               N, good, errf, dut.rx_dropped_flits, dut.rx_bad_flits);
    else
      $display("RXOVF FAIL: %0d error(s) (good %0d, aborted %0d, dropped %0d)", errors, good, errf, dut.rx_dropped_flits);
    $finish;
  end

  initial begin
    #20000000;
    $display("RXOVF FAIL: global timeout");
    $finish;
  end
endmodule
