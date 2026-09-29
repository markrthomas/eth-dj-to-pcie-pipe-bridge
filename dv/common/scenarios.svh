// ============================================================================
// scenarios.svh — SystemVerilog view of the shared scenario set
// (dv/common/scenarios.py is the golden definition; keep the two in sync).
// `include inside a module/class scope that also includes eth_dj_pat.svh.
//   scenario index: 0 single, 1 corners, 2 random, 3 pm_cycle, 4 rate_change
//   ctrl kind     : 0 none, 1 pm_cycle, 2 rate_change
// ============================================================================
localparam int SCEN_N = 5;

function automatic string scen_name(input int s);
  case (s)
    0: scen_name = "single";
    1: scen_name = "corners";
    2: scen_name = "random";
    3: scen_name = "pm_cycle";
    default: scen_name = "rate_change";
  endcase
endfunction

function automatic int scen_ctrl(input int s);
  scen_ctrl = (s == 3) ? 1 : (s == 4) ? 2 : 0;
endfunction

function automatic int scen_nframes(input int s);
  case (s)
    0: scen_nframes = 1;
    1: scen_nframes = 11;
    2: scen_nframes = 40;
    default: scen_nframes = 16;
  endcase
endfunction

function automatic int scen_seed(input int s);
  scen_seed = (s == 2) ? 32'hC0FFEE : (s == 3) ? 7 : 11;
endfunction

// Length of frame i of scenario s (LCG replayed from the seed each call).
function automatic int scen_len(input int s, input int i);
  longint unsigned x;
  int r;
  begin
    r = 0;
    if (s == 0) r = 64;
    else if (s == 1) begin
      case (i)
        0: r = 1;    1: r = 31;   2: r = 32;   3: r = 33;   4: r = 239; 5: r = 240;
        6: r = 241;  7: r = 480;  8: r = 481;  9: r = 1500; default: r = 9000;
      endcase
    end else begin
      x = longint'(scen_seed(s)) & 64'h7FFF_FFFF;
      for (int k = 0; k <= i; k++) x = (64'd1103515245 * x + 64'd12345) & 64'h7FFF_FFFF;
      r = 1 + int'((x >> 8) % 64'd2000);
    end
    scen_len = r;
  end
endfunction

// CRC-32 (IEEE, reflected) running state: start 32'hFFFF_FFFF, final = ~state.
function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] b);
  logic [31:0] r;
  begin
    r = c ^ {24'h0, b};
    for (int k = 0; k < 8; k++) r = r[0] ? ((r >> 1) ^ 32'hEDB8_8320) : (r >> 1);
    crc32_byte = r;
  end
endfunction
