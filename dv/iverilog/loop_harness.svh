// ============================================================================
// dv/iverilog/loop_harness.svh — shared loopback harness, `include'd inside a
// test module body (tb_pm, tb_rxovf).  Instantiates the bridge with PIPE Tx
// looped to PIPE Rx, the MAC source, PHY flit monitor, PHY control model and
// Ethernet sink, the two clocks, and CSR access tasks.
// Requires: `import eth_dj_pipe7_pkg::*;` and `include "eth_dj_pat.svh" before.
// ============================================================================
  logic eth_clk = 1'b0, pclk = 1'b0;
  logic eth_rst_n, pipe_rst_n;

  wire                     eth_tvalid, eth_tready, eth_tlast;
  wire [ETH_DATA_W-1:0]    eth_tdata;
  wire [ETH_KEEP_W-1:0]    eth_tkeep;
  wire [ETH_USER_W-1:0]    eth_tuser;
  wire [PIPE_BUS_W-1:0]    pipe_tx_data;
  wire                     pipe_tx_data_valid, pipe_tx_start_block;
  wire                     eth_rx_tvalid, eth_rx_tready, eth_rx_tlast;
  wire [ETH_DATA_W-1:0]    eth_rx_tdata;
  wire [ETH_KEEP_W-1:0]    eth_rx_tkeep;
  wire [ETH_USER_W-1:0]    eth_rx_tuser;
  pipe_pwr_e               pipe_powerdown;
  pipe_rate_e              pipe_rate;
  wire [1:0]               pipe_width;
  wire                     pipe_phy_status;
  wire [MSGBUS_W-1:0]      m2p, p2m;
  logic                    csr_valid = 1'b0, csr_write = 1'b0;
  logic [7:0]              csr_addr  = 8'h00;
  logic [31:0]             csr_wdata = 32'h0;
  wire  [31:0]             csr_rdata;

  eth_dj_pipe7_bridge dut (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n),
    .eth_tvalid(eth_tvalid), .eth_tready(eth_tready), .eth_tdata(eth_tdata),
    .eth_tkeep(eth_tkeep), .eth_tlast(eth_tlast), .eth_tuser(eth_tuser),
    .eth_rx_tvalid(eth_rx_tvalid), .eth_rx_tready(eth_rx_tready), .eth_rx_tdata(eth_rx_tdata),
    .eth_rx_tkeep(eth_rx_tkeep), .eth_rx_tlast(eth_rx_tlast), .eth_rx_tuser(eth_rx_tuser),
    .pclk(pclk), .pipe_rst_n(pipe_rst_n),
    .pipe_tx_data(pipe_tx_data), .pipe_tx_data_valid(pipe_tx_data_valid),
    .pipe_tx_start_block(pipe_tx_start_block),
    .pipe_rx_data(pipe_tx_data), .pipe_rx_data_valid(pipe_tx_data_valid),
    .pipe_rx_start_block(pipe_tx_start_block),
    .pipe_rate(pipe_rate), .pipe_width(pipe_width), .pipe_powerdown(pipe_powerdown),
    .pipe_phy_status(pipe_phy_status), .pipe_rx_valid(1'b0), .pipe_rx_elec_idle(1'b1),
    .pipe_m2p_msgbus(m2p), .pipe_p2m_msgbus(p2m),
    .csr_valid(csr_valid), .csr_write(csr_write), .csr_addr(csr_addr),
    .csr_wdata(csr_wdata), .csr_rdata(csr_rdata)
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

  pipe_phy_ctrl_model phyc (
    .pclk(pclk), .pipe_rst_n(pipe_rst_n), .powerdown(pipe_powerdown), .rate(pipe_rate),
    .width(pipe_width), .tx_data_valid(pipe_tx_data_valid), .m2p(m2p),
    .phy_status(pipe_phy_status), .p2m(p2m)
  );

  eth_sink_model sink (
    .eth_clk(eth_clk), .eth_rst_n(eth_rst_n), .eth_rx_tvalid(eth_rx_tvalid),
    .eth_rx_tready(eth_rx_tready), .eth_rx_tdata(eth_rx_tdata),
    .eth_rx_tkeep(eth_rx_tkeep), .eth_rx_tlast(eth_rx_tlast), .eth_rx_err(eth_rx_tuser[0])
  );

  always #2.5 eth_clk = ~eth_clk;   // 200 MHz
  always #1.0 pclk    = ~pclk;      // 500 MHz

  task automatic csr_wr(input logic [7:0] a, input logic [31:0] d);
    begin
      @(negedge pclk); csr_valid = 1'b1; csr_write = 1'b1; csr_addr = a; csr_wdata = d;
      @(negedge pclk); csr_valid = 1'b0; csr_write = 1'b0;
    end
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    begin
      @(negedge pclk); csr_addr = a; #0.1; d = csr_rdata;
    end
  endtask

  task automatic do_reset();
    begin
      eth_rst_n = 1'b0; pipe_rst_n = 1'b0;
      repeat (10) @(posedge pclk);
      eth_rst_n = 1'b1; pipe_rst_n = 1'b1;
    end
  endtask
