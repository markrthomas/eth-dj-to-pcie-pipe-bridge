# dv/common — shared BFMs & helpers

- `eth_mac_model.sv` — 802.3dj MAC source BFM (AXI4-S master, `send_frame(id,len)`, `gap_pct`).
- `pipe_phy_model.sv` — PIPE Tx sink + Gen6 flit monitor/checker; reassembles frames.
- `eth_dj_pat.svh` — deterministic frame-byte pattern shared by generators/scoreboards.

Icarus-safe SV only (no `break`, no array literals). See docs/PLAN.md §3, §5.
- `eth_sink_model.sv` — 802.3dj MAC sink BFM (AXI4-S slave, `ready_pct`), tkeep checker, frame reassembly.
