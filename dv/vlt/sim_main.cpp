// ============================================================================
// dv/vlt/sim_main.cpp — DV env 2: plain Verilator C++ harness + coverage vehicle.
//
// Drives Veth_dj_pipe7_bridge directly with the shared C++ BFMs
// (dv/common/cpp/bridge_bfm.h): PIPE Tx looped to PIPE Rx, PHY control model,
// CSR sequencer.  Runs the five cross-check scenarios plus two coverage-only
// scenarios, writes results.json, and (built with --coverage) coverage.dat.
// Plusargs: +trace (FST dump to logs/vlt.fst), +seed=N.
// Clocks: eth_clk 200 MHz (5 ns), pclk 500 MHz (2 ns); time unit = 1 ps.
// ============================================================================
#include <verilated.h>
#if VM_TRACE
#include <verilated_fst_c.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>

#include "Veth_dj_pipe7_bridge.h"
#include "bridge_bfm.h"

using bfm::EthIn;
using bfm::EthOut;
using bfm::PipeIn;
using bfm::PipeOut;

static EthOut sample_eth(const Veth_dj_pipe7_bridge* d) {
  EthOut o;
  o.tready = d->eth_tready;
  o.rx_tvalid = d->eth_rx_tvalid;
  for (int w = 0; w < 8; w++)
    for (int b = 0; b < 4; b++) o.rx_data[w * 4 + b] = uint8_t(d->eth_rx_tdata[w] >> (8 * b));
  o.rx_keep = d->eth_rx_tkeep;
  o.rx_tlast = d->eth_rx_tlast;
  o.rx_tuser = d->eth_rx_tuser;
  return o;
}

static void apply_eth(Veth_dj_pipe7_bridge* d, const EthIn& in) {
  d->eth_rst_n = in.rst_n;
  d->eth_tvalid = in.tvalid;
  for (int w = 0; w < 8; w++) {
    uint32_t v = 0;
    for (int b = 0; b < 4; b++) v |= uint32_t(in.data[w * 4 + b]) << (8 * b);
    d->eth_tdata[w] = v;
  }
  d->eth_tkeep = in.keep;
  d->eth_tlast = in.tlast;
  d->eth_tuser = 0;
  d->eth_rx_tready = in.rx_tready;
}

static PipeOut sample_pipe(const Veth_dj_pipe7_bridge* d) {
  PipeOut o;
  o.tx_valid = d->pipe_tx_data_valid;
  o.tx_sb = d->pipe_tx_start_block;
  o.powerdown = d->pipe_powerdown;
  o.rate = d->pipe_rate;
  o.width = d->pipe_width;
  o.m2p = d->pipe_m2p_msgbus;
  o.csr_rdata = d->csr_rdata;
  o.ctrl_state = -1;
  return o;
}

static void apply_pipe(Veth_dj_pipe7_bridge* d, const PipeIn& in) {
  d->pipe_rst_n = in.rst_n;
  d->pipe_phy_status = in.phy_status;
  d->pipe_p2m_msgbus = in.p2m;
  d->csr_valid = in.csr_valid;
  d->csr_write = in.csr_write;
  d->csr_addr = in.csr_addr;
  d->csr_wdata = in.csr_wdata;
  d->pipe_rx_valid = 0;
  d->pipe_rx_elec_idle = 1;
}

static void loopback(Veth_dj_pipe7_bridge* d) {
  d->pipe_rx_data = d->pipe_tx_data;
  d->pipe_rx_data_valid = d->pipe_tx_data_valid;
  d->pipe_rx_start_block = d->pipe_tx_start_block;
}

int main(int argc, char** argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  ctx->timeunit(-12);
  ctx->timeprecision(-12);
  auto dut = std::make_unique<Veth_dj_pipe7_bridge>(ctx.get(), "TOP");

  uint32_t seed = 12345;
  if (const char* s = ctx->commandArgsPlusMatch("seed=")) {
    if (*s) seed = uint32_t(strtoul(s + 6, nullptr, 0));
  }
  bfm::Harness h(seed);
  h.verbose = true;
  h.mac_gap_pct = 10;
  h.set_sink_default(90);

#if VM_TRACE
  std::unique_ptr<VerilatedFstC> tfp;
  const char* tr = ctx->commandArgsPlusMatch("trace");
  if (tr && *tr) {
    ctx->traceEverOn(true);
    tfp = std::make_unique<VerilatedFstC>();
    dut->trace(tfp.get(), 99);
    tfp->open("logs/vlt.fst");
  }
#endif

  dut->eth_clk = 0;
  dut->pclk = 0;
  apply_eth(dut.get(), EthIn());
  apply_pipe(dut.get(), PipeIn());
  loopback(dut.get());
  dut->eval();

  const uint64_t STEP = 500;                   // ps
  const uint64_t T_MAX = 200000000000ull;      // 200 ms sim-time guard
  uint64_t t = 0;
  while (!h.done && t < T_MAX && !ctx->gotFinish()) {
    t += STEP;
    bool eth_pos = (t % 5000) == 0, eth_neg = (t % 5000) == 2500;
    bool p_pos = (t % 2000) == 0, p_neg = (t % 2000) == 1000;
    if (!(eth_pos || eth_neg || p_pos || p_neg)) continue;
    ctx->time(t);
    EthOut eo;
    PipeOut po;
    if (eth_pos) eo = sample_eth(dut.get());   // values held before the edge
    if (p_pos) po = sample_pipe(dut.get());
    if (eth_pos) dut->eth_clk = 1;
    if (eth_neg) dut->eth_clk = 0;
    if (p_pos) dut->pclk = 1;
    if (p_neg) dut->pclk = 0;
    dut->eval();
    if (eth_pos) apply_eth(dut.get(), h.eth_edge(eo));
    if (p_pos) apply_pipe(dut.get(), h.pclk_edge(po));
    loopback(dut.get());
    dut->eval();
#if VM_TRACE
    if (tfp) tfp->dump(t);
#endif
  }
  dut->final();
#if VM_TRACE
  if (tfp) tfp->close();
#endif
#if VM_COVERAGE
  ctx->coveragep()->write("logs/coverage.dat");
#endif

  bool ok = h.done && h.total_errors == 0;
  h.write_json("logs/results.json", "vlt");
  if (!h.done) printf("VLT FAIL: simulation guard reached before all scenarios finished\n");
  printf("%s: %zu scenarios, %d error(s), sim time %.1f us\n", ok ? "VLT PASS" : "VLT FAIL",
         h.results.size(), h.total_errors, double(t) / 1e6);
  return ok ? 0 : 1;
}
