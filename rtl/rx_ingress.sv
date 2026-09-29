// ============================================================================
// rx_ingress.sv — pclk domain.  Captures PIPE Rx beats into a 256B flit and
// FLIT-locks on pipe_rx_start_block: beats are ignored until a start_block, and a
// start_block mid-flit restarts capture.  A completed flit is held (flit_valid)
// until the deframer takes it.  PIPE Rx has no backpressure, so a flit completing
// while the previous one is still held is DROPPED and counted in dropped_flits
// (credit flow control is future work, docs/OPEN_DECISIONS.md).
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module rx_ingress
  import eth_dj_pipe7_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic [PIPE_BUS_W-1:0]       pipe_rx_data,
  input  logic                        pipe_rx_data_valid,
  input  logic                        pipe_rx_start_block,

  output logic                        flit_valid,
  output logic [FLIT_BYTES*8-1:0]     flit,
  input  logic                        flit_taken,

  output logic [15:0]                 dropped_flits,   // DV visibility (sticky count)
  output logic [15:0]                 lock_errors      // beats/start_block protocol slips
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic [FLIT_BYTES*8-1:0] cap_q, flit_q;
  logic [CW-1:0]           cnt_q;
  logic                    locked_q, full_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_q         <= '0;
      flit_q        <= '0;
      cnt_q         <= '0;
      locked_q      <= 1'b0;
      full_q        <= 1'b0;
      dropped_flits <= '0;
      lock_errors   <= '0;
    end else begin
      if (full_q && flit_taken) full_q <= 1'b0;

      if (pipe_rx_data_valid) begin
        if (pipe_rx_start_block) begin
          if (locked_q) lock_errors <= lock_errors + 16'd1;   // start_block mid-flit
          cap_q[PIPE_BUS_W-1:0] <= pipe_rx_data;
          cnt_q    <= CW'(1);
          locked_q <= 1'b1;
        end else if (locked_q) begin
          cap_q[int'(cnt_q)*PIPE_BUS_W +: PIPE_BUS_W] <= pipe_rx_data;
          if (int'(cnt_q) == FLIT_BEATS - 1) begin
            locked_q <= 1'b0;
            cnt_q    <= '0;
            if (full_q) begin
              dropped_flits <= dropped_flits + 16'd1;
            end else begin
              flit_q <= cap_q;
              flit_q[(FLIT_BEATS-1)*PIPE_BUS_W +: PIPE_BUS_W] <= pipe_rx_data;
              full_q <= 1'b1;
            end
          end else begin
            cnt_q <= cnt_q + CW'(1);
          end
        end else begin
          lock_errors <= lock_errors + 16'd1;                 // data outside a flit
        end
      end else if (locked_q) begin
        locked_q    <= 1'b0;                                  // valid dropped mid-flit
        cnt_q       <= '0;
        lock_errors <= lock_errors + 16'd1;
      end
    end
  end

  assign flit_valid = full_q;
  assign flit       = flit_q;

endmodule : rx_ingress
