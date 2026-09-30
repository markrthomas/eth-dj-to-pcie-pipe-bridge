// ============================================================================
// dv/iverilog/tb_pm.sv — M3 directed control-plane test under live loopback traffic.
//
// A MAC thread streams random frames (1..1500 B, 20% source gaps, 95%-ready
// sink) the whole time, while a CSR thread walks the control plane:
//   power cycle  P0 -> P1 -> P2 -> (P2 -> P1 -> P0)
//   rate change  Gen6 -> Gen5 (no PAM4 msgbus write) -> Gen6 (PAM4 re-sent)
//   width change 0 -> 1 -> 0
//   PAM4CFG rewrite -> new value reaches the PHY over the message bus
//   cancelled request: P1 requested, then P0 again while the drain is in flight
//   P0s request -> ERR[2], link stays up; W1C clear
//   PhyStatus timeout: PHY muted during a rate change -> ERR[0], FSM recovers
// Checks: every frame looped back in order and byte-exact, none aborted, no Rx
// drops; the PHY control model sees no Tx outside P0 / during a pin change;
// powerdown history and CSR STATUS/ERR/PMCNT match the expected sequence.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_pm;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"
  `include "loop_harness.svh"

  localparam int MAXF = 4096;

  int exp_len [0:MAXF-1];
  int sent = 0, checked = 0, errors = 0, bad;
  logic ctl_done = 1'b0;
  logic [31:0] d;

  task automatic chk(input logic c, input string msg);
    if (!c) begin $display("[%0t] FAIL: %s", $time, msg); errors++; end
  endtask

  // ---- scoreboard ----------------------------------------------------------
  always @(posedge eth_clk) begin
    if (sink.frame_done) begin
      if (checked >= sent) begin
        $display("FAIL: unexpected extra frame"); errors++;
      end else if (sink.done_err) begin
        $display("FAIL: frame %0d aborted (tuser err)", checked); errors++;
        checked++;
      end else begin
        if (sink.done_len != exp_len[checked]) begin
          $display("FAIL: frame %0d length %0d, expected %0d", checked, sink.done_len, exp_len[checked]);
          errors++;
        end else begin
          bad = -1;
          for (int i = 0; i < sink.done_len; i++)
            if (bad < 0 && sink.fbuf[i] !== pat(checked, i)) bad = i;
          if (bad >= 0) begin
            $display("FAIL: frame %0d byte %0d = %02x, expected %02x",
                     checked, bad, sink.fbuf[bad], pat(checked, bad));
            errors++;
          end
        end
        checked++;
      end
    end
  end

  // ---- wait for the control plane to settle on a target ---------------------
  task automatic wait_state(input logic [1:0] pd, input logic [2:0] rt, input logic [1:0] wd,
                            input string what);
    int n;
    begin
      n = 0;
      d = '0;
      while (n < 20000) begin
        csr_rd(CSR_STATUS, d);
        if (d[1:0] == pd && d[4:2] == rt && d[6:5] == wd && d[10] == 1'b0) n = 1000000;
        else n++;
      end
      chk(n == 1000000, {"timeout waiting for ", what});
      chk(pipe_powerdown == pd && pipe_rate == rt && pipe_width == wd, {"PIPE pins after ", what});
    end
  endtask

  task automatic wait_mb(input int unsigned n_writes, input string what);
    int n;
    begin
      n = 0;
      while (phyc.mb_writes < n_writes && n < 20000) begin @(posedge pclk); n++; end
      chk(phyc.mb_writes == n_writes, {"message-bus write count after ", what});
    end
  endtask

  function automatic logic [31:0] ctrl(input logic [1:0] pd, input logic [2:0] rt, input logic [1:0] wd);
    ctrl = {25'b0, wd, rt, pd};
  endfunction

  // ---- traffic ---------------------------------------------------------------
  initial begin
    do_reset();
    repeat (20) @(posedge eth_clk);
    mac.gap_pct    = 20;
    sink.ready_pct = 95;
    while (!ctl_done && sent < MAXF) begin
      exp_len[sent] = $urandom_range(1500, 1);
      sent++;                               // count before send: scoreboard may see it early
      mac.send_frame(sent - 1, exp_len[sent - 1]);
    end
  end

  // ---- control sequence ---------------------------------------------------------
  initial begin
    #1;
    wait (pipe_rst_n === 1'b1);
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "link-up");
    wait_mb(1, "link-up");
    repeat (3000) @(posedge pclk);

    // power cycle P0 -> P1 -> P2 -> P0
    csr_wr(CSR_CTRL, ctrl(PWR_P1, RATE_GEN6, 2'd0));
    wait_state(PWR_P1, RATE_GEN6, 2'd0, "P0->P1");
    repeat (50) @(posedge eth_clk);
    chk(eth_tready === 1'b0, "ingress closed in P1");
    chk(pipe_tx_data_valid === 1'b0, "no Tx in P1");
    csr_wr(CSR_CTRL, ctrl(PWR_P2, RATE_GEN6, 2'd0));
    wait_state(PWR_P2, RATE_GEN6, 2'd0, "P1->P2");
    repeat (1000) @(posedge pclk);
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "P2->P0");
    chk(phyc.pd_hist_n == 5 && phyc.pd_hist[1] == PWR_P1 && phyc.pd_hist[2] == PWR_P2 &&
        phyc.pd_hist[3] == PWR_P1 && phyc.pd_hist[4] == PWR_P0,
        "powerdown sequence P0,P1,P2,P1,P0");
    chk(phyc.mb_writes == 1, "no PAM4 re-send on a power cycle");
    repeat (3000) @(posedge pclk);

    // rate change Gen6 -> Gen5 -> Gen6
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN5, 2'd0));
    wait_state(PWR_P0, RATE_GEN5, 2'd0, "rate Gen6->Gen5");
    repeat (2000) @(posedge pclk);
    chk(phyc.mb_writes == 1, "no PAM4 msgbus write at Gen5 (NRZ)");
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "rate Gen5->Gen6");
    wait_mb(2, "return to Gen6");
    chk(phyc.rate_changes == 2, "two rate changes seen by the PHY");
    repeat (2000) @(posedge pclk);

    // width change 0 -> 1 -> 0
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd1));
    wait_state(PWR_P0, RATE_GEN6, 2'd1, "width 0->1");
    repeat (2000) @(posedge pclk);
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "width 1->0");
    chk(phyc.width_changes == 2, "two width changes seen by the PHY");

    // PAM4CFG rewrite
    csr_wr(CSR_PAM4CFG, 32'hF5);            // bits [7:6] set: must be masked (bit 7 = coefficient-request strobe)
    wait_mb(3, "PAM4CFG write");
    chk(phyc.last_mb_addr == MB_ADDR_TX_PRESET && phyc.last_mb_data == 8'h35, "PAM4CFG value at PHY (reserved bits masked)");
    csr_rd(CSR_PAM4CFG, d);
    chk(d === 32'h35, "PAM4CFG reads back with [7:6] = 0");
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "PAM4CFG write");
    repeat (2000) @(posedge pclk);

    // cancelled request: P1 requested, then P0 again before the drain completes
    wait (dut.u_tx_egress.busy === 1'b1);   // a flit is in flight, so the drain takes time
    csr_wr(CSR_CTRL, ctrl(PWR_P1, RATE_GEN6, 2'd0));
    wait (dut.ctrl_state == ST_DRAIN);
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "cancelled P1 request");
    chk(phyc.pd_hist_n == 5, "cancelled P1 request caused no powerdown change");
    repeat (2000) @(posedge pclk);

    // P0s is unsupported
    csr_wr(CSR_CTRL, ctrl(PWR_P0S, RATE_GEN6, 2'd0));
    repeat (20) @(posedge pclk);
    csr_rd(CSR_ERR, d);
    chk(d[2] == 1'b1, "ERR[2] set on a P0s request");
    chk(pipe_powerdown == PWR_P0 && dut.ctrl_state == ST_ACTIVE, "P0s request keeps the link in P0");
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    repeat (5) @(posedge pclk);
    csr_wr(CSR_ERR, 32'h4);
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "ERR W1C clears");

    // PhyStatus timeout during a rate change
    phyc.mute_status = 1'b1;
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN5, 2'd0));
    wait_state(PWR_P0, RATE_GEN5, 2'd0, "muted rate change");
    phyc.mute_status = 1'b0;
    csr_rd(CSR_ERR, d);
    chk(d[0] == 1'b1, "ERR[0] PhyStatus timeout flagged");
    csr_wr(CSR_ERR, 32'h1);
    csr_wr(CSR_CTRL, ctrl(PWR_P0, RATE_GEN6, 2'd0));
    wait_state(PWR_P0, RATE_GEN6, 2'd0, "rate restore after timeout");
    wait_mb(4, "Gen6 restore");
    csr_rd(CSR_ERR, d);
    chk(d == 32'h0, "no further errors after recovery");

    // ops: link-up 2, P1/P2/P1/P0 4, rate x2 + PAM4 3, width x2 2, PAM4 1,
    //      timeout rate 1, restore rate + PAM4 2   = 15
    csr_rd(CSR_PMCNT, d);
    chk(d == 32'd15, "PMCNT == 15 completed control operations");
    repeat (2000) @(posedge pclk);
    ctl_done = 1'b1;
  end

  // ---- end of test ---------------------------------------------------------------
  initial begin
    wait (ctl_done === 1'b1);
    fork
      begin wait (checked == sent && !eth_tvalid); end
      begin repeat (400000) @(posedge pclk); end
    join_any
    repeat (500) @(posedge pclk);
    csr_rd(CSR_PMCNT, d);   // keep the bus quiet; value already checked
    chk(checked == sent, "all frames looped back");
    chk(sink.errors == 0 && sink.err_frames == 0, "sink clean");
    chk(phy.errors == 0, "PHY flit monitor clean");
    chk(phyc.errors == 0, "PHY control model clean (no Tx outside P0 or during a change)");
    chk(dut.rx_dropped_flits == 0 && dut.rx_lock_errors == 0 && dut.rx_bad_flits == 0 &&
        dut.rx_aborted_frames == 0, "Rx counters zero");
    if (errors == 0)
      $display("PM PASS: %0d frames across power/rate/width/cfg changes, %0d flits, %0d PHY pin changes",
               sent, phy.flits, phyc.pd_changes + phyc.rate_changes + phyc.width_changes);
    else
      $display("PM FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("PM FAIL: global timeout (%0d/%0d frames, state %0d)", checked, sent, dut.ctrl_state);
    $finish;
  end
endmodule
