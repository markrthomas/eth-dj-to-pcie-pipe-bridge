// ============================================================================
// dv/iverilog/tb_msgbus.sv — unit test of pipe_msgbus against PIPE 7.1 §6.1.4.
//   T1  write_committed framing on M2P: {WR_C,addr[11:8]}, addr[7:0], data, then idle
//   T2  a read_completion ({RD_CPL,0}, data 8'h5A) while waiting is NOT a write_ack
//   T3  a PHY-initiated write_committed (cmd byte, addr byte 8'h50, data byte 8'h5F) is not an ack
//   T4  transactions may follow with no idle: read_completion immediately followed by write_ack
//   T5  no ack -> exactly one timeout, no done
// ============================================================================
`timescale 1ns/1ps
`include "eth_dj_pipe7_pkg.sv"

module tb_msgbus;
  import eth_dj_pipe7_pkg::*;

  logic clk = 1'b0, rst_n;
  always #1 clk = ~clk;

  logic                  req = 1'b0;
  logic [MB_ADDR_W-1:0]  addr = 12'hA5C;
  logic [7:0]            wdata = 8'h3C;
  wire                   busy, done, timeout;
  wire  [MSGBUS_W-1:0]   m2p;
  logic [MSGBUS_W-1:0]   p2m = 8'h00;

  pipe_msgbus dut (.clk(clk), .rst_n(rst_n), .req(req), .addr(addr), .wdata(wdata),
                   .busy(busy), .done(done), .timeout(timeout), .m2p(m2p), .p2m(p2m));

  int errors = 0, done_cnt = 0, to_cnt = 0;
  always @(posedge clk) begin
    if (done)    done_cnt++;
    if (timeout) to_cnt++;
  end

  task automatic chk(input bit cond, input string what);
    begin
      if (!cond) begin errors++; $display("FAIL: %s", what); end
    end
  endtask

  task automatic step(input int n);
    begin repeat (n) @(posedge clk); end
  endtask

  // issue one write and capture the 6 M2P cycles that follow the request
  logic [7:0] cap [0:5];
  task automatic issue_write();
    begin
      @(posedge clk); req <= 1'b1;
      @(posedge clk); req <= 1'b0;
      for (int i = 0; i < 6; i++) begin @(posedge clk); cap[i] = m2p; end
    end
  endtask

  task automatic drive(input logic [7:0] b);
    begin p2m <= b; @(posedge clk); end
  endtask

  int d0;
  initial begin
    rst_n = 1'b0; step(4); rst_n = 1'b1; step(3);

    // ---- T1 framing + ack ----------------------------------------------------
    issue_write();
    chk(cap[0] == {MB_WR_C, addr[11:8]}, "T1 byte0 = {WR_C, addr[11:8]}");
    chk(cap[1] == addr[7:0],             "T1 byte1 = addr[7:0]");
    chk(cap[2] == wdata,                 "T1 byte2 = data");
    chk(cap[3] == 8'h00 && cap[4] == 8'h00 && cap[5] == 8'h00, "T1 idle 8'h00 after the frame");
    chk(busy && done_cnt == 0, "T1 still waiting for the ack");
    d0 = done_cnt;
    drive({MB_WR_ACK, 4'h0}); drive(8'h00); step(3);
    chk(done_cnt == d0 + 1 && !busy && to_cnt == 0, "T1 write_ack completes the write");

    // ---- T2 read_completion whose data byte looks like a write_ack ---------------
    issue_write();
    d0 = done_cnt;
    drive({MB_RD_CPL, 4'h0}); drive(8'h5A); drive(8'h00); step(3);
    chk(done_cnt == d0 && busy, "T2 read_completion data 8'h5A must not be taken as write_ack");
    drive({MB_WR_ACK, 4'h0}); drive(8'h00); step(3);
    chk(done_cnt == d0 + 1 && !busy, "T2 the real write_ack then completes it");

    // ---- T3 PHY-initiated write_committed (3 cycles) whose bytes alias an ack --------
    issue_write();
    d0 = done_cnt;
    drive({MB_WR_C, 4'h0}); drive(8'h50); drive(8'h5F); drive(8'h00); step(3);
    chk(done_cnt == d0 && busy, "T3 PHY write_committed payload bytes must not be taken as write_ack");
    drive({MB_WR_ACK, 4'h0}); drive(8'h00); step(3);
    chk(done_cnt == d0 + 1 && !busy, "T3 the real write_ack then completes it");

    // ---- T4 no idle between transactions ---------------------------------------------
    issue_write();
    d0 = done_cnt;
    drive({MB_RD_CPL, 4'h0}); drive(8'h5A); drive({MB_WR_ACK, 4'h0}); drive(8'h00); step(3);
    chk(done_cnt == d0 + 1 && !busy, "T4 write_ack immediately after a read_completion is recognised");

    // ---- T5 timeout -------------------------------------------------------------------
    issue_write();
    d0 = done_cnt;
    step(PHY_TIMEOUT + 10);
    chk(to_cnt == 1 && done_cnt == d0 && !busy, "T5 exactly one timeout, no done");

    if (errors == 0) $display("MSGBUS PASS: framing + P2M framer checks (T1-T5)");
    else             $display("MSGBUS FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin #200000; $display("MSGBUS FAIL: timeout"); $finish; end
endmodule
