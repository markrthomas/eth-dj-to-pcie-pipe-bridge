// ============================================================================
// lp/tb_pipe7_upf_power.sv — power-aware TB top for lp/bridge.upf.
//
// Instantiates the bridge (via the shared loopback harness) plus the DV-only
// pipe7_pmu.  lp/bridge.upf is written against THIS scope (u_dut = the bridge,
// u_pmu = the sequencer).  With a commercial power-aware simulator
// (+define+UPF_SIM, load bridge.upf) the PMU controls actually gate PD_DP.
//
// Under Icarus (`make upf-tb`) there are NO power semantics: the UPF is not
// read, nothing is switched off or clamped.  That run only checks
//   * the PMU sequencing order (iso before save before off; on before restore
//     before de-iso) and that it really powers down in P1 and P2 episodes,
//   * the no-handshake timing assumption: whenever the control FSM is outside
//     ST_RESET / ST_LOWPWR / ST_PWR_CHG, PD_DP is powered and not isolated,
//   * that traffic before/after the low-power episodes is byte-exact.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_pipe7_upf_power;
  import eth_dj_pipe7_pkg::*;
`ifdef UPF_SIM
  import UPF::*;               // supply_on/supply_off (IEEE 1801 simulation package)
`endif
  `include "eth_dj_pat.svh"
  `include "loop_harness.svh"

  logic dp_pwr_en, dp_iso_en, dp_save, dp_restore, dp_off;
  int   n_down, n_up, errors, rx_frames, nsent;
  logic [31:0] d;

  pipe7_pmu #(.DOWN_DELAY(16), .PWR_UP_CYC(2)) u_pmu (
    .pclk(pclk), .rst_n(pipe_rst_n), .powerdown(pipe_powerdown),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
    .dp_pwr_en(dp_pwr_en), .dp_iso_en(dp_iso_en), .dp_save(dp_save), .dp_restore(dp_restore),
    .dp_off(dp_off), .n_down(n_down), .n_up(n_up));

`ifdef UPF_SIM
  initial begin
    supply_on("VDD", 0.80);
    supply_on("VSS", 0.00);
  end
`endif

  // ---- checks -----------------------------------------------------------------
  logic iso_q, pwr_q, save_seen, restore_seen;
  always @(posedge pclk) begin
    if (!pipe_rst_n) begin
      iso_q <= 1'b0; pwr_q <= 1'b1; save_seen <= 1'b0; restore_seen <= 1'b0;
    end else begin
      iso_q <= dp_iso_en; pwr_q <= dp_pwr_en;
      if (dp_save) save_seen <= 1'b1;
      if (dp_restore) restore_seen <= 1'b1;
      if (dp_save && !dp_iso_en) begin errors++; $display("FAIL: save without isolation"); end
      if (pwr_q && !dp_pwr_en && !(dp_iso_en && save_seen)) begin
        errors++; $display("FAIL: PD_DP switched off before iso+save");
      end
      if (dp_restore && !dp_pwr_en) begin errors++; $display("FAIL: restore while off"); end
      if (iso_q && !dp_iso_en && !(dp_pwr_en && restore_seen)) begin
        errors++; $display("FAIL: isolation released before power-on+restore");
      end
      if (!dp_iso_en) begin save_seen <= 1'b0; end
      if (dp_pwr_en && !dp_iso_en) restore_seen <= 1'b0;
      // timing assumption (no FSM<->PMU handshake)
      if ((dut.ctrl_state != ST_RESET) && (dut.ctrl_state != ST_LOWPWR) &&
          (dut.ctrl_state != ST_PWR_CHG) && (!dp_pwr_en || dp_iso_en)) begin
        errors++;
        $display("FAIL: ctrl FSM in state %0d while PD_DP is off/isolated (pwr_en=%b iso=%b)",
                 dut.ctrl_state, dp_pwr_en, dp_iso_en);
      end
      if (pipe_tx_data_valid && dp_iso_en) begin errors++; $display("FAIL: Tx data while isolated"); end
    end
  end

  // ---- scoreboard: in-order, byte-exact ------------------------------------------
  always @(posedge eth_clk) begin
    if (sink.frame_done) begin
      if (sink.done_err) begin errors++; $display("FAIL: frame %0d aborted", rx_frames); end
      else for (int i = 0; i < sink.done_len; i++)
        if (sink.fbuf[i] !== pat(rx_frames, i)) errors++;
      rx_frames++;
    end
  end

  task automatic send_n(input int n);
    for (int i = 0; i < n; i++) begin mac.send_frame(nsent, 64 + (nsent * 97) % 1400); nsent++; end
  endtask

  task automatic wait_rx();
    int t;
    begin
      t = 0;
      while (rx_frames < nsent && t < 200000) begin @(posedge pclk); t++; end
      if (rx_frames < nsent) begin errors++; $display("FAIL: timeout, %0d/%0d frames", rx_frames, nsent); end
    end
  endtask

  task automatic go(input logic [1:0] pd);
    int t;
    begin
      csr_wr(CSR_CTRL, {27'b0, RATE_GEN6, pd});
      t = 0; d = '0;
      while (t < 20000) begin
        csr_rd(CSR_STATUS, d);
        if (d[1:0] == pd && d[10] == 1'b0) t = 1000000; else t++;
      end
      if (t != 1000000) begin errors++; $display("FAIL: pwr state %0d not reached", pd); end
    end
  endtask

  initial begin
    errors = 0; rx_frames = 0; nsent = 0;
    mac.gap_pct = 10; sink.ready_pct = 90;
    do_reset();
    wait (dut.ctrl_state == ST_ACTIVE);
    send_n(12); wait_rx();
    // P1 episode: park long enough for the PMU to switch PD_DP off
    go(PWR_P1); repeat (100) @(posedge pclk);
    if (!dp_off) begin errors++; $display("FAIL: PD_DP not powered down in P1"); end
    go(PWR_P0);
    send_n(12); wait_rx();
    // P2 episode (P0 -> P1 -> P2 -> P1 -> P0)
    go(PWR_P2); repeat (100) @(posedge pclk);
    if (!dp_off) begin errors++; $display("FAIL: PD_DP not powered down in P2"); end
    go(PWR_P0);
    send_n(12); wait_rx();
    repeat (200) @(posedge pclk);
    errors += phy.errors + phyc.errors + sink.errors;
    if (n_down != 2 || n_up != 2) begin errors++; $display("FAIL: n_down=%0d n_up=%0d", n_down, n_up); end
    if (errors == 0)
      $display("UPF-TB PASS: %0d frames, %0d PD_DP power-down/up cycles (functional only: no UPF semantics under Icarus)",
               rx_frames, n_down);
    else
      $display("UPF-TB FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("UPF-TB FAIL: global timeout");
    $finish;
  end
endmodule
