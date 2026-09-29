// Shared deterministic frame-byte pattern: byte idx of frame id.
// Used by the MAC model (generate) and by scoreboards (expect).
function automatic logic [7:0] pat(input int id, input int idx);
  pat = 8'((id * 37) + (idx * 13) + (idx >> 8) + 5);
endfunction
