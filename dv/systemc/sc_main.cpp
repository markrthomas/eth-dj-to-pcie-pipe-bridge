// ============================================================================
// dv/systemc/sc_main.cpp — DV env 4: Verilator --sc model of the bridge inside a
// SystemC testbench.  sc_clocks drive eth_clk (5 ns) and pclk (2 ns); a Tb
// SC_MODULE samples DUT outputs at each rising edge (sc_signal reads return the
// pre-edge values) and writes DUT inputs, which take effect after the edge.  The
// scenario/BFM logic is the shared C++ harness (dv/common/cpp/bridge_bfm.h), so
// this env cross-checks the SystemC kernel scheduling against the vlt env.
// PIPE Tx is looped to PIPE Rx by binding both ports to the same sc_signals.
// ============================================================================
#include <systemc.h>
#include <verilated.h>

#include <cstdio>
#include <memory>

#include "Veth_dj_pipe7_bridge.h"
#include "bridge_bfm.h"

SC_MODULE(Tb) {
  sc_in<bool> eth_clk, pclk;
  // eth domain
  sc_signal<bool> eth_rst_n, eth_tvalid, eth_tready, eth_tlast, eth_rx_tvalid, eth_rx_tready, eth_rx_tlast;
  sc_signal<sc_bv<256>> eth_tdata, eth_rx_tdata;
  sc_signal<uint32_t> eth_tkeep, eth_tuser, eth_rx_tkeep, eth_rx_tuser;
  // pipe domain
  sc_signal<bool> pipe_rst_n, pipe_tx_data_valid, pipe_tx_start_block, pipe_phy_status,
      pipe_rx_valid, pipe_rx_elec_idle, csr_valid, csr_write;
  sc_signal<uint64_t> pipe_tx_data;
  sc_signal<uint32_t> pipe_rate, pipe_width, pipe_powerdown, pipe_m2p_cmd, pipe_m2p_data, pipe_p2m_cmd,
      pipe_p2m_data, csr_addr, csr_wdata, csr_rdata;

  bfm::Harness h;

  void eth_pos() {
    bfm::EthOut o;
    o.tready = eth_tready.read();
    o.rx_tvalid = eth_rx_tvalid.read();
    sc_bv<256> rd = eth_rx_tdata.read();
    for (int i = 0; i < 32; i++) o.rx_data[i] = uint8_t(rd.range(8 * i + 7, 8 * i).to_uint());
    o.rx_keep = eth_rx_tkeep.read();
    o.rx_tlast = eth_rx_tlast.read();
    o.rx_tuser = uint8_t(eth_rx_tuser.read());
    bfm::EthIn in = h.eth_edge(o);
    eth_rst_n.write(in.rst_n);
    eth_tvalid.write(in.tvalid);
    sc_bv<256> td;
    for (int i = 0; i < 32; i++) td.range(8 * i + 7, 8 * i) = in.data[i];
    eth_tdata.write(td);
    eth_tkeep.write(in.keep);
    eth_tlast.write(in.tlast);
    eth_rx_tready.write(in.rx_tready);
  }

  void pclk_pos() {
    bfm::PipeOut o;
    o.tx_valid = pipe_tx_data_valid.read();
    o.tx_sb = pipe_tx_start_block.read();
    o.powerdown = int(pipe_powerdown.read());
    o.rate = int(pipe_rate.read());
    o.width = int(pipe_width.read());
    o.m2p_cmd = int(pipe_m2p_cmd.read());
    o.m2p_data = int(pipe_m2p_data.read());
    o.csr_rdata = csr_rdata.read();
    o.ctrl_state = -1;
    bfm::PipeIn in = h.pclk_edge(o);
    pipe_rst_n.write(in.rst_n);
    pipe_phy_status.write(in.phy_status);
    pipe_p2m_cmd.write(uint32_t(in.p2m_cmd));
    pipe_p2m_data.write(uint32_t(in.p2m_data));
    csr_valid.write(in.csr_valid);
    csr_write.write(in.csr_write);
    csr_addr.write(uint32_t(in.csr_addr));
    csr_wdata.write(in.csr_wdata);
    if (h.done) sc_stop();
  }

  SC_CTOR(Tb) : h(12345) {
    SC_METHOD(eth_pos);
    sensitive << eth_clk.pos();
    dont_initialize();
    SC_METHOD(pclk_pos);
    sensitive << pclk.pos();
    dont_initialize();
    pipe_phy_status.write(true);
    pipe_rx_elec_idle.write(true);
  }
};

int sc_main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  sc_clock eth_clk("eth_clk", 5, SC_NS, 0.5, 0, SC_NS, true);
  sc_clock pclk("pclk", 2, SC_NS, 0.5, 0, SC_NS, true);

  Tb tb("tb");
  tb.eth_clk(eth_clk);
  tb.pclk(pclk);
  tb.h.verbose = true;
  tb.h.mac_gap_pct = 10;
  tb.h.set_sink_default(90);

  auto dut = std::make_unique<Veth_dj_pipe7_bridge>("dut");
  dut->eth_clk(eth_clk);
  dut->eth_rst_n(tb.eth_rst_n);
  dut->eth_tvalid(tb.eth_tvalid);
  dut->eth_tready(tb.eth_tready);
  dut->eth_tdata(tb.eth_tdata);
  dut->eth_tkeep(tb.eth_tkeep);
  dut->eth_tlast(tb.eth_tlast);
  dut->eth_tuser(tb.eth_tuser);
  dut->eth_rx_tvalid(tb.eth_rx_tvalid);
  dut->eth_rx_tready(tb.eth_rx_tready);
  dut->eth_rx_tdata(tb.eth_rx_tdata);
  dut->eth_rx_tkeep(tb.eth_rx_tkeep);
  dut->eth_rx_tlast(tb.eth_rx_tlast);
  dut->eth_rx_tuser(tb.eth_rx_tuser);
  dut->pclk(pclk);
  dut->pipe_rst_n(tb.pipe_rst_n);
  dut->pipe_tx_data(tb.pipe_tx_data);
  dut->pipe_tx_data_valid(tb.pipe_tx_data_valid);
  dut->pipe_tx_start_block(tb.pipe_tx_start_block);
  dut->pipe_rx_data(tb.pipe_tx_data);                 // loopback
  dut->pipe_rx_data_valid(tb.pipe_tx_data_valid);
  dut->pipe_rx_start_block(tb.pipe_tx_start_block);
  dut->pipe_rate(tb.pipe_rate);
  dut->pipe_width(tb.pipe_width);
  dut->pipe_powerdown(tb.pipe_powerdown);
  dut->pipe_phy_status(tb.pipe_phy_status);
  dut->pipe_rx_valid(tb.pipe_rx_valid);
  dut->pipe_rx_elec_idle(tb.pipe_rx_elec_idle);
  dut->pipe_m2p_cmd(tb.pipe_m2p_cmd);
  dut->pipe_m2p_data(tb.pipe_m2p_data);
  dut->pipe_p2m_cmd(tb.pipe_p2m_cmd);
  dut->pipe_p2m_data(tb.pipe_p2m_data);
  dut->csr_valid(tb.csr_valid);
  dut->csr_write(tb.csr_write);
  dut->csr_addr(tb.csr_addr);
  dut->csr_wdata(tb.csr_wdata);
  dut->csr_rdata(tb.csr_rdata);

  sc_start(200, SC_MS);   // guard; the Tb calls sc_stop() when all scenarios are done
  dut->final();

  bool ok = tb.h.done && tb.h.total_errors == 0;
  tb.h.write_json("logs/results.json", "systemc");
  printf("%s: %zu scenarios, %d error(s), sim time %s\n", ok ? "SYSTEMC PASS" : "SYSTEMC FAIL",
         tb.h.results.size(), tb.h.total_errors, sc_time_stamp().to_string().c_str());
  return ok ? 0 : 1;
}
