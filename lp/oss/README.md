# lp/oss — zero-cost power / area flow (no commercial tool)

```
make -C lp/oss deps         # Nangate45 liberty + LEFs, `openroad` pip wheel (OpenSTA) into build/   (network)
make -C lp/oss generic      # Yosys+slang elaboration + generic synth, hierarchy kept   (~8.5 min, ~10-14 GB RAM, once)
make -C lp/oss map          # dfflibmap/abc to Nangate45 -> build/bridge_gl.v, build/stat.txt (area)     (~3 min)
make -C lp/oss gls-verify   # Verilator, full 7-scenario harness on the mapped netlist (functional equivalence) (~8 min, ~6 GB)
make -C lp/oss gls          # Icarus gate-level run of tb_scen, VCD window of 2 us -> rebased gls_r.vcd     (~17 min)
make -C lp/oss power        # OpenSTA report_power with that activity -> build/power.json                   (~1 min)
python3 metrics/collect.py --power-into-latest && make dashboard   # put the numbers on the dashboard
```
Needs the pinned OSS CAD Suite on PATH (yosys + slang, verilator, iverilog, fst2vcd). `build/` is git-ignored.

| Stage | Tool | Why this tool |
|---|---|---|
| structural mapping | Yosys (+slang), `dfflibmap` + `abc` | the 32 x 289-bit CDC FIFO arrays become ~9k flops each; Yosys is the only free mapper |
| functional check of the netlist | Verilator | reuses the dv/vlt C++ harness: all 7 scenarios, golden-model crc32s identical to the RTL |
| switching activity | Icarus | Verilator tracing of the ~230k `_NNN_` nets needs > 14 GB at verilation (OOM); Icarus dumps a window |
| power numbers | OpenSTA via the pip `openroad` wheel | `read_vcd` + `report_power`; needs the Nangate45 tech/macro LEF to link a netlist |

**Estimate only.** Nangate45 (45 nm) typical corner; no placement, parasitics or clock tree (the
"Clock" power group is 0); the FIFO arrays are flops (a real design would use SRAM / latch macros);
activity is a 2 us window of the `random` scenario at pclk 500 MHz / eth_clk 200 MHz. Use it to
compare options and for the order of magnitude, not as sign-off numbers. **It does not simulate UPF
semantics** (corruption, isolation, retention) - see docs/power_intent.md.

`vcd_rebase.py` shifts the VCD to start at #0: OpenSTA takes the activity window as [0, last
timestamp], so a VCD that only dumps 12-14 us would otherwise be diluted by 7x.
