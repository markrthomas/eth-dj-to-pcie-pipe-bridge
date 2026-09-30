// ============================================================================
// dv/uvm/bridge_uvm_pkg.sv — UVM environment for eth_dj_pipe7_bridge (DV env 3).
//
//   eth_frame_item / frame_seq -> eth_sequencer -> eth_tx_driver  (AXI4-S source)
//   eth_rx_monitor  : tready responder + frame reassembly -> analysis port
//   pipe_phy_driver : reactive PHY (PhyStatus, msgbus target, flit count,
//                     Tx-legality checker)
//   csr_agent       : CSR read/write/poll tasks
//   bridge_sb       : in-order byte check + CRC-32 per scenario
//   scen_test       : runs the shared five-scenario set, writes results.json
// Drive with NBAs after @(posedge clk); sample right after @(posedge clk)
// (pre-NBA, i.e. the values the DUT flops just sampled).
// ============================================================================
`include "uvm_macros.svh"

package bridge_uvm_pkg;
  import uvm_pkg::*;
  import eth_dj_pipe7_pkg::*;

  `include "eth_dj_pat.svh"
  `include "scenarios.svh"

  // ------------------------------------------------------------------ items
  class eth_frame_item extends uvm_sequence_item;
    int fid;
    int len;
    `uvm_object_utils(eth_frame_item)
    function new(string name = "eth_frame_item");
      super.new(name);
    endfunction
  endclass

  class rx_frame extends uvm_object;
    byte unsigned data[$];
    bit err;
    `uvm_object_utils(rx_frame)
    function new(string name = "rx_frame");
      super.new(name);
    endfunction
  endclass

  typedef uvm_sequencer #(eth_frame_item) eth_sequencer;

  class frame_seq extends uvm_sequence #(eth_frame_item);
    int scen, lo, hi;
    `uvm_object_utils(frame_seq)
    function new(string name = "frame_seq");
      super.new(name);
    endfunction
    task body();
      for (int i = lo; i < hi; i++) begin
        eth_frame_item it = eth_frame_item::type_id::create($sformatf("f%0d", i));
        start_item(it);
        it.fid = i;
        it.len = scen_len(scen, i);
        finish_item(it);
      end
    endtask
  endclass

  // ------------------------------------------------------------ eth tx driver
  class eth_tx_driver extends uvm_driver #(eth_frame_item);
    virtual eth_if vif;
    int gap_pct = 10;
    `uvm_component_utils(eth_tx_driver)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual eth_if)::get(this, "", "eth_vif", vif))
        `uvm_fatal("NOVIF", "eth_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      eth_frame_item it;
      logic [ETH_DATA_W-1:0] d;
      logic [ETH_KEEP_W-1:0] k;
      int off, n;
      vif.tvalid <= 1'b0;
      vif.tlast  <= 1'b0;
      @(posedge vif.clk);
      forever begin
        seq_item_port.get_next_item(it);
        off = 0;
        while (off < it.len) begin
          if (gap_pct > 0 && $urandom_range(99, 0) < gap_pct) begin
            vif.tvalid <= 1'b0;
            @(posedge vif.clk);
            continue;
          end
          n = it.len - off;
          if (n > ETH_KEEP_W) n = ETH_KEEP_W;
          d = '0;
          k = '0;
          for (int i = 0; i < n; i++) begin
            d[8*i +: 8] = pat(it.fid, off + i);
            k[i] = 1'b1;
          end
          vif.tvalid <= 1'b1;
          vif.tdata  <= d;
          vif.tkeep  <= k;
          vif.tlast  <= (off + n == it.len);
          do @(posedge vif.clk); while (!(vif.tvalid && vif.tready));
          off += n;
        end
        vif.tvalid <= 1'b0;
        vif.tlast  <= 1'b0;
        seq_item_port.item_done();
        @(posedge vif.clk);
      end
    endtask
  endclass

  // ------------------------------------------------------------ eth rx monitor
  class eth_rx_monitor extends uvm_component;
    virtual eth_if vif;
    uvm_analysis_port #(rx_frame) ap;
    int ready_pct = 90;
    int errors = 0;
    `uvm_component_utils(eth_rx_monitor)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual eth_if)::get(this, "", "eth_vif", vif))
        `uvm_fatal("NOVIF", "eth_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      rx_frame fr = rx_frame::type_id::create("fr");
      int nb;
      vif.rx_tready <= 1'b0;
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n && vif.rx_tvalid && vif.rx_tready) begin
          nb = 0;
          for (int i = 0; i < ETH_KEEP_W; i++) nb += int'(vif.rx_tkeep[i]);
          if (nb == 0 || vif.rx_tkeep != ETH_KEEP_W'((64'd1 << nb) - 1) ||
              (!vif.rx_tlast && nb != ETH_KEEP_W) || (vif.rx_tuser[0] && !vif.rx_tlast)) begin
            errors++;
            `uvm_error("RXMON", $sformatf("illegal tkeep %h last %b", vif.rx_tkeep, vif.rx_tlast))
          end
          for (int i = 0; i < nb; i++) fr.data.push_back(vif.rx_tdata[8*i +: 8]);
          if (vif.rx_tlast) begin
            fr.err = vif.rx_tuser[0];
            ap.write(fr);
            fr = rx_frame::type_id::create("fr");
          end
        end
        vif.rx_tready <= vif.rst_n && ($urandom_range(99, 0) < ready_pct);
      end
    endtask
  endclass

  // ------------------------------------------------------------ PHY (reactive)
  class pipe_phy_driver extends uvm_component;
    virtual pipe_if vif;
    int unsigned flits = 0;
    int errors = 0;
    int mb_writes = 0;
    `uvm_component_utils(pipe_phy_driver)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual pipe_if)::get(this, "", "pipe_vif", vif))
        `uvm_fatal("NOVIF", "pipe_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      logic [1:0] pd_q, wd_q;
      logic [2:0] rt_q;
      int rst_cnt, st_cnt, ack_cnt, beat;
      int mb_ph;   // 0 idle, 1 next byte = addr[7:0], 2 next byte = data
      bit change;
      logic [MB_ADDR_W-1:0] mb_addr;
      vif.phy_status <= 1'b1;
      vif.p2m_msgbus <= 8'h00;
      rst_cnt = 0; st_cnt = 0; ack_cnt = 0; beat = 0; mb_ph = 0; mb_addr = '0;
      pd_q = '0; rt_q = '0; wd_q = '0;
      forever begin
        @(posedge vif.clk);
        if (!vif.rst_n) begin
          vif.phy_status <= 1'b1;
          vif.p2m_msgbus <= 8'h00;
          rst_cnt = 0; st_cnt = 0; ack_cnt = 0; beat = 0; mb_ph = 0;
          pd_q = vif.powerdown; rt_q = vif.rate; wd_q = vif.width;
          continue;
        end
        // flit monitor
        if (vif.tx_valid) begin
          if (vif.tx_sb != (beat == 0)) begin errors++; `uvm_error("PHY", "start_block misplaced") end
          if (beat == 0) flits++;
          beat = (beat + 1) % FLIT_BEATS;
        end else if (beat != 0) begin
          errors++; `uvm_error("PHY", "data_valid dropped mid-flit") beat = 0;
        end
        // PhyStatus
        change = (vif.powerdown != pd_q) || (vif.rate != rt_q) || (vif.width != wd_q);
        if (vif.tx_valid && (vif.powerdown != PWR_P0 || st_cnt != 0 || change)) begin
          errors++; `uvm_error("PHY", "Tx data_valid outside P0 / during a change")
        end
        vif.phy_status <= 1'b0;
        if (rst_cnt < 16) begin rst_cnt++; vif.phy_status <= 1'b1; end
        else if (change) st_cnt = 8;
        else if (st_cnt == 1) begin st_cnt = 0; vif.phy_status <= 1'b1; end
        else if (st_cnt > 1) st_cnt--;
        pd_q = vif.powerdown; rt_q = vif.rate; wd_q = vif.width;
        // message bus target
        vif.p2m_msgbus <= 8'h00;
        if (mb_ph == 1) begin
          mb_addr[7:0] = vif.m2p_msgbus; mb_ph = 2;
        end else if (mb_ph == 2) begin
          mb_writes++; mb_ph = 0; ack_cnt = 8;
        end else if (vif.m2p_msgbus != 8'h00) begin   // any non-idle byte starts a transaction
          if (vif.m2p_msgbus[7:4] == MB_WR_C) begin
            mb_addr[MB_ADDR_W-1:8] = vif.m2p_msgbus[3:0]; mb_ph = 1;
          end else begin
            errors++; `uvm_error("PHY", "unsupported msgbus command")
          end
        end
        if (ack_cnt == 1) begin
          ack_cnt = 0; vif.p2m_msgbus <= {MB_WR_ACK, 4'h0};
        end else if (ack_cnt > 1) ack_cnt--;
      end
    endtask
  endclass

  // ------------------------------------------------------------ CSR agent
  class csr_agent extends uvm_component;
    virtual pipe_if vif;
    `uvm_component_utils(csr_agent)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual pipe_if)::get(this, "", "pipe_vif", vif))
        `uvm_fatal("NOVIF", "pipe_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      vif.csr_valid <= 1'b0;
      vif.csr_write <= 1'b0;
      vif.csr_addr  <= '0;
      vif.csr_wdata <= '0;
    endtask
    task write(logic [7:0] a, logic [31:0] d);
      @(posedge vif.clk);
      vif.csr_valid <= 1'b1; vif.csr_write <= 1'b1; vif.csr_addr <= a; vif.csr_wdata <= d;
      @(posedge vif.clk);
      vif.csr_valid <= 1'b0; vif.csr_write <= 1'b0;
    endtask
    task read(logic [7:0] a, output logic [31:0] d);
      @(posedge vif.clk);
      vif.csr_addr <= a;
      @(posedge vif.clk);
      d = vif.csr_rdata;
    endtask
    task set_state(logic [1:0] pd, logic [2:0] rt, output bit ok);
      logic [31:0] s;
      write(CSR_CTRL, {25'b0, 2'b00, rt, pd});
      ok = 0;
      for (int t = 0; t < 20000 && !ok; t++) begin
        read(CSR_STATUS, s);
        ok = (s[1:0] == pd) && (s[4:2] == rt) && !s[10];
      end
    endtask
  endclass

  // ------------------------------------------------------------ scoreboard
  class bridge_sb extends uvm_subscriber #(rx_frame);
    int scen;
    int frames, errors;
    longint nbytes;
    logic [31:0] crc;
    `uvm_component_utils(bridge_sb)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void start(int s);
      scen = s; frames = 0; errors = 0; nbytes = 0; crc = 32'hFFFF_FFFF;
    endfunction
    function void write(rx_frame t);
      if (t.err || frames >= scen_nframes(scen) || t.data.size() != scen_len(scen, frames)) begin
        errors++;
        `uvm_error("SB", $sformatf("%s frame %0d len %0d err %b", scen_name(scen), frames, t.data.size(), t.err))
      end else begin
        foreach (t.data[i])
          if (t.data[i] != pat(frames, i)) begin
            errors++;
            `uvm_error("SB", $sformatf("%s frame %0d byte %0d", scen_name(scen), frames, i))
            break;
          end
      end
      foreach (t.data[i]) crc = crc32_byte(crc, t.data[i]);
      nbytes += t.data.size();
      frames++;
    endfunction
  endclass

  // ------------------------------------------------------------ env / test
  class bridge_env extends uvm_env;
    eth_sequencer   seqr;
    eth_tx_driver   drv;
    eth_rx_monitor  rxm;
    pipe_phy_driver phy;
    csr_agent       csr;
    bridge_sb       sb;
    `uvm_component_utils(bridge_env)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      seqr = eth_sequencer::type_id::create("seqr", this);
      drv  = eth_tx_driver::type_id::create("drv", this);
      rxm  = eth_rx_monitor::type_id::create("rxm", this);
      phy  = pipe_phy_driver::type_id::create("phy", this);
      csr  = csr_agent::type_id::create("csr", this);
      sb   = bridge_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(seqr.seq_item_export);
      rxm.ap.connect(sb.analysis_export);
    endfunction
  endclass

  class scen_test extends uvm_test;
    bridge_env env;
    virtual eth_if  evif;
    virtual pipe_if pvif;
    int total_errors = 0;
    `uvm_component_utils(scen_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      env = bridge_env::type_id::create("env", this);
      void'(uvm_config_db#(virtual eth_if)::get(this, "", "eth_vif", evif));
      void'(uvm_config_db#(virtual pipe_if)::get(this, "", "pipe_vif", pvif));
    endfunction

    task do_reset(output bit ok);
      logic [31:0] s;
      evif.rst_n <= 1'b0;
      pvif.rst_n <= 1'b0;
      repeat (10) @(posedge pvif.clk);
      evif.rst_n <= 1'b1;
      pvif.rst_n <= 1'b1;
      ok = 0;
      for (int t = 0; t < 20000 && !ok; t++) begin
        env.csr.read(CSR_STATUS, s);
        ok = s[11];
      end
    endtask

    task wait_frames(int n, output bit ok);
      int t = 0;
      while (env.sb.frames < n && t < 400000) begin @(posedge pvif.clk); t++; end
      ok = env.sb.frames >= n;
    endtask

    task run_phase(uvm_phase phase);
      int fd, nfr, f0, e0, errs;
      bit ok, o;
      logic [31:0] pm;
      frame_seq seq;
      phase.raise_objection(this);
      fd = $fopen("logs/results.json", "w");
      $fwrite(fd, "{\"env\": \"uvm\", \"scenarios\": {");
      for (int sc = 0; sc < SCEN_N; sc++) begin
        nfr = scen_nframes(sc);
        env.sb.start(sc);
        do_reset(ok);
        f0 = env.phy.flits;
        e0 = env.phy.errors + env.rxm.errors;
        seq = frame_seq::type_id::create("seq");
        seq.scen = sc;
        if (scen_ctrl(sc) == 0) begin
          seq.lo = 0; seq.hi = nfr; seq.start(env.seqr);
        end else begin
          seq.lo = 0; seq.hi = nfr / 2; seq.start(env.seqr);
          wait_frames(nfr / 2, o); ok &= o;
          if (scen_ctrl(sc) == 1) begin
            env.csr.set_state(PWR_P1, RATE_GEN6, o); ok &= o;
            repeat (200) @(posedge pvif.clk);
            env.csr.set_state(PWR_P0, RATE_GEN6, o); ok &= o;
          end else begin
            env.csr.set_state(PWR_P0, RATE_GEN5, o); ok &= o;
            repeat (200) @(posedge pvif.clk);
            env.csr.set_state(PWR_P0, RATE_GEN6, o); ok &= o;
          end
          seq = frame_seq::type_id::create("seq_b");
          seq.scen = sc; seq.lo = nfr / 2; seq.hi = nfr; seq.start(env.seqr);
        end
        wait_frames(nfr, o); ok &= o;
        repeat (200) @(posedge pvif.clk);
        env.csr.read(CSR_PMCNT, pm);
        errs = env.sb.errors + (env.phy.errors + env.rxm.errors - e0) + (ok ? 0 : 1);
        total_errors += errs;
        `uvm_info("SCEN", $sformatf("%-11s frames=%0d bytes=%0d flits=%0d crc32=%08x pmcnt=%0d errors=%0d",
                  scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0, ~env.sb.crc, pm, errs), UVM_LOW)
        $fwrite(fd, "%s\"%s\": {\"frames\": %0d, \"bytes\": %0d, \"flits\": %0d, \"crc32\": \"%08x\", \"pmcnt\": %0d, \"errors\": %0d}",
                (sc == 0) ? "" : ", ", scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0,
                ~env.sb.crc, pm, errs);
      end
      $fwrite(fd, "}}\n");
      $fclose(fd);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      if (total_errors == 0) `uvm_info("RESULT", "UVM PASS: 5 scenarios", UVM_NONE)
      else `uvm_error("RESULT", $sformatf("UVM FAIL: %0d error(s)", total_errors))
    endfunction
  endclass

endpackage
