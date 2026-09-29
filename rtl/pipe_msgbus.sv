// ============================================================================
// pipe_msgbus.sv — pclk domain.  PIPE 7.x message-bus master (MAC side).
//
// Issues one committed write at a time (docs/OPEN_DECISIONS.md D8):
//   cycle 0: m2p = {MB_WR_C, addr}
//   cycle 1: m2p = {MB_NOP,  wdata}
//   then waits for p2m_cmd == MB_WR_ACK (any p2m_data) or PHY_TIMEOUT cycles.
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
  input  logic [7:0]               addr,
  input  logic [7:0]               wdata,
  output logic                     busy,
  output logic                     done,       // 1-cycle pulse: write_ack received
  output logic                     timeout,    // 1-cycle pulse: no write_ack

  output logic [MSGBUS_CMD_W-1:0]  m2p_cmd,
  output logic [MSGBUS_DATA_W-1:0] m2p_data,
  input  logic [MSGBUS_CMD_W-1:0]  p2m_cmd,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [MSGBUS_DATA_W-1:0] p2m_data    // write_ack payload not checked
  /* verilator lint_on UNUSEDSIGNAL */
);
  localparam int unsigned TW = $clog2(PHY_TIMEOUT + 1);

  localparam logic [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2, S_WAIT = 2'd3;

  logic [1:0]    st_q;
  logic [7:0]    wdata_q;
  logic [TW-1:0] tmr_q;

  assign busy = (st_q != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q     <= S_IDLE;
      wdata_q  <= '0;
      tmr_q    <= '0;
      m2p_cmd  <= MB_NOP;
      m2p_data <= '0;
      done     <= 1'b0;
      timeout  <= 1'b0;
    end else begin
      done    <= 1'b0;
      timeout <= 1'b0;
      case (st_q)
        S_IDLE: begin
          m2p_cmd  <= MB_NOP;
          m2p_data <= '0;
          if (req) begin
            m2p_cmd  <= MB_WR_C;
            m2p_data <= addr;
            wdata_q  <= wdata;
            st_q     <= S_ADDR;
          end
        end
        S_ADDR: begin
          m2p_cmd  <= MB_NOP;
          m2p_data <= wdata_q;
          st_q     <= S_DATA;
        end
        S_DATA: begin
          m2p_cmd  <= MB_NOP;
          m2p_data <= '0;
          tmr_q    <= '0;
          st_q     <= S_WAIT;
        end
        default: begin // S_WAIT
          if (p2m_cmd == MB_WR_ACK) begin
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
