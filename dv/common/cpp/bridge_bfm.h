// ============================================================================
// bridge_bfm.h — simulator-independent C++ BFMs + scenario runner for the
// eth_dj_pipe7_bridge loopback harness.  Used by dv/vlt (plain Verilator C++)
// and dv/systemc (Verilator --sc).  The glue code in each env copies DUT
// outputs into EthOut/PipeOut *as sampled just before a rising edge*, calls
// eth_edge()/pclk_edge(), and applies the returned EthIn/PipeIn after the edge
// (i.e. testbench drives behave like nonblocking assignments).
//
// The five cross-check scenarios mirror dv/common/scenarios.py exactly; two extra
// coverage-only scenarios (pm_full, rxovf) exercise the rest of the control plane
// and the Rx overload policy and are not part of the cross-check.
// ============================================================================
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace bfm {

constexpr int ETH_BYTES = 32;          // ETH_DATA_W / 8
constexpr int FLIT_PAYLOAD_B = 240;
constexpr int FLIT_BYTES = 256, FLIT_BEATS = 32, FLIT_HDR_B = 2, FLIT_FC_OFF = 242;
// Link flow control (docs/OPEN_DECISIONS.md D16): build with -DFLOW_CTRL_OVERRIDE.
#ifdef FLOW_CTRL_OVERRIDE
constexpr bool FLOW_CTRL = true;
#else
constexpr bool FLOW_CTRL = false;
#endif
// pkg constants (eth_dj_pipe7_pkg.sv)
constexpr int PWR_P0 = 0, PWR_P0S = 1, PWR_P1 = 2, PWR_P2 = 3;
constexpr int RATE_GEN5 = 4, RATE_GEN6 = 5;
constexpr int ST_ACTIVE = 2;
constexpr int MB_NOP = 0, MB_WR_UC = 1, MB_WR_C = 2, MB_RD = 3, MB_RD_CPL = 4, MB_WR_ACK = 5;
constexpr int MB_ADDR_W = 12;
constexpr int MB_ADDR_TX_PRESET = 0x405;
constexpr int CSR_CTRL = 0x00, CSR_PAM4CFG = 0x04, CSR_STATUS = 0x08, CSR_ERR = 0x0C,
              CSR_RXCNT0 = 0x10, CSR_RXCNT1 = 0x14, CSR_PMCNT = 0x18;

inline uint8_t pat(int id, int idx) { return uint8_t(id * 37 + idx * 13 + (idx >> 8) + 5); }

inline uint32_t crc32_byte(uint32_t c, uint8_t b) {
  c ^= b;
  for (int k = 0; k < 8; k++) c = (c & 1) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
  return c;
}

// deterministic xorshift for gaps/throttling (not part of the scenario contract)
struct Rng {
  uint32_t s;
  explicit Rng(uint32_t seed) : s(seed ? seed : 1) {}
  uint32_t next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
  bool pct(int p) { return int(next() % 100) < p; }
};

// ---- port bundles -----------------------------------------------------------
struct EthOut {                  // DUT outputs, eth_clk domain
  bool tready = false;
  bool rx_tvalid = false;
  uint8_t rx_data[ETH_BYTES] = {};
  uint32_t rx_keep = 0;
  bool rx_tlast = false;
  uint8_t rx_tuser = 0;
};
struct EthIn {                   // DUT inputs, eth_clk domain
  bool rst_n = false;
  bool tvalid = false;
  uint8_t data[ETH_BYTES] = {};
  uint32_t keep = 0;
  bool tlast = false;
  bool rx_tready = false;
};
struct PipeOut {                 // DUT outputs, pclk domain
  bool tx_valid = false, tx_sb = false;
  uint64_t tx_data = 0;          // pipe_tx_data (64-bit x1 bus)
  int powerdown = 0, rate = 0, width = 0;
  int m2p = 0;                   // pipe_m2p_msgbus byte
  uint32_t csr_rdata = 0;
  int ctrl_state = 0;            // optional (hierarchical peek); -1 if unavailable
};
struct PipeIn {                  // DUT inputs, pclk domain
  bool rst_n = false;
  bool phy_status = true;
  int p2m = 0;                   // pipe_p2m_msgbus byte
  bool csr_valid = false, csr_write = false;
  int csr_addr = 0;
  uint32_t csr_wdata = 0;
};

struct ScenResult {
  std::string name;
  int frames = 0;
  long bytes = 0;
  int flits = 0;
  uint32_t crc = 0;
  uint32_t pmcnt = 0;
  int errors = 0;
  bool crosscheck = true;
  // extra (coverage scenarios)
  int err_frames = 0;
};

// ---- the harness: all models + scenario sequencer ------------------------------
class Harness {
 public:
  explicit Harness(uint32_t seed = 12345) : rng_(seed) {}

  // ---- configuration
  int mac_gap_pct = 10;
  int sink_ready_pct = 90;
  bool verbose = false;
  std::vector<ScenResult> results;
  bool done = false;
  int total_errors = 0;

  // ---------------------------------------------------------------- eth_clk
  EthIn eth_edge(const EthOut& o) {
    EthIn in = eth_in_;
    in.rst_n = rst_n_;
    // MAC source: a beat is accepted when tvalid && tready held before the edge
    if (mac_valid_ && o.tready) {
      mac_off_ += mac_n_;
      mac_valid_ = false;
      if (mac_off_ >= cur_len_) { mac_q_.pop_front(); mac_off_ = 0; }
    }
    if (!rst_n_) { mac_q_.clear(); mac_off_ = 0; mac_valid_ = false; }
    if (!mac_valid_ && !mac_q_.empty() && !rng_.pct(mac_gap_pct)) {
      int id = mac_q_.front();
      cur_len_ = len_of_(id);
      int n = cur_len_ - mac_off_;
      if (n > ETH_BYTES) n = ETH_BYTES;
      memset(in.data, 0, sizeof in.data);
      for (int i = 0; i < n; i++) in.data[i] = pat(id, mac_off_ + i);
      in.keep = (n == 32) ? 0xFFFFFFFFu : ((1u << n) - 1);
      in.tlast = (mac_off_ + n == cur_len_);
      mac_n_ = n;
      mac_valid_ = true;
    }
    in.tvalid = mac_valid_;

    // Ethernet sink: accept on tvalid && tready (both as held before the edge)
    if (rst_n_ && o.rx_tvalid && eth_in_.rx_tready) sink_beat_(o);
    in.rx_tready = rst_n_ && rng_.pct(sink_ready_pct);
    eth_in_ = in;
    return in;
  }

  // ---------------------------------------------------------------- pclk
  PipeIn pclk_edge(const PipeOut& o) {
    PipeIn in = pipe_in_;
    // flit monitor (Tx side)
    if (!rst_n_) flit_reset_();
    else flit_beat_(o);
    phy_ctrl_(o, in);
    csr_rdata_ = o.csr_rdata;
    sequencer_(o, in);
    in.rst_n = rst_n_;
    pipe_in_ = in;
    return in;
  }

 public:
  // FLOW_CTRL run summary: credit-only flits must have been seen, else FC was not exercised.
  void fc_summary() {
    if (!FLOW_CTRL) return;
    printf("FC credit-only flits=%d last_cl=%u\n", cr_flits_, last_cl_);
    if (cr_flits_ == 0) err_("flow control on but no credit-only flit seen (FC not exercised)");
  }
 private:
  // ---- Tx flit monitor + checker (mirror of dv/common/pipe_phy_model.sv) ----
  // Checks every flit: contiguous 32 beats, start_block only on beat 0, header valid bit,
  // reserved bits, payload length, sof/eof sequencing, zero padding.  With FLOW_CTRL the
  // DLP bytes FLIT_FC_OFF..+3 carry seq/cl and are exempt from the zero check; a flit with
  // count 0, sof = eof = 0 is a legal credit-only flit (cr_flits_, not counted in flits_);
  // seq must equal the data flits sent since reset.
  void flit_reset_() { fbeat_ = 0; fc_sent_ = 0; fin_frame_ = false; }
  void flit_beat_(const PipeOut& o) {
    if (o.tx_sb && !o.tx_valid) err_("start_block without data_valid");
    if (o.tx_valid) {
      if (o.tx_sb && fbeat_ != 0) err_("start_block mid-flit");
      if (!o.tx_sb && fbeat_ == 0) err_("flit beat 0 without start_block");
      for (int b = 0; b < 8; b++) fl_[fbeat_ * 8 + b] = uint8_t(o.tx_data >> (8 * b));
      if (fbeat_ == FLIT_BEATS - 1) { fbeat_ = 0; flit_done_(); } else fbeat_++;
    } else if (fbeat_ != 0) { err_("data_valid dropped mid-flit"); fbeat_ = 0; }
  }
  void flit_done_() {
    bool hv = fl_[0] & 1, hsof = (fl_[0] >> 1) & 1, heof = (fl_[0] >> 2) & 1;
    int plen = fl_[1];
    if (!hv) err_("header valid bit clear");
    if (fl_[0] >> 3) err_("header reserved bits nonzero");
    if (plen > FLIT_PAYLOAD_B) err_("payload length > 240");
    bool cr = FLOW_CTRL && plen == 0 && !hsof && !heof;
    if (plen == 0 && !cr) err_("empty flit emitted");
    if (!cr && hsof == fin_frame_) err_("sof/frame state mismatch");
    bool padbad = false;
    for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
      if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl_[b] != 0) padbad = true;
    if (padbad) err_("nonzero padding/DLP/FEC byte");
    if (FLOW_CTRL) {
      unsigned seq = fl_[FLIT_FC_OFF] | (fl_[FLIT_FC_OFF + 1] << 8);
      last_cl_ = fl_[FLIT_FC_OFF + 2] | (fl_[FLIT_FC_OFF + 3] << 8);
      if (seq != (fc_sent_ & 0xFFFFu)) err_("flow-control seq field != data flits sent before");
    }
    if (cr) cr_flits_++; else { flits_++; fc_sent_++; fin_frame_ = !heof; }
  }
  uint8_t fl_[FLIT_BYTES] = {};
  int fbeat_ = 0;
  unsigned fc_sent_ = 0;
  bool fin_frame_ = false;
 public:
  int cr_flits_ = 0;                 // credit-only flits seen (FLOW_CTRL)
  unsigned last_cl_ = 0;
 private:
  // ---- scenario definition (mirror of dv/common/scenarios.py) ---------------
  static constexpr int N_SCEN = 7;   // 5 cross-check + pm_full + rxovf
  static const char* scen_name_(int s) {
    static const char* n[] = {"single", "corners", "random", "pm_cycle", "rate_change",
                              "pm_full", "rxovf"};
    return n[s];
  }
  static int scen_nframes_(int s) {
    static const int n[] = {1, 11, 40, 16, 16, 16, 60};
    return n[s];
  }
  static int scen_len_(int s, int i) {
    static const int corners[] = {1, 31, 32, 33, 239, 240, 241, 480, 481, 1500, 9000};
    if (s == 0) return 64;
    if (s == 1) return corners[i];
    uint64_t seed = (s == 2) ? 0xC0FFEE : (s == 3) ? 7 : (s == 4) ? 11 : (s == 5) ? 13 : 17;
    uint64_t x = seed & 0x7FFFFFFF;
    for (int k = 0; k <= i; k++) x = (1103515245ull * x + 12345ull) & 0x7FFFFFFF;
    int len = 1 + int((x >> 8) % 2000);
    if (s == 6 && len < 60) len += 60;
    return len;
  }
  int len_of_(int id) const { return scen_len_(scen_, id); }

  // ---- sink / scoreboard ------------------------------------------------------
  void sink_beat_(const EthOut& o) {
    int nb = 0;
    bool kbad = false;
    for (int i = 0; i < ETH_BYTES; i++) {
      if ((o.rx_keep >> i) & 1) {
        nb++;
        if (i > 0 && !((o.rx_keep >> (i - 1)) & 1)) kbad = true;
      }
    }
    if (nb == 0 || (!o.rx_tlast && nb != ETH_BYTES)) kbad = true;
    if ((o.rx_tuser & 1) && !o.rx_tlast) kbad = true;
    if (kbad) err_("sink: illegal tkeep/tuser");
    for (int i = 0; i < nb; i++) fbuf_.push_back(o.rx_data[i]);
    if (!o.rx_tlast) return;
    bool aborted = o.rx_tuser & 1;
    if (scen_ == 6) {                         // rxovf: flagged or exact match, in order
      if (aborted) { res_.err_frames++; if (FLOW_CTRL) err_("rxovf: frame aborted although credit flow control is on"); }
      else {
        int match = -1;
        for (int k = rx_next_; k < scen_nframes_(scen_) && match < 0; k++) {
          if (int(fbuf_.size()) != len_of_(k)) continue;
          bool ok = true;
          for (size_t i = 0; i < fbuf_.size() && ok; i++) ok = fbuf_[i] == pat(k, int(i));
          if (ok) match = k;
        }
        if (match < 0) err_("rxovf: unflagged frame matches no sent frame");
        else rx_next_ = match + 1;
      }
    } else {
      int id = res_.frames;
      if (aborted) err_("frame aborted");
      if (id >= scen_nframes_(scen_) || int(fbuf_.size()) != len_of_(id)) err_("frame length");
      else
        for (size_t i = 0; i < fbuf_.size(); i++)
          if (fbuf_[i] != pat(id, int(i))) { err_("frame payload"); break; }
    }
    for (uint8_t b : fbuf_) crc_ = crc32_byte(crc_, b);
    res_.bytes += long(fbuf_.size());
    res_.frames++;
    fbuf_.clear();
  }

  // ---- PHY control model (PhyStatus, msgbus target, Tx legality) -----------------
  void phy_ctrl_(const PipeOut& o, PipeIn& in) {
    if (!rst_n_) {
      in.phy_status = true; in.p2m = 0;
      rst_cnt_ = 0; st_cnt_ = 0; ack_cnt_ = 0; mb_ph_ = 0; p2m_q_.clear();
      pd_q_ = o.powerdown; rate_q_ = o.rate; width_q_ = o.width;
      return;
    }
    bool change = o.powerdown != pd_q_ || o.rate != rate_q_ || o.width != width_q_;
    if (o.tx_valid && (o.powerdown != PWR_P0 || st_cnt_ != 0 || change))
      err_("phy: Tx data_valid outside P0 or during a pin change");
    in.phy_status = false;
    if (rst_cnt_ < 16) { rst_cnt_++; in.phy_status = true; }
    else if (change) { st_cnt_ = 8; }
    else if (st_cnt_ == 1) { st_cnt_ = 0; in.phy_status = !mute_status_; }
    else if (st_cnt_ > 1) { st_cnt_--; }
    pd_q_ = o.powerdown; rate_q_ = o.rate; width_q_ = o.width;

    // byte-serial msgbus target: {MB_WR_C, addr[11:8]}, addr[7:0], data[7:0]; idle = 0x00
    in.p2m = 0;
    if (mb_ph_ == 1) {
      mb_addr_ = (mb_addr_ & 0xF00) | (o.m2p & 0xFF); mb_ph_ = 2;
    } else if (mb_ph_ == 2) {
      mb_last_addr_ = mb_addr_; mb_last_data_ = o.m2p & 0xFF; mb_writes_++; mb_ph_ = 0; ack_cnt_ = 8;
    } else if (mb_ph_ == 3) {                      // MAC read_completion data byte
      mb_rd_data_ = o.m2p & 0xFF; mb_rds_++; mb_ph_ = 0;
    } else if (o.m2p != 0) {
      int cmd = (o.m2p >> 4) & 0xF;
      if (cmd == MB_WR_C) {
        mb_addr_ = (o.m2p & 0xF) << 8; mb_ph_ = 1;
      } else if (cmd == MB_WR_ACK) {               // MAC acknowledges a PHY-initiated write
        mb_acks_++;
      } else if (cmd == MB_RD_CPL) {               // MAC answers a PHY-initiated read
        mb_ph_ = 3;
      } else {
        err_("phy: unsupported message-bus command");
      }
    }
    if (ack_cnt_ == 1) { ack_cnt_ = 0; in.p2m = MB_WR_ACK << 4; }
    else if (ack_cnt_ > 1) ack_cnt_--;
    // PHY-initiated transactions (MAC register file, PIPE 7.1 6.1.4 / 7.2): one byte per pclk, only
    // started at quiet points of the scenario (no own write / ack outstanding), so never split
    if (in.p2m == 0 && !p2m_q_.empty()) { in.p2m = p2m_q_.front(); p2m_q_.pop_front(); }
  }

  // ---- sequencer -------------------------------------------------------------------
  enum Phase { P_RESET, P_WAIT_UP, P_RUN, P_FINISH, P_DONE };
  // op list executed one per step; each op is a small program
  enum OpKind { OP_SEND, OP_WAIT_RX, OP_CSR_WR, OP_WAIT_ST, OP_IDLE, OP_SINK, OP_MUTE,
                OP_EXPECT_ERR, OP_WAIT_MB, OP_PHY_WR, OP_PHY_RD };
  struct Op { OpKind k; int a, b, c; };

  void build_ops_() {
    ops_.clear();
    int n = scen_nframes_(scen_);
    auto ctrl = [](int pd, int rt, int wd) { return (wd << 5) | (rt << 2) | pd; };
    auto set = [&](int pd, int rt, int wd) {
      ops_.push_back({OP_CSR_WR, CSR_CTRL, ctrl(pd, rt, wd), 0});
      ops_.push_back({OP_WAIT_ST, pd, rt, wd});
    };
    if (scen_ <= 2) {
      ops_.push_back({OP_SEND, 0, n, 0});
    } else if (scen_ == 3 || scen_ == 4) {
      ops_.push_back({OP_SEND, 0, n / 2, 0});
      ops_.push_back({OP_WAIT_RX, n / 2, 0, 0});
      if (scen_ == 3) { set(PWR_P1, RATE_GEN6, 0); ops_.push_back({OP_IDLE, 200, 0, 0}); set(PWR_P0, RATE_GEN6, 0); }
      else            { set(PWR_P0, RATE_GEN5, 0); ops_.push_back({OP_IDLE, 200, 0, 0}); set(PWR_P0, RATE_GEN6, 0); }
      ops_.push_back({OP_SEND, n / 2, n, 0});
    } else if (scen_ == 5) {                  // pm_full (coverage)
      ops_.push_back({OP_SEND, 0, 4, 0});
      ops_.push_back({OP_WAIT_RX, 4, 0, 0});
      set(PWR_P1, RATE_GEN6, 0); set(PWR_P2, RATE_GEN6, 0); set(PWR_P0, RATE_GEN6, 0);
      set(PWR_P0, RATE_GEN6, 1); set(PWR_P0, RATE_GEN6, 0);
      ops_.push_back({OP_CSR_WR, CSR_PAM4CFG, 0x35, 0});
      ops_.push_back({OP_WAIT_MB, 0x35, 0, 0});
      ops_.push_back({OP_SEND, 4, 8, 0});
      // PHY-initiated MAC register accesses (msgbus_mac_tgt: PIPE 7.1 7.2 register file)
      ops_.push_back({OP_IDLE, 60, 0, 0});
      ops_.push_back({OP_PHY_RD, 0x005, 0, 0x00});                   // reset value
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x005, 0x03});
      ops_.push_back({OP_PHY_RD, 0x005, 0, 0x03});
      ops_.push_back({OP_PHY_WR, MB_WR_UC, 0x400, 0x11});            // atomic group: 2 uncommitted + commit
      ops_.push_back({OP_PHY_WR, MB_WR_UC, 0x401, 0x22});
      ops_.push_back({OP_PHY_RD, 0x400, 0, 0x00});                   // not visible before the commit
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x402, 0x44});
      ops_.push_back({OP_PHY_RD, 0x400, 0, 0x11});
      ops_.push_back({OP_PHY_RD, 0x401, 0, 0x22});
      ops_.push_back({OP_PHY_RD, 0x402, 0, 0x44});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x008, 0xFF});             // reserved: ignored
      ops_.push_back({OP_PHY_RD, 0x008, 0, 0x00});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x40D, 0xFF});
      ops_.push_back({OP_PHY_RD, 0x40D, 0, 0x00});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0xC00, 0xFF});             // vendor window
      ops_.push_back({OP_PHY_RD, 0xC00, 0, 0x00});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x205, 0x02});             // RX2 window is separate storage
      ops_.push_back({OP_PHY_RD, 0x205, 0, 0x02});
      ops_.push_back({OP_PHY_RD, 0x005, 0, 0x03});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x800, 0x01});
      ops_.push_back({OP_PHY_RD, 0x800, 0, 0x01});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x40C, 0xA5});
      ops_.push_back({OP_PHY_RD, 0x40C, 0, 0xA5});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x010, 0x5A});
      ops_.push_back({OP_PHY_RD, 0x010, 0, 0x5A});
      for (int k = 0; k < 9; k++)                                    // 9th uncommitted write overflows the buffer
        ops_.push_back({OP_PHY_WR, MB_WR_UC, 0x403 + k, 0x80 + k});
      ops_.push_back({OP_PHY_WR, MB_WR_C, 0x40C, 0x5B});
      ops_.push_back({OP_PHY_RD, 0x40A, 0, 0x87});
      ops_.push_back({OP_PHY_RD, 0x40B, 0, 0x00});                   // the dropped entry
      ops_.push_back({OP_CSR_WR, CSR_CTRL, ctrl(PWR_P0S, RATE_GEN6, 0), 0});
      ops_.push_back({OP_IDLE, 50, 0, 0});
      ops_.push_back({OP_EXPECT_ERR, 0x4, 0, 0});
      set(PWR_P0, RATE_GEN6, 0);
      ops_.push_back({OP_CSR_WR, CSR_ERR, 0x4, 0});
      ops_.push_back({OP_MUTE, 1, 0, 0});
      set(PWR_P0, RATE_GEN5, 0);
      ops_.push_back({OP_MUTE, 0, 0, 0});
      ops_.push_back({OP_EXPECT_ERR, 0x1, 0, 0});
      ops_.push_back({OP_CSR_WR, CSR_ERR, 0x1, 0});
      set(PWR_P0, RATE_GEN6, 0);
      ops_.push_back({OP_SEND, 8, n, 0});
    } else {                                  // rxovf (coverage)
      ops_.push_back({OP_SINK, 4, 0, 0});
      ops_.push_back({OP_SEND, 0, n, 0});
      ops_.push_back({OP_IDLE, 60000, 0, 0});
      ops_.push_back({OP_SINK, 100, 0, 0});
      ops_.push_back({OP_IDLE, 20000, 0, 0});
    }
    if (scen_ != 6) ops_.push_back({OP_WAIT_RX, n, 0, 0});
    ops_.push_back({OP_IDLE, 200, 0, 0});
  }

  // one CSR access per pclk: write = 1 cycle valid; read = set addr, sample next edge
  void sequencer_(const PipeOut& o, PipeIn& in) {
    in.csr_valid = false; in.csr_write = false;
    switch (phase_) {
      case P_RESET:
        if (rst_hold_ == 0) {
          res_ = ScenResult(); res_.name = scen_name_(scen_); res_.crosscheck = scen_ < 5;
          crc_ = 0xFFFFFFFFu; flits_base_ = flits_; rx_next_ = 0; fbuf_.clear(); err_base_ = total_errors;
          mb_writes_ = 0; mute_status_ = false; sink_ready_pct = sink_ready_default_;
          rst_n_ = false;
        }
        if (++rst_hold_ >= 10) { rst_n_ = true; rst_hold_ = 0; phase_ = P_WAIT_UP; tmo_ = 0; }
        break;
      case P_WAIT_UP:
        in.csr_addr = CSR_STATUS;
        if (((csr_rdata_ >> 11) & 1) && pipe_in_.csr_addr == CSR_STATUS) {
          build_ops_(); op_i_ = 0; op_t_ = 0; phase_ = P_RUN;
        } else if (++tmo_ > 20000) { err_("link-up timeout"); phase_ = P_FINISH; }
        break;
      case P_RUN:
        if (op_i_ >= ops_.size()) { phase_ = P_FINISH; op_t_ = 0; break; }
        if (step_op_(ops_[op_i_], in)) { op_i_++; op_t_ = 0; } else if (++op_t_ > 400000) {
          err_("scenario op timeout"); op_i_ = ops_.size();
        }
        break;
      case P_FINISH:
        in.csr_addr = CSR_PMCNT;
        if (op_t_++ >= 2) {
          res_.pmcnt = csr_rdata_;
          res_.flits = flits_ - flits_base_;
          res_.crc = ~crc_;
          // FLOW_CTRL: credits must make the same stimulus lossless (no abort, all frames good)
          if (scen_ == 6 && FLOW_CTRL && res_.frames != scen_nframes_(6)) err_("rxovf: credit flow control lost frames");
          if (scen_ == 6 && !FLOW_CTRL && res_.err_frames == 0) err_("rxovf: no frame was aborted (overload not exercised)");
          res_.errors = total_errors - err_base_;
          results.push_back(res_);
          if (verbose)
            printf("SCEN %-11s frames=%d bytes=%ld flits=%d crc32=%08x pmcnt=%u errors=%d%s\n",
                   res_.name.c_str(), res_.frames, res_.bytes, res_.flits, res_.crc, res_.pmcnt,
                   res_.errors, res_.crosscheck ? "" : "  (coverage-only)");
          if (++scen_ >= N_SCEN) { phase_ = P_DONE; done = true; }
          else phase_ = P_RESET;
        }
        break;
      case P_DONE: break;
    }
    (void)o;
  }

  bool step_op_(const Op& op, PipeIn& in) {
    switch (op.k) {
      case OP_SEND:
        for (int i = op.a; i < op.b; i++) mac_q_.push_back(i);
        return true;
      case OP_WAIT_RX: return res_.frames >= op.a;
      case OP_CSR_WR:
        in.csr_valid = true; in.csr_write = true; in.csr_addr = op.a; in.csr_wdata = uint32_t(op.b);
        return true;
      case OP_WAIT_ST: {
        in.csr_addr = CSR_STATUS;
        uint32_t d = csr_rdata_;
        return pipe_in_.csr_addr == CSR_STATUS && op_t_ > 2 && int(d & 3) == op.a &&
               int((d >> 2) & 7) == op.b && int((d >> 5) & 3) == op.c && !((d >> 10) & 1);
      }
      case OP_IDLE: return op_t_ >= op.a;
      case OP_SINK: sink_ready_pct = op.a; return true;
      case OP_MUTE: mute_status_ = op.a != 0; return true;
      case OP_WAIT_MB: return mb_writes_ >= 2 && mb_last_data_ == op.a && mb_last_addr_ == MB_ADDR_TX_PRESET;
      case OP_PHY_WR:                              // a = cmd, b = addr, c = data
        if (op_t_ == 0) {
          ack_base_ = mb_acks_;
          p2m_q_.push_back((op.a << 4) | ((op.b >> 8) & 0xF)); p2m_q_.push_back(op.b & 0xFF); p2m_q_.push_back(op.c & 0xFF);
        }
        return p2m_q_.empty() && (op.a == MB_WR_UC || mb_acks_ > ack_base_);
      case OP_PHY_RD:                              // a = addr, c = expected data (-1: no check)
        if (op_t_ == 0) {
          rd_base_ = mb_rds_;
          p2m_q_.push_back((MB_RD << 4) | ((op.a >> 8) & 0xF)); p2m_q_.push_back(op.a & 0xFF);
        }
        if (p2m_q_.empty() && mb_rds_ > rd_base_) {
          if (op.c >= 0 && mb_rd_data_ != op.c) err_("MAC register read-back mismatch");
          return true;
        }
        return false;
      case OP_EXPECT_ERR:
        in.csr_addr = CSR_ERR;
        if (pipe_in_.csr_addr == CSR_ERR && op_t_ > 2) {
          if ((csr_rdata_ & uint32_t(op.a)) != uint32_t(op.a)) err_("expected ERR bit not set");
          return true;
        }
        return false;
    }
    return true;
  }

  void err_(const char* m) {
    total_errors++;
    if (total_errors < 20) printf("ERROR [%s]: %s\n", scen_name_(scen_), m);
  }

  Rng rng_;
  EthIn eth_in_;
  PipeIn pipe_in_;
  bool rst_n_ = false;
  // mac
  std::deque<int> mac_q_;
  int mac_off_ = 0, mac_n_ = 0, cur_len_ = 0;
  bool mac_valid_ = false;
  // sink
  std::vector<uint8_t> fbuf_;
  uint32_t crc_ = 0xFFFFFFFFu;
  int rx_next_ = 0;
  int sink_ready_default_ = 90;
  // phy
  int flits_ = 0, flits_base_ = 0;
  int rst_cnt_ = 0, st_cnt_ = 0, ack_cnt_ = 0, pd_q_ = 0, rate_q_ = 0, width_q_ = 0;
  bool mute_status_ = false;
  int mb_ph_ = 0;                // 0 idle, 1 expect addr[7:0], 2 expect data
  int mb_addr_ = 0, mb_last_addr_ = 0, mb_last_data_ = 0, mb_writes_ = 0;
  std::deque<int> p2m_q_;        // PHY-initiated message-bus bytes still to drive
  int mb_acks_ = 0, mb_rds_ = 0, mb_rd_data_ = 0, ack_base_ = 0, rd_base_ = 0;
  // sequencer
  int scen_ = 0;
  Phase phase_ = P_RESET;
  int rst_hold_ = 0, tmo_ = 0, err_base_ = 0;
  uint32_t csr_rdata_ = 0;
  std::vector<Op> ops_;
  size_t op_i_ = 0;
  int op_t_ = 0;
  ScenResult res_;

 public:
  void set_sink_default(int p) { sink_ready_default_ = p; sink_ready_pct = p; }

  // results.json (only the cross-check scenarios)
  bool write_json(const char* path, const char* env) const {
    FILE* f = fopen(path, "w");
    if (!f) return false;
    fprintf(f, "{\"env\": \"%s\", \"scenarios\": {", env);
    bool first = true;
    for (const auto& r : results) {
      if (!r.crosscheck) continue;
      fprintf(f, "%s\"%s\": {\"frames\": %d, \"bytes\": %ld, \"flits\": %d, \"crc32\": \"%08x\", "
                 "\"pmcnt\": %u, \"errors\": %d}",
              first ? "" : ", ", r.name.c_str(), r.frames, r.bytes, r.flits, r.crc, r.pmcnt, r.errors);
      first = false;
    }
    fprintf(f, "}}\n");
    fclose(f);
    return true;
  }
};

}  // namespace bfm
