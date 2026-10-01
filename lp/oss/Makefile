# lp/oss — zero-cost power flow (no commercial tool): Yosys (+slang) structural mapping to the
# Nangate45 liberty -> Verilator gate-level simulation of the mapped netlist (same C++ harness and
# golden-model checks as dv/vlt) -> OpenSTA (the pip `openroad` wheel) report_power from the
# simulation's switching activity.  See docs/power_intent.md ("OSS power flow").
#
#   make -C lp/oss deps        # liberty file + openroad wheel into build/  (needs network)
#   make -C lp/oss power-oss   # generic synth (~8 min, ~10 GB RAM, once) -> map -> GLS -> power
#
# ESTIMATE ONLY: Nangate45 (45 nm) typical corner, no placement / parasitics / clock tree.
# Needs the pinned OSS CAD Suite on PATH (yosys + slang, verilator, fst2vcd).  Do NOT set VERILATOR_ROOT.
BUILD   := build
ROOT    := ../..
YOSYS   ?= yosys
VERILATOR ?= verilator
PY      ?= $(BUILD)/venv/bin/python
LIB_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib
LEF_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/lef
LIB     := $(abspath $(BUILD)/nangate45.lib)
TECHLEF := $(abspath $(BUILD)/nangate45.tech.lef)
MACROLEF := $(abspath $(BUILD)/nangate45.macro.lef)
OUTABS  := $(abspath $(BUILD))
# VCD window in ns (2 us inside the traffic-heavy random scenario; the VCD grows with window x signals)
TON     ?= 12000
TOFF    ?= 14000

.PHONY: deps generic map cells gls gls-verify power power-oss clean
power-oss: power

deps: $(LIB) $(TECHLEF) $(MACROLEF) $(BUILD)/venv/bin/python
$(TECHLEF):
	mkdir -p $(BUILD)
	curl -fsSL -o $@ $(LEF_URL)/NangateOpenCellLibrary.tech.lef
$(MACROLEF):
	mkdir -p $(BUILD)
	curl -fsSL -o $@ $(LEF_URL)/NangateOpenCellLibrary.macro.lef
$(LIB):
	mkdir -p $(BUILD)
	curl -fsSL -o $@ $(LIB_URL)
$(BUILD)/venv/bin/python:
	mkdir -p $(BUILD)
	python3 -m venv $(BUILD)/venv
	$(BUILD)/venv/bin/pip install -q openroad

generic: $(BUILD)/bridge_generic.il
$(BUILD)/bridge_generic.il: synth_gen.ys $(wildcard $(ROOT)/rtl/*.sv)
	mkdir -p $(BUILD)
	sed 's|$${OUT}|$(OUTABS)|g' synth_gen.ys > $(BUILD)/synth_gen.ys
	cd $(ROOT) && $(YOSYS) -q -l $(OUTABS)/generic.log $(OUTABS)/synth_gen.ys

map: $(BUILD)/bridge_gl.v
$(BUILD)/bridge_gl.v: synth_map.ys $(BUILD)/bridge_generic.il $(LIB)
	sed 's|$${OUT}|$(OUTABS)|g; s|$${LIB}|$(LIB)|g' synth_map.ys > $(BUILD)/synth_map.ys
	cd $(ROOT) && $(YOSYS) -q -l $(OUTABS)/map.log $(OUTABS)/synth_map.ys

# gate-level simulation models generated from the liberty (functions + ff groups)
cells: $(BUILD)/cells_sim.v
$(BUILD)/cells_sim.v: $(LIB)
	$(YOSYS) -q -p "read_liberty -ignore_miss_func -ignore_miss_dir -ignore_miss_data_latch $(LIB); write_verilog -noattr $@"

# switching activity: Icarus gate-level run of the shared scenario TB with a short VCD window
# (Verilator cannot do this here: tracing the ~230k '_NNN_' nets exceeds 14 GB at verilation).
IVERILOG ?= iverilog
VVP      ?= vvp
COMMON   := $(ROOT)/dv/common
GLS_TB   := $(ROOT)/dv/iverilog/tb_scen.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv \
            $(COMMON)/pipe_phy_ctrl_model.sv $(COMMON)/eth_sink_model.sv
gls: $(BUILD)/gls_r.vcd
$(BUILD)/gls_r.vcd $(BUILD)/gls.vcd: $(BUILD)/bridge_gl.v $(BUILD)/cells_sim.v gls_dump.sv $(GLS_TB)
	$(IVERILOG) -g2012 -I $(ROOT)/rtl -I $(COMMON) -I $(ROOT)/dv/iverilog -s tb_scen -s gls_dump -o $(BUILD)/gls.vvp \
	  $(GLS_TB) gls_dump.sv $(BUILD)/bridge_gl.v $(BUILD)/cells_sim.v
	mkdir -p $(BUILD)/sim_build
	cd $(BUILD) && $(VVP) gls.vvp +ton=$(TON) +toff=$(TOFF) | tee gls.log
	python3 vcd_rebase.py $(BUILD)/gls.vcd $(BUILD)/gls_r.vcd

# functional equivalence of the mapped netlist: the full 7-scenario Verilator harness (same C++ BFM and
# golden-model checks as dv/vlt) on bridge_gl.v + liberty-derived cell models.  ~8 min, ~6 GB.
gls-verify: $(BUILD)/bridge_gl.v $(BUILD)/cells_sim.v $(ROOT)/dv/vlt/sim_main.cpp $(ROOT)/dv/common/cpp/bridge_bfm.h
	cd $(BUILD) && $(VERILATOR) --cc --exe --build -j $$(nproc) -O2 --x-assign unique --x-initial unique \
	  --trace-fst -Wno-fatal -Wno-lint -Wno-style --Mdir gls_obj --top-module eth_dj_pipe7_bridge \
	  -CFLAGS "-I$(abspath $(ROOT)/dv/common/cpp) -O1" bridge_gl.v cells_sim.v $(abspath $(ROOT)/dv/vlt/sim_main.cpp)
	cd $(BUILD) && ./gls_obj/Veth_dj_pipe7_bridge | tee gls_verify.log
	@grep -q "VLT PASS" $(BUILD)/gls_verify.log
	python3 $(COMMON)/crosscheck.py $(BUILD)/logs/results.json 2>/dev/null || true

power: $(BUILD)/power.json
$(BUILD)/power.json: $(BUILD)/gls_r.vcd $(BUILD)/bridge_gl.v deps power.py
	$(PY) power.py --lib $(LIB) --tech-lef $(TECHLEF) --macro-lef $(MACROLEF) --netlist $(BUILD)/bridge_gl.v --vcd $(BUILD)/gls_r.vcd --scope tb_scen/dut --out $@

clean:
	rm -rf $(BUILD)
