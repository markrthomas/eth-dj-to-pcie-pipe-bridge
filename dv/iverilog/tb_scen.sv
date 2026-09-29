// ============================================================================
// dv/iverilog/tb_scen.sv — the shared five-scenario set (dv/common/scenarios.py)
// on the Icarus loopback harness.  Resets the DUT before each scenario, runs it,
// and writes sim_build/results.json for dv/common/crosscheck.py.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_scen;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"
  `include "scenarios.svh"
  `include "loop_harness.svh"

  int          rx_frames, rx_bytes, errors, tot_err, nfr, base_flits, base_err, fd, sc;
  logic [31:0] crc, d;
  logic        running = 1'b0;

  // ---- scoreboard: in-order byte check + CRC over everything received ------
  always @(posedge eth_clk) begin
    if (running && sink.frame_done) begin
      if (sink.done_err || rx_frames >= nfr || sink.done_len != scen_len(sc, rx_frames)) begin
        $display("FAIL: %s frame %0d len %0d err %b", scen_name(sc), rx_frames, sink.done_len, sink.done_err);
        errors++;
      end else begin
        for (int i = 0; i < sink.done_len; i++)
          if (sink.fbuf[i] !== pat(rx_frames, i)) errors++;
      end
      for (int i = 0; i < sink.done_len; i++) crc = crc32_byte(crc, sink.fbuf[i]);
      rx_bytes  += sink.done_len;
      rx_frames++;
    end
  end

  task automatic wait_rx(input int n);
    int t;
    begin
      t = 0;
      while (rx_frames < n && t < 400000) begin @(posedge pclk); t++; end
      if (rx_frames < n) begin $display("FAIL: timeout waiting for %0d frames", n); errors++; end
    end
  endtask

  task automatic set_wait(input logic [1:0] pd, input logic [2:0] rt);
    int t;
    begin
      csr_wr(CSR_CTRL, {25'b0, 2'b00, rt, pd});
      t = 0;
      d = '0;
      while (t < 20000) begin
        csr_rd(CSR_STATUS, d);
        if (d[1:0] == pd && d[4:2] == rt && d[10] == 1'b0) t = 1000000; else t++;
      end
      if (t != 1000000) begin $display("FAIL: control op timeout"); errors++; end
    end
  endtask

  initial begin
    fd = $fopen("sim_build/results.json", "w");
    $fwrite(fd, "{\"env\": \"iverilog\", \"scenarios\": {");
    tot_err = 0;
    mac.gap_pct    = 10;
    sink.ready_pct = 90;
    for (sc = 0; sc < SCEN_N; sc++) begin
      rx_frames = 0; rx_bytes = 0; errors = 0; crc = 32'hFFFF_FFFF;
      nfr = scen_nframes(sc);
      do_reset();
      wait (dut.ctrl_state == ST_ACTIVE);
      base_flits = phy.flits;
      base_err   = phy.errors + phyc.errors + sink.errors;
      running = 1'b1;
      if (scen_ctrl(sc) == 0) begin
        for (int i = 0; i < nfr; i++) mac.send_frame(i, scen_len(sc, i));
      end else begin
        for (int i = 0; i < nfr / 2; i++) mac.send_frame(i, scen_len(sc, i));
        wait_rx(nfr / 2);
        if (scen_ctrl(sc) == 1) begin
          set_wait(PWR_P1, RATE_GEN6);
          repeat (200) @(posedge pclk);
          set_wait(PWR_P0, RATE_GEN6);
        end else begin
          set_wait(PWR_P0, RATE_GEN5);
          repeat (200) @(posedge pclk);
          set_wait(PWR_P0, RATE_GEN6);
        end
        for (int i = nfr / 2; i < nfr; i++) mac.send_frame(i, scen_len(sc, i));
      end
      wait_rx(nfr);
      repeat (200) @(posedge pclk);
      running = 1'b0;
      csr_rd(CSR_PMCNT, d);
      errors += phy.errors + phyc.errors + sink.errors - base_err;
      tot_err += errors;
      $display("SCEN %-11s frames=%0d bytes=%0d flits=%0d crc32=%08x pmcnt=%0d errors=%0d",
               scen_name(sc), rx_frames, rx_bytes, phy.flits - base_flits, ~crc, d, errors);
      $fwrite(fd, "%s\"%s\": {\"frames\": %0d, \"bytes\": %0d, \"flits\": %0d, \"crc32\": \"%08x\", \"pmcnt\": %0d, \"errors\": %0d}",
              (sc == 0) ? "" : ", ", scen_name(sc), rx_frames, rx_bytes, phy.flits - base_flits, ~crc, d, errors);
    end
    $fwrite(fd, "}}\n");
    $fclose(fd);
    if (tot_err == 0) $display("SCEN PASS: 5 scenarios, results in sim_build/results.json");
    else              $display("SCEN FAIL: %0d error(s)", tot_err);
    $finish;
  end

  initial begin
    #50000000;
    $display("SCEN FAIL: global timeout");
    $finish;
  end
endmodule
