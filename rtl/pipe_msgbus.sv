// ============================================================================
// pipe_msgbus.sv — pclk domain.  PIPE 7.x message-bus master (MAC side).
//
// Issues one committed write at a time on the 8-bit M2P byte bus
// (docs/OPEN_DECISIONS.md D8):
//   cycle 0: m2p = {MB_WR_C, addr[11:8]}
//   cycle 1: m2p = addr[7:0]
//   cycle 2: m2p = wdata[7:0]      (then idle 8'h00)
//   then waits for a P2M byte with p2m[7:4] == MB_WR_ACK, or PHY_TIMEOUT cycles.
// `done` pulses on the ack, `timeout` pulses instead if no ack arrives.  Other
// P2M messages (read completions, unsolicited writes) are ignored.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module pipe_msgbus
  import eth_dj_pipe7_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,

  input  logic                     req,        // start a write (ignored while busy)
  input  logic [MB_ADDR_W-1:0]     addr,
  input  logic [7:0]               wdata,
  output logic                     busy,
  output logic                     done,       // 1-cycle pulse: write_ack received
  output logic                     timeout,    // 1-cycle pulse: no write_ack

  output logic [MSGBUS_W-1:0]      m2p,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [MSGBUS_W-1:0]      p2m         // only p2m[7:4] (command) is examined
  /* verilator lint_on UNUSEDSIGNAL */
);
  localparam int unsigned TW = $clog2(PHY_TIMEOUT + 1);

  localparam logic [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2, S_WAIT = 2'd3;

  logic [1:0]    st_q;
  logic [7:0]    wdata_q;
  logic [7:0]    addr_lo_q;
  logic [TW-1:0] tmr_q;

  assign busy = (st_q != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q     <= S_IDLE;
      wdata_q  <= '0;
      tmr_q    <= '0;
      addr_lo_q <= '0;
      m2p      <= 8'h00;
      done     <= 1'b0;
      timeout  <= 1'b0;
    end else begin
      done    <= 1'b0;
      timeout <= 1'b0;
      case (st_q)
        S_IDLE: begin
          m2p <= 8'h00;
          if (req) begin
            m2p       <= {MB_WR_C, addr[MB_ADDR_W-1:8]};   // byte 0
            addr_lo_q <= addr[7:0];
            wdata_q   <= wdata;
            st_q      <= S_ADDR;
          end
        end
        S_ADDR: begin
          m2p  <= addr_lo_q;                                // byte 1
          st_q <= S_DATA;
        end
        S_DATA: begin
          m2p   <= wdata_q;                                 // byte 2
          tmr_q <= '0;
          st_q  <= S_WAIT;
        end
        default: begin // S_WAIT
          m2p <= 8'h00;
          if (p2m[7:4] == MB_WR_ACK) begin
            done <= 1'b1;
            st_q <= S_IDLE;
          end else if (int'(tmr_q) == PHY_TIMEOUT - 1) begin
            timeout <= 1'b1;
            st_q    <= S_IDLE;
          end else begin
            tmr_q <= tmr_q + TW'(1);
          end
        end
      endcase
    end
  end

endmodule : pipe_msgbus
