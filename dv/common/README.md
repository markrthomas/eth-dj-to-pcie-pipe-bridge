# dv/common — shared BFMs, scenario set & helpers

- `eth_mac_model.sv` — 802.3dj MAC source BFM (AXI4-S master, `send_frame(id,len)`, `gap_pct`).
- `eth_sink_model.sv` — 802.3dj MAC sink BFM (AXI4-S slave, `ready_pct`), tkeep checker, frame reassembly.
- `pipe_phy_model.sv` — PIPE Tx sink + Gen6 flit monitor/checker; reassembles frames.
- `pipe_phy_ctrl_model.sv` — PhyStatus + message-bus target + "no Tx outside P0" checker.
- `eth_dj_pat.svh` — deterministic frame-byte pattern shared by generators/scoreboards.
- `scenarios.py` — **golden model** of the shared cross-env scenario set (PLAN §5);
  `scenarios.svh` is its SystemVerilog view (keep in sync).
- `crosscheck.py` — compares env `results.json` files with the golden model
  (`make crosscheck` requires all five envs).
- `cpp/bridge_bfm.h` — C++ BFMs + scenario sequencer shared by `dv/vlt` and `dv/systemc`.

Icarus-safe SV only (no `break`, no array literals). See docs/PLAN.md §3, §5 and
docs/OPEN_DECISIONS.md D12.
