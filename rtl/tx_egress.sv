// ============================================================================
// tx_egress.sv — pclk domain.  Serialises a completed flit onto the PIPE Tx
// datapath, PIPE_BUS_W bits per beat (LSB byte first), FLIT_BEATS beats, with
// pipe_tx_start_block on the first beat.  A flit is only started while the link
// is in P0 (tx_en); once started it always completes.
//
// Link flow control (FLOW_CTRL, docs/OPEN_DECISIONS.md D16): a data flit only starts while
// credit_ok; every flit gets its seq / cl fields overlaid (latched at flit start) at
// FLIT_FC_OFF; and when a credit update is wanted (cr_req) and no data flit can go, a
// credit-only flit (valid, count 0) is generated here.  With FLOW_CTRL = 0 all of this
// elaborates away and the module is unchanged.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module tx_egress
  import eth_dj_pipe7_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic                        tx_en,

  input  logic                        flit_valid,
  input  logic [FLIT_BYTES*8-1:0]     flit,
  output logic                        flit_taken,

  input  logic                        credit_ok,
  input  logic                        cr_req,
  input  logic [15:0]                 seq_now,
  input  logic [15:0]                 cl_now,
  output logic                        st_any,
  output logic                        st_data,

  output logic [PIPE_BUS_W-1:0]       pipe_tx_data,
  output logic                        pipe_tx_data_valid,
  output logic                        pipe_tx_start_block,
  output logic                        busy
);
  localparam int unsigned CW = $clog2(FLIT_BEATS);

  logic          busy_q;
  logic [CW-1:0] cnt_q;
  logic          cr_q;               // current flit is a credit-only flit
  logic [15:0]   seq_q, cl_q;        // fields latched at flit start

  wire start_data = !busy_q && flit_valid && tx_en && (!FLOW_CTRL || credit_ok);
  wire start_cr   = FLOW_CTRL && !busy_q && tx_en && cr_req && !start_data;
  wire start      = start_data || start_cr;

  assign busy    = busy_q;
  assign st_any  = start;
  assign st_data = start_data;

  wire last_beat = busy_q && (int'(cnt_q) == FLIT_BEATS - 1);
  assign flit_taken = last_beat && !cr_q;

  // fields in effect this cycle (live at the start cycle, latched afterwards)
  wire          use_cr = start ? start_cr : cr_q;
  wire [15:0]   seq_e  = start ? seq_now  : seq_q;
  wire [15:0]   cl_e   = start ? cl_now   : cl_q;

  logic [FLIT_BYTES*8-1:0] eff;
  always_comb begin
    eff = flit;
    if (FLOW_CTRL) begin
      if (use_cr) begin
        eff       = '0;
        eff[7:0]  = 8'h01;                          // valid, sof = eof = 0, count = 0
      end
      eff[8*FLIT_FC_OFF +: 16]       = seq_e;
      eff[8*(FLIT_FC_OFF+2) +: 16]   = cl_e;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q              <= 1'b0;
      cnt_q               <= '0;
      cr_q                <= 1'b0;
      seq_q               <= '0;
      cl_q                <= '0;
      pipe_tx_data        <= '0;
      pipe_tx_data_valid  <= 1'b0;
      pipe_tx_start_block <= 1'b0;
    end else if (start) begin
      busy_q              <= 1'b1;
      cnt_q               <= CW'(1);
      cr_q                <= start_cr;
      seq_q               <= seq_now;
      cl_q                <= cl_now;
      pipe_tx_data        <= eff[PIPE_BUS_W-1:0];
      pipe_tx_data_valid  <= 1'b1;
      pipe_tx_start_block <= 1'b1;
    end else if (busy_q) begin
      pipe_tx_data        <= eff[int'(cnt_q)*PIPE_BUS_W +: PIPE_BUS_W];
      pipe_tx_data_valid  <= 1'b1;
      pipe_tx_start_block <= 1'b0;
      if (last_beat) busy_q <= 1'b0;
      cnt_q               <= cnt_q + CW'(1);
    end else begin
      pipe_tx_data_valid  <= 1'b0;
      pipe_tx_start_block <= 1'b0;
    end
  end

endmodule : tx_egress
