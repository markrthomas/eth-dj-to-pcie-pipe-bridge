// ============================================================================
// dv/iverilog/tb_link.sv — TWO-ENDED link test (docs/OPEN_DECISIONS.md D16).
// Two complete bridges (A, B) cross-connected: A.pipe_tx -> B.pipe_rx and B.pipe_tx ->
// A.pipe_rx (A->B passes a flit killer).  Each end has its own MAC source, Ethernet sink,
// PHY control model and flit monitor.  Built with -DFLOW_CTRL_OVERRIDE.
//   P1  bidirectional traffic, fast sinks           : all frames intact, no drops/aborts
//   P2  B's sink fully stalled while A floods       : A is back-pressured (tready low),
//                                                     B drops/aborts nothing; released -> all arrive
//   P3  slow sinks (10% ready), both directions     : all intact, zero drops
//   P4  5 flits killed on the wire, sink at 50%     : no silent corruption; at most one frame
//                                                     lost/aborted per killed flit
//   P5  clean traffic afterwards                    : all intact (no credit leaked) and at
//                                                     quiescence credits are back to INIT_CREDITS
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

// ---- one end of the link: bridge + MAC source + Ethernet sink + PHY models ------------------
module link_end
  import eth_dj_pipe7_pkg::*;
(
  input  logic                   eth_clk,
  input  logic                   pclk,
  input  logic                   eth_rst_n,
  input  logic                   pipe_rst_n,
  input  logic [PIPE_BUS_W-1:0]  rx_data,
  input  logic                   rx_valid,
  input  logic                   rx_sb,
  output logic [PIPE_BUS_W-1:0]  tx_data,
  output logic                   tx_valid,
  output logic                   tx_sb
);
  wire                     eth_tvalid, eth_tready, eth_tlast;
  wire [ETH_DATA_W-1:0]    eth_tdata;
  wire [ETH_KEEP_W-1:0]    eth_tkeep;
  wire [ETH_USER_W-1:0]    eth_tuser;
  wire                     eth_rx_tvalid, eth_rx_tready, eth_rx_tlast;
  wire [ETH_DATA_W-1:0]    eth_rx_tdata;
  wire [ETH_KEEP_W-1:0]    eth_rx_tkeep;
  wire [ETH_USER_W-1:0]    eth_rx_tuser;
  pipe_pwr_e               pipe_powerdown;
  pipe_rate_e              pipe_rate;
  wire [1:0]               pipe_width;
  wire                     pipe_phy_status;
  wire [MSGBUS_W-1:0]      m2p, p2m;
  wire [31:0]              csr_rdata;

  eth_dj_pipe7_bridge dut (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n),
    .eth_tvalid(eth_tvalid), .eth_tready(eth_tready), .eth_tdata(eth_tdata),
    .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast), .eth_tuser(eth_tuser),
    .eth_rx_tvalid(eth_rx_tvalid), .eth_rx_tready(eth_rx_tready), .eth_rx_tdata(eth_rx_tdata),
    .eth_rx_tkeep(eth_rx_tkeep), .eth_rx_tlast(eth_rx_tlast), .eth_rx_tuser(eth_rx_tuser),
    .pclk(pclk), .pipe_rst_n(pipe_rst_n),
    .pipe_tx_data(tx_data), .pipe_tx_data_valid(tx_valid), .pipe_tx_start_block(tx_sb),
    .pipe_rx_data(rx_data), .pipe_rx_data_valid(rx_valid), .pipe_rx_start_block(rx_sb),
    .pipe_rate(pipe_rate), .pipe_width(pipe_width), .pipe_powerdown(pipe_powerdown),
    .pipe_phy_status(pipe_phy_status), .pipe_rx_valid(1'b0), .pipe_rx_elec_idle(1'b1),
    .pipe_m2p_msgbus(m2p), .pipe_p2m_msgbus(p2m),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr(8'h00), .csr_wdata(32'h0), .csr_rdata(csr_rdata)
  );

  eth_mac_model mac (
    .eth_clk(eth_clk), .eth_tvalid(eth_tvalid), .eth_tready(eth_tready),
    .eth_tdata(eth_tdata), .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast), .eth_tuser(eth_tuser)
  );

  pipe_phy_model mon (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .pipe_tx_data(tx_data),
    .pipe_tx_data_valid(tx_valid), .pipe_tx_start_block(tx_sb)
  );

  pipe_phy_ctrl_model phyc (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .powerdown(pipe_powerdown), .rate(pipe_rate),
    .width(pipe_width), .tx_data_valid(tx_valid), .m2p(m2p),
    .phy_status(pipe_phy_status), .p2m(p2m)
  );

  eth_sink_model sink (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n), .eth_rx_tvalid(eth_rx_tvalid),
    .eth_rx_tready(eth_rx_tready), .eth_rx_tdata(eth_rx_tdata),
    .eth_rx_tkeep(eth_rx_tkeep), .eth_rx_tlast(eth_rx_tlast), .eth_rx_err(eth_rx_tuser[0])
  );
endmodule : link_end

module tb_link;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"

  localparam int NMAX = 400;
  localparam int KWIN = 8;               // how many ids ahead a received frame may skip (loss phase)

  logic eth_clk = 1'b0, pclk = 1'b0;
  logic eth_rst_n, pipe_rst_n;
  always #2.5 eth_clk = ~eth_clk;   // 200 MHz
  always #1.0 pclk    = ~pclk;      // 500 MHz

  wire [PIPE_BUS_W-1:0] a_tx_data, b_tx_data;
  wire                  a_tx_valid, a_tx_sb, b_tx_valid, b_tx_sb;

  // ---- flit killer on A -> B --------------------------------------------------------------------
  int  kill_req = 0, kills_done = 0;
  int  kill_left = 0;
  wire start_kill = a_tx_valid && a_tx_sb && (kill_req != kills_done) && (kill_left == 0);
  wire masking    = (kill_left != 0) || start_kill;
  always @(posedge pclk) begin
    if (start_kill) begin kill_left <= FLIT_BEATS - 1; kills_done <= kills_done + 1; end
    else if (kill_left != 0) kill_left <= kill_left - 1;
  end
  wire [PIPE_BUS_W-1:0] b_rx_data  = masking ? '0 : a_tx_data;
  wire                  b_rx_valid = masking ? 1'b0 : a_tx_valid;
  wire                  b_rx_sb    = masking ? 1'b0 : a_tx_sb;

  link_end endA (.eth_clk(eth_clk), .pclk(pclk), .eth_rst_n(eth_rst_n), .pipe_rst_n(pipe_rst_n),
    .rx_data(b_tx_data), .rx_valid(b_tx_valid), .rx_sb(b_tx_sb),
    .tx_data(a_tx_data), .tx_valid(a_tx_valid), .tx_sb(a_tx_sb));
  link_end endB (.eth_clk(eth_clk), .pclk(pclk), .eth_rst_n(eth_rst_n), .pipe_rst_n(pipe_rst_n),
    .rx_data(b_rx_data), .rx_valid(b_rx_valid), .rx_sb(b_rx_sb),
    .tx_data(b_tx_data), .tx_valid(b_tx_valid), .tx_sb(b_tx_sb));

  // ---- expected frames per direction: 0 = A->B (seen at B's sink), 1 = B->A --------------------------
  int len0 [0:NMAX-1];
  int len1 [0:NMAX-1];
  int nid [0:1];          // next id expected at the sink
  int good [0:1], errf [0:1], skipped [0:1], corrupt [0:1];
  int errors = 0;

  function automatic int elen(input int dir, input int id);
    begin elen = (dir == 0) ? len0[id] : len1[id]; end
  endfunction

  function automatic bit bytes_match(input int dir, input int id, input int n);
    bit ok;
    begin
      ok = 1'b1;
      for (int i = 0; i < n; i++)
        if (((dir == 0) ? endB.sink.fbuf[i] : endA.sink.fbuf[i]) !== pat(id, i)) ok = 1'b0;
      bytes_match = ok;
    end
  endfunction

  task automatic check_frame(input int dir, input int flen, input bit ferr);
    int found;
    begin
      found = -1;
      for (int k = 0; k < KWIN; k++) begin
        if (found < 0 && nid[dir] + k < NMAX) begin
          if (ferr ? (flen <= elen(dir, nid[dir] + k) && bytes_match(dir, nid[dir] + k, flen))
                   : (flen == elen(dir, nid[dir] + k) && bytes_match(dir, nid[dir] + k, flen)))
            found = nid[dir] + k;
        end
      end
      if (found < 0) begin
        corrupt[dir]++;
        $display("[%0t] LINK ERROR: dir %0d frame len %0d err=%0b matches none of ids %0d..%0d (lens %0d %0d %0d) b0..3=%h %h %h %h",
                 $time, dir, flen, ferr, nid[dir], nid[dir] + KWIN - 1, elen(dir, nid[dir]), elen(dir, nid[dir]+1), elen(dir, nid[dir]+2),
                 (dir==0)?endB.sink.fbuf[0]:endA.sink.fbuf[0], (dir==0)?endB.sink.fbuf[1]:endA.sink.fbuf[1],
                 (dir==0)?endB.sink.fbuf[2]:endA.sink.fbuf[2], (dir==0)?endB.sink.fbuf[3]:endA.sink.fbuf[3]);
      end else begin
        skipped[dir] += found - nid[dir];
        nid[dir] = found + 1;
        if (ferr) errf[dir]++; else good[dir]++;
      end
    end
  endtask

  always @(posedge eth_clk) begin
    if (endB.sink.frame_done) check_frame(0, endB.sink.done_len, endB.sink.done_err);
    if (endA.sink.frame_done) check_frame(1, endA.sink.done_len, endA.sink.done_err);
  end

  // ---- back-pressure observation: cycles A's source was stalled --------------------------------------
  int stallA = 0;
  always @(posedge eth_clk) if (endA.eth_tvalid && !endA.eth_tready) stallA++;

  // ---- helpers ----------------------------------------------------------------------------------------
  task automatic chk(input bit c, input string w);
    begin if (!c) begin errors++; $display("FAIL: %s", w); end end
  endtask

  task automatic send_range(input int dir, input int lo, input int hi);
    begin
      for (int id = lo; id < hi; id++) begin
        if (dir == 0) endA.mac.send_frame(id, len0[id]);
        else          endB.mac.send_frame(id, len1[id]);
      end
    end
  endtask

  // wait until every id below `hi` in `dir` has been accounted for (delivered, aborted or skipped)
  task automatic wait_done(input int dir, input int hi, input int max_cycles, input string what);
    int n;
    begin
      n = 0;
      while (nid[dir] < hi && n < max_cycles) begin @(posedge pclk); n++; end
      chk(nid[dir] >= hi, {what, ": all frames accounted for"});
    end
  endtask

  task automatic quiesce(); begin repeat (6000) @(posedge pclk); end endtask

  task automatic check_no_rx_loss(input string what);
    begin
      chk(endA.dut.rx_dropped_flits == 0 && endB.dut.rx_dropped_flits == 0, {what, ": no Rx flit dropped"});
      chk(endA.dut.rx_lock_errors == 0 && endB.dut.rx_lock_errors == 0,     {what, ": no Rx lock errors"});
      chk(endA.dut.rx_aborted_frames == 0 && endB.dut.rx_aborted_frames == 0, {what, ": no aborted frames"});
    end
  endtask

  task automatic check_credits(input string what);
    logic [15:0] ca, cb;
    begin
      // at quiescence each side's view of the remote limit equals what the remote advertises, and
      // exactly INIT_CREDITS are available (nothing leaked, nothing invented)
      ca = endB.dut.fc_cl - endA.dut.u_fc.s_cnt_q;
      cb = endA.dut.fc_cl - endB.dut.u_fc.s_cnt_q;
      chk(endA.dut.rx_cl_remote == endB.dut.fc_cl, {what, ": A knows B's credit limit"});
      chk(endB.dut.rx_cl_remote == endA.dut.fc_cl, {what, ": B knows A's credit limit"});
      chk(ca == 16'(INIT_CREDITS), {what, ": A->B credits back to INIT_CREDITS"});
      chk(cb == 16'(INIT_CREDITS), {what, ": B->A credits back to INIT_CREDITS"});
      if (ca != 16'(INIT_CREDITS) || cb != 16'(INIT_CREDITS))
        $display("       credits A->B=%0d B->A=%0d (expected %0d)", ca, cb, INIT_CREDITS);
    end
  endtask

  int id0, id1, t0, t1;
  int nlow, nhi;
  initial begin
    for (int i = 0; i < NMAX; i++) begin
      len0[i] = $urandom_range(1500, 1);
      len1[i] = $urandom_range(1500, 1);
    end
    // corner lengths
    len0[0] = 1;   len0[1] = 240; len0[2] = 241; len0[3] = 64;  len0[4] = 480;
    len1[0] = 240; len1[1] = 1;   len1[2] = 32;  len1[3] = 1500; len1[4] = 33;
    nid[0] = 0; nid[1] = 0;
    for (int d = 0; d < 2; d++) begin good[d] = 0; errf[d] = 0; skipped[d] = 0; corrupt[d] = 0; end

    eth_rst_n = 1'b0; pipe_rst_n = 1'b0;
    repeat (10) @(posedge pclk);
    eth_rst_n = 1'b1; pipe_rst_n = 1'b1;
    wait (endA.dut.ctrl_state == ST_ACTIVE && endB.dut.ctrl_state == ST_ACTIVE);
    repeat (400) @(posedge pclk);

    // ---- P1: bidirectional, fast sinks ----------------------------------------------------------
    fork send_range(0, 0, 40); send_range(1, 0, 40); join
    wait_done(0, 40, 400000, "P1 A->B"); wait_done(1, 40, 400000, "P1 B->A");
    quiesce();
    chk(good[0] == 40 && good[1] == 40 && skipped[0] == 0 && skipped[1] == 0 && errf[0] == 0 && errf[1] == 0,
        "P1 every frame delivered intact in both directions");
    check_no_rx_loss("P1"); check_credits("P1");
    chk(endA.mon.cr_flits > 0 && endB.mon.cr_flits > 0, "P1 credit-only flits were exchanged");

    // ---- P2: B's sink fully stalled while A floods ---------------------------------------------------
    endB.sink.ready_pct = 0;
    stallA = 0;
    fork
      send_range(0, 40, 70);                                   // ~30 large frames >> buffering
      begin
        repeat (30000) @(posedge pclk);                        // ~60 us of stall
        chk(stallA > 1000, "P2 A's source was back-pressured while B's sink is stalled");
        check_no_rx_loss("P2 (during stall)");
        chk(endB.sink.frames == good[0] + errf[0], "P2 nothing reached B's sink while stalled");
        endB.sink.ready_pct = 100;
      end
    join
    wait_done(0, 70, 800000, "P2 A->B");
    quiesce();
    chk(good[0] == 70 && skipped[0] == 0 && errf[0] == 0, "P2 all flooded frames arrived intact after release");
    check_no_rx_loss("P2"); check_credits("P2");

    // ---- P3: slow sinks, both directions -------------------------------------------------------------
    endA.sink.ready_pct = 10; endB.sink.ready_pct = 10;
    fork send_range(0, 70, 110); send_range(1, 40, 80); join
    wait_done(0, 110, 3000000, "P3 A->B"); wait_done(1, 80, 3000000, "P3 B->A");
    endA.sink.ready_pct = 100; endB.sink.ready_pct = 100;
    quiesce();
    chk(good[0] == 110 && good[1] == 80 && skipped[0] == 0 && skipped[1] == 0 && errf[0] == 0 && errf[1] == 0,
        "P3 all frames intact with slow sinks");
    check_no_rx_loss("P3"); check_credits("P3");

    // ---- P4: flits killed on the wire A -> B ---------------------------------------------------------------
    endB.sink.ready_pct = 50;
    fork
      send_range(0, 110, 170);
      begin
        for (int k = 0; k < 5; k++) begin
          repeat (600 + 300 * k) @(posedge pclk);
          kill_req = kill_req + 1;
          t0 = 0;
          while (kills_done != kill_req && t0 < 20000) begin @(posedge pclk); t0++; end
        end
      end
    join
    quiesce();
    endB.sink.ready_pct = 100;
    repeat (20000) @(posedge pclk);
    chk(kills_done == 5, "P4 all 5 kills were applied");
    chk(corrupt[0] == 0 && corrupt[1] == 0, "P4 no silent corruption: every received frame matches an expected one");
    chk(skipped[0] + errf[0] <= kills_done, "P4 at most one frame lost/aborted per killed flit");
    chk(endB.dut.rx_dropped_flits == 0, "P4 no credited flit was dropped for lack of a slot");
    $display("       P4: A->B good=%0d aborted=%0d skipped=%0d (kills=%0d)", good[0], errf[0], skipped[0], kills_done);
    nid[0] = 170;                                          // resynchronise the scoreboard past the loss window

    // ---- P5: clean traffic afterwards: no credit leaked ---------------------------------------------------------
    id0 = good[0]; id1 = good[1];
    endB.sink.ready_pct = 100;
    fork send_range(0, 170, 230); send_range(1, 80, 130); join
    wait_done(0, 230, 1500000, "P5 A->B"); wait_done(1, 130, 1500000, "P5 B->A");
    quiesce();
    chk(good[0] - id0 == 60 && good[1] - id1 == 50, "P5 all post-loss frames intact (credit was not leaked)");
    chk(skipped[0] + errf[0] <= kills_done && skipped[1] == 0 && errf[1] == 0, "P5 no further loss");
    check_credits("P5 (after losses)");

    chk(endA.sink.errors == 0 && endB.sink.errors == 0, "sink tkeep checks");
    chk(endA.mon.errors == 0 && endB.mon.errors == 0, "flit monitors: format + seq fields");
    chk(endA.phyc.errors == 0 && endB.phyc.errors == 0, "PHY control model");

    $display("       A->B good=%0d aborted=%0d skipped=%0d; B->A good=%0d; cr flits A=%0d B=%0d; A source stalled %0d cycles",
             good[0], errf[0], skipped[0], good[1], endA.mon.cr_flits, endB.mon.cr_flits, stallA);
    if (errors == 0) $display("LINK PASS: two-ended flow control (P1-P5)");
    else             $display("LINK FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin #2000000; $display("LINK FAIL: global timeout (stall: send or wait never completed)"); $finish; end
endmodule
