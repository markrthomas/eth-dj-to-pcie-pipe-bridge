// ============================================================================
// dv/iverilog/tb_tx.sv — M1 directed Tx test: Ethernet frames -> Gen6 flits.
// Directed length corners (1/31/32/33/239/240/241/480/...), then random lengths,
// first back-to-back (FIFO backpressure), then with random gaps.  Every frame is
// reassembled from the PIPE flits by pipe_phy_model and compared byte-for-byte.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_tx;
  import eth_dj_pipe7_pkg::*;
  `include "eth_dj_pat.svh"

  localparam int N_DIRECTED = 15;
  localparam int N_RANDOM   = 100;
  localparam int N          = N_DIRECTED + N_RANDOM;

  logic eth_clk = 1'b0, pclk = 1'b0;
  logic eth_rst_n, pipe_rst_n;

  wire                     eth_tvalid, eth_tready, eth_tlast;
  wire [ETH_DATA_W-1:0]    eth_tdata;
  wire [ETH_KEEP_W-1:0]    eth_tkeep;
  wire [ETH_USER_W-1:0]    eth_tuser;
  wire [PIPE_BUS_W-1:0]    pipe_tx_data;
  wire                     pipe_tx_data_valid, pipe_tx_start_block;
  pipe_pwr_e               pipe_powerdown;
  pipe_rate_e              pipe_rate;
  wire [1:0]               pipe_width;
  wire                     pipe_phy_status;
  wire [MSGBUS_CMD_W-1:0]  m2p_cmd, p2m_cmd;
  wire [MSGBUS_DATA_W-1:0] m2p_data, p2m_data;

  eth_dj_pipe7_bridge dut (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n),
    .eth_tvalid(eth_tvalid), .eth_tready(eth_tready), .eth_tdata(eth_tdata),
    .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast), .eth_tuser(eth_tuser),
    .eth_rx_tvalid(), .eth_rx_tready(1'b1), .eth_rx_tdata(), .eth_rx_tkeep(),
    .eth_rx_tlast(), .eth_rx_tuser(),
    .pclk(pclk), .pipe_rst_n(pipe_rst_n),
    .pipe_tx_data(pipe_tx_data), .pipe_tx_data_valid(pipe_tx_data_valid),
    .pipe_tx_start_block(pipe_tx_start_block),
    .pipe_rx_data('0), .pipe_rx_data_valid(1'b0), .pipe_rx_start_block(1'b0),
    .pipe_rate(pipe_rate), .pipe_width(pipe_width), .pipe_powerdown(pipe_powerdown),
    .pipe_phy_status(pipe_phy_status), .pipe_rx_valid(1'b0), .pipe_rx_elec_idle(1'b1),
    .pipe_m2p_cmd(m2p_cmd), .pipe_m2p_data(m2p_data), .pipe_p2m_cmd(p2m_cmd), .pipe_p2m_data(p2m_data),
    .csr_valid(1'b0), .csr_write(1'b0), .csr_addr('0), .csr_wdata('0), .csr_rdata()
  );

  pipe_phy_ctrl_model phyc (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .powerdown(pipe_powerdown), .rate(pipe_rate),
    .width(pipe_width), .tx_data_valid(pipe_tx_data_valid), .m2p_cmd(m2p_cmd),
    .m2p_data(m2p_data), .phy_status(pipe_phy_status), .p2m_cmd(p2m_cmd), .p2m_data(p2m_data)
  );

  eth_mac_model mac (
    .eth_clk(eth_clk), .eth_tvalid(eth_tvalid), .eth_tready(eth_tready),
    .eth_tdata(eth_tdata), .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast),
    .eth_tuser(eth_tuser)
  );

  pipe_phy_model phy (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .pipe_tx_data(pipe_tx_data),
    .pipe_tx_data_valid(pipe_tx_data_valid), .pipe_tx_start_block(pipe_tx_start_block)
  );

  always #2.5 eth_clk = ~eth_clk;   // 200 MHz
  always #1.0 pclk    = ~pclk;      // 500 MHz

  // ---- scoreboard ----------------------------------------------------------
  int exp_len [0:N-1];
  int unsigned exp_flits = 0;
  int errors = 0;
  int checked = 0;
  int bad;

  always @(posedge pclk) begin
    if (phy.frame_done) begin
      if (checked >= N) begin
        $display("FAIL: unexpected extra frame"); errors++;
      end else begin
        if (phy.done_len != exp_len[checked]) begin
          $display("FAIL: frame %0d length %0d, expected %0d", checked, phy.done_len, exp_len[checked]);
          errors++;
        end else begin
          bad = -1;
          for (int i = 0; i < phy.done_len; i++)
            if (bad < 0 && phy.fbuf[i] !== pat(checked, i)) bad = i;
          if (bad >= 0) begin
            $display("FAIL: frame %0d byte %0d = %02x, expected %02x",
                     checked, bad, phy.fbuf[bad], pat(checked, bad));
            errors++;
          end
        end
        checked++;
      end
    end
  end

  // ---- stimulus ------------------------------------------------------------
  int dl [0:N_DIRECTED-1];
  initial begin
    dl[0]=64;  dl[1]=1;    dl[2]=31;   dl[3]=32;  dl[4]=33;
    dl[5]=239; dl[6]=240;  dl[7]=241;  dl[8]=480; dl[9]=481;
    dl[10]=1500; dl[11]=9000; dl[12]=240; dl[13]=720; dl[14]=7;
  end

  initial begin
    #0;
    for (int i = 0; i < N; i++) begin
      exp_len[i] = (i < N_DIRECTED) ? dl[i] : $urandom_range(2000, 1);
      exp_flits += (exp_len[i] + FLIT_PAYLOAD_B - 1) / FLIT_PAYLOAD_B;
    end

    eth_rst_n = 1'b0; pipe_rst_n = 1'b0;
    repeat (10) @(posedge pclk);
    eth_rst_n = 1'b1; pipe_rst_n = 1'b1;
    repeat (20) @(posedge eth_clk);

    for (int i = 0; i < N; i++) begin
      mac.gap_pct = (i < N/2) ? 0 : 40;
      mac.send_frame(i, exp_len[i]);
    end

    // drain
    fork
      begin wait (checked == N); end
      begin repeat (400000) @(posedge pclk); end
    join_any
    repeat (200) @(posedge pclk);

    if (checked != N)                 begin $display("FAIL: %0d/%0d frames received", checked, N); errors++; end
    if (phy.flits != exp_flits)       begin $display("FAIL: %0d flits, expected %0d", phy.flits, exp_flits); errors++; end
    if (phyc.errors != 0)             begin $display("FAIL: %0d PHY-ctrl error(s)", phyc.errors); errors++; end
    if (phyc.mb_writes != 1 || phyc.regs[MB_ADDR_PAM4_TXCTL] !== PAM4CFG_RST)
      begin $display("FAIL: expected one PAM4 msgbus write at link-up, saw %0d", phyc.mb_writes); errors++; end
    if (phy.errors != 0)              begin $display("FAIL: %0d PHY-model error(s)", phy.errors); errors++; end

    if (errors == 0)
      $display("TX PASS: %0d frames, %0d flits, all payloads match", N, phy.flits);
    else
      $display("TX FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TX FAIL: global timeout (%0d/%0d frames)", checked, N);
    $finish;
  end
endmodule
