// ============================================================================
// dv/iverilog/tb_msgbus_mac.sv — msgbus_mac_tgt (MAC-side target + M2P arbiter) with the
// bridge's pipe_msgbus master, against PIPE 7.1 §6.1.4.
//   A  PHY write_committed          -> exactly one write_ack, nothing else
//   B  PHY read                     -> read_completion {RD_CPL,0},{data}
//   C  PHY write_uncommitted x2 + write_committed -> one write_ack only
//   D  PHY request DURING our 3-byte frame -> our frame is intact/contiguous, response after it
//   E  PHY read while our write waits for its ack -> response inserted in the idle gap;
//      our write still completes on the PHY's write_ack
//   F  PHY write + read back to back -> write_ack then read_completion, each once
//   G1 response already queued when our request arrives -> response first, both intact
//   G2 our request and a PHY read in the same cycle -> master has priority
//   H  PHY write_ack / read_completion (responses to us) never trigger a response
// The M2P monitor decodes the bus with the spec's framing rules (start byte, length by cmd);
// an interleaved or split transaction makes the decoded list differ from the expected one.
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_msgbus_mac;
  import eth_dj_pipe7_pkg::*;

  logic clk = 1'b0, rst_n;
  always #1 clk = ~clk;

  logic                  fsm_req = 1'b0;
  logic [MB_ADDR_W-1:0]  addr = 12'h405;
  logic [7:0]            wdata = 8'h21;
  wire                   m_req, m_tx_active, tgt_tx;
  wire  [MB_ADDR_W-1:0]  m_addr;
  wire  [7:0]            m_wdata;
  wire  [MSGBUS_W-1:0]   m_m2p, m2p;
  logic [MSGBUS_W-1:0]   p2m = 8'h00;
  wire                   busy, done, timeout;
  wire [15:0]            phy_wr_cnt, phy_rd_cnt, drop_cnt;
  wire [MB_ADDR_W-1:0]   last_wr_addr;
  wire [7:0]             last_wr_data;

  msgbus_mac_tgt tgt (.clk(clk), .rst_n(rst_n), .fsm_req(fsm_req), .fsm_addr(addr), .fsm_wdata(wdata),
    .m_req(m_req), .m_addr(m_addr), .m_wdata(m_wdata), .m_tx_active(m_tx_active), .m_m2p(m_m2p),
    .p2m(p2m), .m2p(m2p), .tgt_tx(tgt_tx), .phy_wr_cnt(phy_wr_cnt), .phy_rd_cnt(phy_rd_cnt),
    .drop_cnt(drop_cnt), .last_wr_addr(last_wr_addr), .last_wr_data(last_wr_data));

  pipe_msgbus mst (.clk(clk), .rst_n(rst_n), .req(m_req), .addr(m_addr), .wdata(m_wdata),
    .busy(busy), .done(done), .timeout(timeout), .tx_active(m_tx_active), .m2p(m_m2p), .p2m(p2m));

  int errors = 0, done_cnt = 0, to_cnt = 0;
  always @(posedge clk) begin
    if (done)    done_cnt++;
    if (timeout) to_cnt++;
  end

  // ---- M2P transaction monitor (spec framing) -----------------------------------------------
  // kinds: 1 = our write_committed {addr,data}; 4 = read_completion {data}; 5 = write_ack
  int  ntx = 0;
  int  tx_kind [0:63];
  int  tx_a [0:63];
  int  tx_d [0:63];
  int  mrem = 0, mkind = 0, mstage = 0;
  logic [3:0] mhi;
  logic [7:0] mlo;
  always @(posedge clk) begin
    if (!rst_n) begin mrem = 0; end
    else if (mrem > 0) begin
      case (mkind)
        1: begin
             if (mstage == 1) begin mlo = m2p; mstage = 2; end
             else begin tx_kind[ntx] = 1; tx_a[ntx] = {mhi, mlo}; tx_d[ntx] = m2p; ntx++; end
           end
        4: begin tx_kind[ntx] = 4; tx_a[ntx] = 0; tx_d[ntx] = m2p; ntx++; end
        default: ;
      endcase
      mrem--;
    end else if (m2p != 8'h00) begin
      case (m2p[7:4])
        MB_WR_C:   begin mkind = 1; mrem = 2; mstage = 1; mhi = m2p[3:0]; end
        MB_RD_CPL: begin mkind = 4; mrem = 1; end
        MB_WR_ACK: begin tx_kind[ntx] = 5; tx_a[ntx] = 0; tx_d[ntx] = 0; ntx++; end
        default:   begin tx_kind[ntx] = 99; tx_a[ntx] = m2p; tx_d[ntx] = 0; ntx++; end   // unexpected
      endcase
    end
  end

  task automatic chk(input bit c, input string w);
    begin if (!c) begin errors++; $display("FAIL: %s", w); end end
  endtask
  task automatic step(input int n); begin repeat (n) @(posedge clk); end endtask
  task automatic drive(input logic [7:0] b); begin p2m <= b; @(posedge clk); end endtask
  task automatic idle(input int n); begin p2m <= 8'h00; step(n); end endtask
  task automatic fsm_write();
    begin @(posedge clk); fsm_req <= 1'b1; @(posedge clk); fsm_req <= 1'b0; end
  endtask
  // PHY-initiated transactions
  task automatic phy_wr(input logic [3:0] cmd, input logic [11:0] a, input logic [7:0] d);
    begin drive({cmd, a[11:8]}); drive(a[7:0]); drive(d); end
  endtask
  task automatic phy_rd(input logic [11:0] a);
    begin drive({MB_RD, a[11:8]}); drive(a[7:0]); end
  endtask
  task automatic expect_tx(input int idx, input int kind, input int a, input int d, input string w);
    begin
      chk(idx < ntx, {w, ": transaction present"});
      if (idx < ntx) begin
        chk(tx_kind[idx] == kind, {w, ": kind"});
        if (kind == 1) chk(tx_a[idx] == a, {w, ": addr"});
        if (kind == 1 || kind == 4) chk(tx_d[idx] == d, {w, ": data"});
      end
    end
  endtask

  int n0, w0, r0;
  initial begin
    rst_n = 1'b0; step(4); rst_n = 1'b1; step(3);

    // A: PHY write_committed
    n0 = ntx; w0 = phy_wr_cnt;
    phy_wr(MB_WR_C, 12'h123, 8'h9A); idle(8);
    chk(ntx == n0 + 1, "A exactly one M2P transaction");
    expect_tx(n0, 5, 0, 0, "A write_ack");
    chk(phy_wr_cnt == w0 + 1 && last_wr_addr == 12'h123 && last_wr_data == 8'h9A, "A write recorded");

    // B: PHY read
    n0 = ntx; r0 = phy_rd_cnt;
    phy_rd(12'h004); idle(8);
    chk(ntx == n0 + 1, "B exactly one M2P transaction");
    expect_tx(n0, 4, 0, 8'h00, "B read_completion (no MAC registers: data 0)");
    chk(phy_rd_cnt == r0 + 1, "B read counted");

    // C: two write_uncommitted then one write_committed
    n0 = ntx;
    phy_wr(MB_WR_UC, 12'h010, 8'h11); phy_wr(MB_WR_UC, 12'h011, 8'h22); phy_wr(MB_WR_C, 12'h012, 8'h33);
    idle(8);
    chk(ntx == n0 + 1, "C only the committed write is acknowledged");
    expect_tx(n0, 5, 0, 0, "C write_ack");

    // D: PHY write arrives during our frame
    n0 = ntx; done_cnt = 0;
    fsm_write();
    step(1);                                   // our master is now mid-frame
    phy_wr(MB_WR_C, 12'h200, 8'h5A);           // 3 P2M cycles overlapping our frame
    idle(10);
    expect_tx(n0, 1, 12'h405, 8'h21, "D our write frame intact and contiguous");
    expect_tx(n0 + 1, 5, 0, 0, "D write_ack for the PHY write follows our frame");
    chk(ntx == n0 + 2, "D exactly two M2P transactions");
    drive({MB_WR_ACK, 4'h0}); idle(6);          // the PHY acks our write
    chk(done_cnt == 1 && !busy, "D our write completes on the PHY's write_ack");

    // E: PHY read while our write is waiting for its ack
    n0 = ntx; done_cnt = 0;
    fsm_write(); step(10);                     // frame sent, master in its wait state
    phy_rd(12'h001); idle(8);
    expect_tx(n0, 1, 12'h405, 8'h21, "E our frame");
    expect_tx(n0 + 1, 4, 0, 8'h00, "E read_completion inserted in the idle gap");
    chk(busy && done_cnt == 0, "E our write still waiting");
    drive({MB_WR_ACK, 4'h0}); idle(6);
    chk(done_cnt == 1 && !busy, "E our write completes on the PHY's write_ack");

    // F: write + read back to back (no idle)
    n0 = ntx;
    phy_wr(MB_WR_C, 12'h300, 8'h77); phy_rd(12'h002); idle(12);
    chk(ntx == n0 + 2, "F two responses");
    expect_tx(n0, 5, 0, 0, "F write_ack first");
    expect_tx(n0 + 1, 4, 0, 8'h00, "F then read_completion");

    // G1: a response is already queued/on the bus when our request arrives -> response first,
    //     our frame follows, both intact
    n0 = ntx; done_cnt = 0;
    phy_rd(12'h003);
    fsm_write();
    idle(14);
    expect_tx(n0, 4, 0, 8'h00, "G1 read_completion already on the bus goes first");
    expect_tx(n0 + 1, 1, 12'h405, 8'h21, "G1 our frame follows, intact and contiguous");
    chk(ntx == n0 + 2, "G1 exactly two transactions");
    drive({MB_WR_ACK, 4'h0}); idle(6);
    chk(done_cnt == 1 && !busy, "G1 our write completes");

    // G2: our request and the PHY read complete in the same cycle -> the master has priority
    n0 = ntx; done_cnt = 0;
    fork
      phy_rd(12'h003);                                   // byte1 is sampled at edge e2
      begin @(posedge clk); fsm_req <= 1'b1; @(posedge clk); fsm_req <= 1'b0; end   // req sampled at e2
    join
    idle(14);
    expect_tx(n0, 1, 12'h405, 8'h21, "G2 master has priority over a same-cycle pending response");
    expect_tx(n0 + 1, 4, 0, 8'h00, "G2 read_completion after our frame, not inside it");
    chk(ntx == n0 + 2, "G2 exactly two transactions");
    drive({MB_WR_ACK, 4'h0}); idle(6);
    chk(done_cnt == 1 && !busy, "G2 our write completes");

    // H: the PHY's own responses to us must not provoke a response
    n0 = ntx;
    drive({MB_WR_ACK, 4'h0}); drive({MB_RD_CPL, 4'h0}); drive(8'h5A); idle(8);
    chk(ntx == n0, "H no response to write_ack / read_completion");
    chk(drop_cnt == 0, "no dropped PHY request in the directed cases");

    if (errors == 0) $display("MSGBUS-MAC PASS: target + arbiter checks (A-H)");
    else             $display("MSGBUS-MAC FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin #400000; $display("MSGBUS-MAC FAIL: timeout"); $finish; end
endmodule
