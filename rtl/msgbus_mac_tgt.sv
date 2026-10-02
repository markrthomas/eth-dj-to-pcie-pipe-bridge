// ============================================================================
// msgbus_mac_tgt.sv — pclk domain.  MAC-side PIPE message-bus TARGET + M2P arbiter.
//
// PIPE 7.1 §6.1.4 lets the PHY initiate reads/writes to MAC registers over P2M and
// requires the MAC to answer on M2P: a write_ack after a write_committed, and a
// read_completion after a read.  This block
//   * frames P2M by transaction length (same rules as pipe_msgbus: only a transaction's
//     first byte is a command; write_* 3 cycles, read/read_completion 2, others 1),
//   * accepts PHY write_committed (-> one write_ack), write_uncommitted (no response; buffered
//     and applied together with the next write_committed, same cycle) and read
//     (-> read_completion of the stored value), and ignores the PHY's read_completion /
//     write_ack (responses to the bridge's own master),
//   * shares the single M2P byte bus with the bridge's message-bus master: a response
//     transaction is never inserted inside the master's 3-byte frame, and the master's
//     request is never started during a response (rule 4: contiguous cycles).
//
// MAC REGISTERS (PIPE 7.1 §7.2, Table 7-25): the PHY writes status into the MAC's register
// file.  Implemented as plain 8-bit storage, reset value 0 (every §7.2 default is 0h), for
// the defined addresses only: Rx 12'h0-7, 12'hA-12'h10; Tx 12'h400-12'h40C; Cmn 12'h800
// (+12'h200 for the RX2 / TX2 / CMN2 windows).  Reserved / unmapped addresses read 8'h00
// and writes to them are ignored (still acknowledged).  The bridge does not consume any
// of these fields (no margining, EB, recalibration); they exist so a PHY's status writes
// are retained and readable.  Field attributes (1-cycle / level) and reserved bits are
// NOT modelled: whole bytes are stored as written.  write_uncommitted entries go into a
// write buffer of WB_DEPTH (spec minimum 5) and are applied, in order, in the same cycle
// as the write_committed that follows them (§6.1.4.1); an uncommitted write with the
// buffer full is dropped and counted in drop_cnt.  docs/OPEN_DECISIONS.md D8 / D17.
//
// Arbitration: the FSM's request is latched and started from A_IDLE, the master has priority
// over a pending response (so a PHY that floods requests cannot starve the bridge's write);
// a response is sent from A_IDLE when no request is pending.  At most one write_ack and one
// read_completion can be outstanding; a third request while one is pending is dropped and
// counted in drop_cnt.
// ============================================================================
`include "eth_dj_pipe7_pkg.sv"

module msgbus_mac_tgt
  import eth_dj_pipe7_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,

  // request from the control FSM (pulse) — latched here
  input  logic                     fsm_req,
  input  logic [MB_ADDR_W-1:0]     fsm_addr,
  input  logic [7:0]               fsm_wdata,

  // to / from the pipe_msgbus master
  output logic                     m_req,
  output logic [MB_ADDR_W-1:0]     m_addr,
  output logic [7:0]               m_wdata,
  input  logic                     m_busy,        // master is mid-transaction (incl. waiting for its ack)
  input  logic                     m_tx_active,   // master is driving byte0/byte1 of its frame
  input  logic [MSGBUS_W-1:0]      m_m2p,

  // message bus
  input  logic [MSGBUS_W-1:0]      p2m,
  output logic [MSGBUS_W-1:0]      m2p,

  // observation (DV / SVA)
  output logic                     tgt_tx,        // this block is driving M2P
  output logic [15:0]              phy_wr_cnt,    // PHY write_committed accepted
  output logic [15:0]              phy_rd_cnt,    // PHY reads answered
  output logic [15:0]              drop_cnt,      // PHY requests dropped (response still pending)
  output logic [MB_ADDR_W-1:0]     last_wr_addr,
  output logic [7:0]               last_wr_data
);
  // ---- MAC register file (Table 7-25) --------------------------------------------------------
  localparam int NREG_WIN = 29;                  // per window: 15 Rx + 13 Tx + 1 Cmn
  localparam int WB_DEPTH = 8;                   // write buffer entries (spec minimum 5)

  // register index of an address, -1 when reserved / unmapped
  function automatic int reg_idx(input logic [MB_ADDR_W-1:0] a);
    int o, base;
    begin
      reg_idx = -1;
      o = int'(a[8:0]);
      base = a[9] ? NREG_WIN : 0;                // RX2 / TX2 / CMN2 windows mirror the layout
      case (a[11:10])
        2'b00: begin                             // Rx: 0-7, A-10h
          if (o <= 7)                   reg_idx = base + o;
          else if (o >= 10 && o <= 16)  reg_idx = base + 8 + (o - 10);
        end
        2'b01: if (o <= 12)             reg_idx = base + 15 + o;              // Tx Status0-12
        2'b10: if (o == 0)              reg_idx = base + 28;                  // Near End Loopback Status
        default: ;
      endcase
    end
  endfunction

  logic [7:0] regs_q [0:2*NREG_WIN-1];
  logic [MB_ADDR_W-1:0] wb_a_q [0:WB_DEPTH-1];
  logic [7:0]           wb_d_q [0:WB_DEPTH-1];
  int unsigned          wb_n_q;

  function automatic logic [7:0] mac_rd_data(input logic [MB_ADDR_W-1:0] a);
    int i;
    begin
      i = reg_idx(a);
      mac_rd_data = (i >= 0) ? regs_q[i] : 8'h00;
    end
  endfunction

  // ---- P2M framer + transaction decode --------------------------------------------------
  logic [1:0]            rem_q;
  logic [3:0]            cmd_q, ahi_q;
  logic [7:0]            alo_q;
  logic                  pend_ack_q, pend_rd_q;
  logic [MB_ADDR_W-1:0]  rd_addr_q;
  logic                  ack_sent, rd_sent;       // response completed this cycle (from the sender)

  wire p2m_start = (rem_q == 2'd0) && (p2m != 8'h00);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rem_q <= 2'd0; cmd_q <= 4'd0; ahi_q <= 4'd0; alo_q <= 8'd0;
      pend_ack_q <= 1'b0; pend_rd_q <= 1'b0; rd_addr_q <= '0;
      phy_wr_cnt <= '0; phy_rd_cnt <= '0; drop_cnt <= '0;
      last_wr_addr <= '0; last_wr_data <= '0;
      wb_n_q <= 0;
      for (int r = 0; r < 2*NREG_WIN; r++) regs_q[r] <= 8'h00;
      for (int w = 0; w < WB_DEPTH; w++) begin wb_a_q[w] <= '0; wb_d_q[w] <= 8'h00; end
    end else begin
      if (ack_sent) pend_ack_q <= 1'b0;
      if (rd_sent)  pend_rd_q  <= 1'b0;

      if (rem_q != 2'd0) begin
        rem_q <= rem_q - 2'd1;
        case (cmd_q)
          MB_WR_UC, MB_WR_C: begin
            if (rem_q == 2'd2) alo_q <= p2m;                       // addr[7:0]
            else if (cmd_q == MB_WR_UC) begin                      // data byte: buffer
              if (wb_n_q < WB_DEPTH) begin
                wb_a_q[wb_n_q] <= {ahi_q, alo_q};
                wb_d_q[wb_n_q] <= p2m;
                wb_n_q         <= wb_n_q + 1;
              end else begin
                drop_cnt <= drop_cnt + 16'd1;                      // write buffer full
              end
            end else begin                                         // data byte: commit
              if (pend_ack_q && !ack_sent) begin
                drop_cnt <= drop_cnt + 16'd1;                      // previous ack not yet sent
              end else begin
                pend_ack_q   <= 1'b1;
                phy_wr_cnt   <= phy_wr_cnt + 16'd1;
                last_wr_addr <= {ahi_q, alo_q};
                last_wr_data <= p2m;
                // apply the buffered writes in order, then this one (later entries win)
                for (int w = 0; w < WB_DEPTH; w++)
                  if (w < int'(wb_n_q) && reg_idx(wb_a_q[w]) >= 0) regs_q[reg_idx(wb_a_q[w])] <= wb_d_q[w];
                if (reg_idx({ahi_q, alo_q}) >= 0) regs_q[reg_idx({ahi_q, alo_q})] <= p2m;
                wb_n_q <= 0;
              end
            end
          end
          MB_RD: begin                                             // addr[7:0]
            if (pend_rd_q && !rd_sent) begin
              drop_cnt <= drop_cnt + 16'd1;
            end else begin
              pend_rd_q  <= 1'b1;
              rd_addr_q  <= {ahi_q, p2m};
              phy_rd_cnt <= phy_rd_cnt + 16'd1;
            end
          end
          default: ;                                               // read_completion data: ignored
        endcase
      end else if (p2m_start) begin
        cmd_q <= p2m[7:4];
        ahi_q <= p2m[3:0];
        case (p2m[7:4])
          MB_WR_UC, MB_WR_C: rem_q <= 2'd2;
          MB_RD, MB_RD_CPL:  rem_q <= 2'd1;
          default:           rem_q <= 2'd0;                        // write_ack, NOP, reserved
        endcase
      end
    end
  end

  // ---- arbiter + response sender -------------------------------------------------------------
  typedef enum logic [1:0] { A_IDLE, A_MST, A_TGT } arb_e;
  arb_e arb_q;

  logic                 fsm_pend_q, seen_tx_q;
  logic [MB_ADDR_W-1:0] addr_q;
  logic [7:0]           wdata_q;
  logic                 kind_rd_q;      // response in flight: 0 = write_ack, 1 = read_completion
  logic                 step_q;         // read_completion: 0 = command byte, 1 = data byte
  logic [7:0]           rd_data_q;

  // m_req only while the master is idle: a request pulsed into a busy pipe_msgbus is ignored there,
  // which would leave the arbiter in A_MST forever (it would wait for a frame that never starts)
  assign m_req   = (arb_q == A_IDLE) && fsm_pend_q && !m_busy;
  assign m_addr  = addr_q;
  assign m_wdata = wdata_q;
  assign tgt_tx  = (arb_q == A_TGT);

  always_comb begin
    m2p     = m_m2p;
    ack_sent = 1'b0;
    rd_sent  = 1'b0;
    if (arb_q == A_TGT) begin
      if (!kind_rd_q)      m2p = {MB_WR_ACK, 4'h0};
      else if (!step_q)    m2p = {MB_RD_CPL, 4'h0};
      else                 m2p = rd_data_q;
      if (!kind_rd_q)                   ack_sent = 1'b1;
      else if (step_q)                  rd_sent  = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_q <= A_IDLE; fsm_pend_q <= 1'b0; seen_tx_q <= 1'b0;
      addr_q <= '0; wdata_q <= '0; kind_rd_q <= 1'b0; step_q <= 1'b0; rd_data_q <= 8'h00;
    end else begin
      if (fsm_req) begin                       // latch the FSM's request
        fsm_pend_q <= 1'b1;
        addr_q     <= fsm_addr;
        wdata_q    <= fsm_wdata;
      end
      case (arb_q)
        A_IDLE: begin
          if (fsm_pend_q && !m_busy) begin     // master has priority; m_req pulses this cycle
            fsm_pend_q <= fsm_req;             // (a back-to-back new request stays pending)
            arb_q      <= A_MST;
            seen_tx_q  <= 1'b0;
          end else if (pend_ack_q || pend_rd_q) begin
            arb_q     <= A_TGT;
            step_q    <= 1'b0;
            kind_rd_q <= !pend_ack_q;          // write_ack first, then the read_completion
            rd_data_q <= mac_rd_data(rd_addr_q);
          end
        end
        A_MST: begin                           // master is driving its frame
          if (m_tx_active) seen_tx_q <= 1'b1;
          if (seen_tx_q && !m_tx_active) arb_q <= A_IDLE;
        end
        default: begin                         // A_TGT
          if (!kind_rd_q || step_q) arb_q <= A_IDLE;
          else                      step_q <= 1'b1;
        end
      endcase
    end
  end
endmodule : msgbus_mac_tgt
