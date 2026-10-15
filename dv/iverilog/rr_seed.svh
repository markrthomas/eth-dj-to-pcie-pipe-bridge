// ============================================================================
// dv/iverilog/rr_seed.svh — random-regression seeding, `include'd inside a test module body.
// +seed=N turns it on; without the plusarg every rr_* helper returns its base value and the
// $urandom stream is untouched, so the directed runs are bit-identical.  With +seed=N:
//   * the shared $urandom stream is shifted by a seed-derived number of draws (frame lengths,
//     MAC gaps and sink back-pressure then differ per seed),
//   * a per-run profile is drawn from a private LCG (never from $urandom): maximum extra MAC
//     gap, minimum sink ready %, PHY-ctrl latency / reset cycles, extra idle cycles.
// Call rr_init() once, first thing in the main initial block (before any $urandom draw).
// Knob ranges keep the stimulus legal: sinks never fall below rr_rdy_min, so the TBs' timeouts
// (sized for the directed runs) stay valid; deliberate stall phases are left literal in the TBs.
// ============================================================================
  bit          rr_on = 1'b0;
  int unsigned rr_state = 32'd1;
  int          rr_rdy_force = -1;   // +rr_rdy=N pins EVERY sink ready% to N (debug knob; also works without +seed)
  int          rr_seed = 0, rr_gap_max = 0, rr_rdy_min = 100, rr_lat = 8, rr_rst_cyc = 16, rr_idle_max = 0;

  int          rr_last_gap = 0;      // last MAC gap % handed out by rr_gap (rr_rdy floors the sink against it at x2/x4)
  int          rr_x4_margin = 10;    // +rr_margin=N: sink-ready margin (%) above the MAC duty cycle when PIPE_NLANES > 1

  function int rr_range(input int lo, input int hi);
    begin
      rr_state = rr_state * 32'd1664525 + 32'd1013904223;
      rr_range = lo + int'((rr_state >> 8) % (hi - lo + 1));
    end
  endfunction

  function void rr_init();
    int burn;
    begin
      void'($value$plusargs("rr_margin=%d", rr_x4_margin));
      if ($value$plusargs("rr_rdy=%d", rr_rdy_force)) $display("RR rr_rdy forced to %0d", rr_rdy_force);
      if ($value$plusargs("seed=%d", rr_seed)) begin
        rr_on       = 1'b1;
        rr_state    = 32'(rr_seed) * 32'd2654435761 + 32'd12345;
        rr_gap_max  = rr_range(0, 40);
        rr_rdy_min  = rr_range(50, 100);
        rr_lat      = rr_range(2, 20);
        rr_rst_cyc  = rr_range(4, 32);
        rr_idle_max = rr_range(0, 6);
        burn        = rr_range(0, 20000);
        for (int i = 0; i < burn; i++) void'($urandom);
        $display("RR seed=%0d gap_max=%0d rdy_min=%0d lat=%0d rst_cycles=%0d idle_max=%0d",
                 rr_seed, rr_gap_max, rr_rdy_min, rr_lat, rr_rst_cyc, rr_idle_max);
      end
    end
  endfunction

  // MAC idle-cycle percentage: base (+ up to rr_gap_max when seeded)
  function int rr_gap(input int base);
    begin rr_gap = rr_on ? (base + rr_range(0, rr_gap_max)) : base; rr_last_gap = rr_gap; end
  endfunction
  // sink tready percentage: base, lowered to a seeded value >= rr_rdy_min.
  // Stimulus contract at PIPE_NLANES > 1 (D1/D9, rr-dbg-x4): PIPE Rx cannot be back-pressured, and from x2 up the Tx framer
  // is no longer the bottleneck (it is at x1: single-buffered, 64 bit/pclk < the 256 bit/eth_clk MAC), so a MAC that
  // streams faster than the sink drains overruns the Rx path and the deframer drops + aborts frames (the documented D9
  // behaviour, counted in RXCNT0/1).  The seeded sink is therefore never slower than the MAC duty cycle
  // (100 - last rr_gap) plus rr_x4_margin; it is still lowered to rr_rdy_min where that leaves room.  The RNG draw
  // count is unchanged, so x1 runs are bit-identical.  +rr_rdy=N overrides everything (debug).
  function int rr_rdy(input int base);
    int v, lo;
    begin
      if (rr_rdy_force >= 0) begin rr_rdy = rr_rdy_force; return rr_rdy; end
      v = rr_on ? rr_range(rr_rdy_min, 100) : base;
      v = (v < base) ? v : base;
      if (rr_on && PIPE_NLANES > 1) begin      // the floor beats the TB's base value (scen: base 90 < MAC duty + margin)
        lo = 100 - rr_last_gap + rr_x4_margin;
        if (lo > 100) lo = 100;
        if (v < lo) v = lo;
      end
      rr_rdy = v;
    end
  endfunction
  // extra idle cycles (message-bus TB)
  function int rr_idle();
    begin rr_idle = rr_on ? rr_range(0, rr_idle_max) : 0; end
  endfunction
