// ============================================================================
// rx_ingress.sv — pclk domain.  Captures PIPE Rx beats into a 256B flit and
// FLIT-locks on pipe_rx_start_block: beats are ignored until a start_block, and a
// start_block mid-flit restarts capture.  A completed flit is held (flit_valid)
// until the deframer takes it.
//
// PIPE Rx has no backpressure (docs/OPEN_DECISIONS.md D9): a flit completing
// while the previous one is still held is DROPPED and counted.  Any lost flit
// (overflow drop or a lock error) sets a gap marker that travels with the next
// flit handed to the deframer (flit_gap), so the deframer can abort the frame
// that lost data instead of splicing it onto later bytes.
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
  output logic                        flit_gap,        // >=1 flit lost before this one
  input  logic                        flit_taken,

  output logic                        idle,            // not mid-flit, nothing held
  output logic [15:0]                 dropped_flits,   // DV visibility (sticky count)
  output logic [15:0]                 lock_errors      // beats/start_block protocol slips
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic [FLIT_BYTES*8-1:0] cap_q, flit_q;
  logic [CW-1:0]           cnt_q;
  logic                    locked_q, full_q, gap_q, lost_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_q         <= '0;
      flit_q        <= '0;
      cnt_q         <= '0;
      locked_q      <= 1'b0;
      full_q        <= 1'b0;
      gap_q         <= 1'b0;
      lost_q        <= 1'b0;
      dropped_flits <= '0;
      lock_errors   <= '0;
    end else begin
      if (full_q && flit_taken) full_q <= 1'b0;

      if (pipe_rx_data_valid) begin
        if (pipe_rx_start_block) begin
          if (locked_q) begin
            lock_errors <= lock_errors + 16'd1;   // start_block mid-flit
            lost_q      <= 1'b1;
          end
          cap_q[PIPE_BUS_W-1:0] <= pipe_rx_data;
          cnt_q    <= CW'(1);
          locked_q <= 1'b1;
        end else if (locked_q) begin
          cap_q[int'(cnt_q)*PIPE_BUS_W +: PIPE_BUS_W] <= pipe_rx_data;
          if (int'(cnt_q) == FLIT_BEATS - 1) begin
            locked_q <= 1'b0;
            cnt_q    <= '0;
            if (full_q && !flit_taken) begin
              dropped_flits <= dropped_flits + 16'd1;
              lost_q        <= 1'b1;
            end else begin
              flit_q <= cap_q;
              flit_q[(FLIT_BEATS-1)*PIPE_BUS_W +: PIPE_BUS_W] <= pipe_rx_data;
              full_q <= 1'b1;
              gap_q  <= lost_q;
              lost_q <= 1'b0;
            end
          end else begin
            cnt_q <= cnt_q + CW'(1);
          end
        end else begin
          lock_errors <= lock_errors + 16'd1;     // data outside a flit
          lost_q      <= 1'b1;
        end
      end else if (locked_q) begin
        locked_q    <= 1'b0;                      // valid dropped mid-flit
        cnt_q       <= '0;
        lock_errors <= lock_errors + 16'd1;
        lost_q      <= 1'b1;
      end
    end
  end

  assign flit_valid = full_q;
  assign flit       = flit_q;
  assign flit_gap   = gap_q;
  assign idle       = !locked_q && !full_q;

endmodule : rx_ingress
