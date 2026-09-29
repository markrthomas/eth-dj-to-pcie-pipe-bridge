# dv/uvm — DV env 3: Accellera UVM on Verilator

`make -C dv/uvm smoke` (or `make uvm` at the root) builds `tb_uvm_top` with
Verilator `--binary --timing` and runs `scen_test`: the shared five-scenario set
(`dv/common/scenarios.py`) on the PIPE-loopback harness. It writes
`logs/results.json` and runs `dv/common/crosscheck.py` on it.

- **Verilator version:** needs a UVM-capable Verilator (>= 5.03x). The CI-pinned
  OSS CAD Suite 2026-04-13 (Verilator 5.047) works. apt Verilator 5.020 fails to
  compile uvm-core (`PKGNODECL`). Keep `VERILATOR_ROOT` unset.
- **UVM library:** `uvm-core` (Accellera, 2020.3.1 line) is `git clone`d into
  `./uvm-core` at the commit pinned in `UVM_REF` the first time you build
  (git-ignored). Set `UVM_HOME=/path/to/uvm-core/src` to use an existing copy.
  Built with `+define+UVM_NO_DPI`.
- **Runtime:** first build ~2 min on 4 cores (compiles UVM), run a few seconds.
- **CI:** runs as the `uvm` job in `.github/workflows/ci.yml` (see
  `docs/OPEN_DECISIONS.md` D12).

Structure (`bridge_uvm_pkg.sv`): `eth_tx_driver` (sequence of `eth_frame_item`),
`eth_rx_monitor` -> `bridge_sb` scoreboard (in-order byte compare + CRC-32),
`pipe_phy_driver` (PhyStatus + msgbus target + flit/Tx-legality checks),
`csr_agent`, `scen_test`.
