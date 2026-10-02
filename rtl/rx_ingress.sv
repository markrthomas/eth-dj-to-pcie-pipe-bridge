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
//
// Link flow control (FLOW_CTRL, docs/OPEN_DECISIONS.md D16).  Each flit is examined the
// cycle it finishes arriving, independent of whether the previous flit is still held:
//  * its seq field is compared with the number of data flits expected; a gap means flits
//    were lost (counted in fc_lost_cnt, and the next stored flit gets flit_gap);
//  * its cl field (the remote's cumulative credit limit) is merged into fc_cl_remote;
//  * a credit-only flit (count 0, sof = eof = 0) is consumed here and never stored, so it
//    cannot be dropped for lack of a slot;
//  * a data flit dropped because the slot is busy is added to fc_lost_cnt (it will never
//    be deframed, so its credit must be given back).
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
  output logic [15:0]                 lock_errors,     // beats/start_block protocol slips
  output logic [15:0]                 fc_cl_remote,    // remote credit limit (FLOW_CTRL)
  output logic [15:0]                 fc_lost_cnt      // cumulative data flits lost or dropped (FLOW_CTRL)
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic [FLIT_BYTES*8-1:0] cap_q, flit_q;
  logic [CW-1:0]           cnt_q;
  logic                    locked_q, full_q, gap_q, lost_q;
  logic [15:0]             exp_q;                 // data flits expected so far (FLOW_CTRL)

  // ---- flow-control view of the flit completing this cycle -----------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  logic [FLIT_BYTES*8-1:0] arr_flit;      // only header + flow-control bytes are examined
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    arr_flit = cap_q;
    arr_flit[(FLIT_BEATS-1)*PIPE_BUS_W +: PIPE_BUS_W] = pipe_rx_data;
  end
  wire        arr_last  = pipe_rx_data_valid && !pipe_rx_start_block && locked_q &&
                          (int'(cnt_q) == FLIT_BEATS - 1);
  wire [7:0]  arr_plen  = arr_flit[15:8];
  wire        arr_data  = (arr_plen != 8'd0);
  wire        arr_cr    = (arr_plen == 8'd0) && !arr_flit[1] && !arr_flit[2];
  wire        arr_ok    = FLOW_CTRL && arr_last && arr_flit[0] &&
                          ((arr_data && int'(arr_plen) <= FLIT_PAYLOAD_B) || arr_cr);
  wire [15:0] arr_seq   = arr_flit[8*FLIT_FC_OFF +: 16];
  wire [15:0] arr_cl    = arr_flit[8*(FLIT_FC_OFF+2) +: 16];
  wire [15:0] seq_gapn  = arr_seq - exp_q;                       // flits missing before this one
  wire        seq_back  = seq_gapn[15];                          // "behind" expected: resync, no loss
  wire        seq_gap   = arr_ok && (seq_gapn != 16'd0);
  wire        drop_now  = arr_last && !(arr_ok && arr_cr) && full_q && !flit_taken;
  wire [15:0] lost_add  = arr_ok ? ((seq_back ? 16'd0 : seq_gapn) + ((arr_data && drop_now) ? 16'd1 : 16'd0))
                                 : 16'd0;

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
      exp_q         <= '0;
      fc_cl_remote  <= '0;
      fc_lost_cnt   <= '0;
    end else begin
      if (full_q && flit_taken) full_q <= 1'b0;

      if (arr_ok) begin
        exp_q       <= arr_seq + (arr_data ? 16'd1 : 16'd0);
        fc_lost_cnt <= fc_lost_cnt + lost_add;
        if (!(arr_cl - fc_cl_remote > 16'h7FFF)) fc_cl_remote <= arr_cl;   // keep the newest (modular)
      end

      if (pipe_rx_data_valid) begin
        if (pipe_rx_start_block) begin
          if (locked_q) begin
            lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;   // start_block mid-flit
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
            if (arr_ok && arr_cr) begin
              if (seq_gap) lost_q <= 1'b1;         // credit-only: consumed, never stored
            end else if (full_q && !flit_taken) begin
              dropped_flits <= (&dropped_flits) ? dropped_flits : dropped_flits + 16'd1;
              lost_q        <= 1'b1;
            end else begin
              flit_q <= cap_q;
              flit_q[(FLIT_BEATS-1)*PIPE_BUS_W +: PIPE_BUS_W] <= pipe_rx_data;
              full_q <= 1'b1;
              gap_q  <= lost_q | seq_gap;
              lost_q <= 1'b0;
            end
          end else begin
            cnt_q <= cnt_q + CW'(1);
          end
        end else begin
          lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;     // data outside a flit
          lost_q      <= 1'b1;
        end
      end else if (locked_q) begin
        locked_q    <= 1'b0;                      // valid dropped mid-flit
        cnt_q       <= '0;
        lock_errors <= (&lock_errors) ? lock_errors : lock_errors + 16'd1;
        lost_q      <= 1'b1;
      end
    end
  end

  assign flit_valid = full_q;
  assign flit       = flit_q;
  assign flit_gap   = gap_q;
  assign idle       = !locked_q && !full_q;

endmodule : rx_ingress
