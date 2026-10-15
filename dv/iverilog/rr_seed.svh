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
  int          rr_seed = 0, rr_gap_max = 0, rr_rdy_min = 100, rr_lat = 8, rr_rst_cyc = 16, rr_idle_max = 0;

  function int rr_range(input int lo, input int hi);
    begin
      rr_state = rr_state * 32'd1664525 + 32'd1013904223;
      rr_range = lo + int'((rr_state >> 8) % (hi - lo + 1));
    end
  endfunction

  function void rr_init();
    int burn;
    begin
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
    begin rr_gap = rr_on ? (base + rr_range(0, rr_gap_max)) : base; end
  endfunction
  // sink tready percentage: base, lowered to a seeded value >= rr_rdy_min
  function int rr_rdy(input int base);
    int v;
    begin
      v = rr_on ? rr_range(rr_rdy_min, 100) : base;
      rr_rdy = (v < base) ? v : base;
    end
  endfunction
  // extra idle cycles (message-bus TB)
  function int rr_idle();
    begin rr_idle = rr_on ? rr_range(0, rr_idle_max) : 0; end
  endfunction
