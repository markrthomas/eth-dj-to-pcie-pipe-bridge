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
LIB     := $(abspath $(BUILD)/nangate45.lib)
OUTABS  := $(abspath $(BUILD))
# GLS dump window in ps (traffic-heavy part of the 7-scenario run; whole run is ~204 us)
TFROM   ?= 8000000
TTO     ?= 28000000

.PHONY: deps generic map cells gls power power-oss clean
power-oss: power

deps: $(LIB) $(BUILD)/venv/bin/python
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

gls: $(BUILD)/gls.vcd
$(BUILD)/gls.vcd: $(BUILD)/bridge_gl.v $(BUILD)/cells_sim.v $(ROOT)/dv/vlt/sim_main.cpp $(ROOT)/dv/common/cpp/bridge_bfm.h
	cd $(BUILD) && $(VERILATOR) --cc --exe --build -j $$(nproc) -O2 --x-assign unique --x-initial unique \
	  --trace-fst -Wno-fatal -Wno-lint -Wno-style --Mdir gls_obj --top-module eth_dj_pipe7_bridge \
	  -CFLAGS "-I$(abspath $(ROOT)/dv/common/cpp) -O1" bridge_gl.v cells_sim.v $(abspath $(ROOT)/dv/vlt/sim_main.cpp)
	cd $(BUILD) && ./gls_obj/Veth_dj_pipe7_bridge +trace +trace_file=gls.fst +trace_from=$(TFROM) +trace_to=$(TTO) | tee gls.log
	@grep -q "VLT PASS" $(BUILD)/gls.log
	fst2vcd $(BUILD)/gls.fst > $@

power: $(BUILD)/power.json
$(BUILD)/power.json: $(BUILD)/gls.vcd $(BUILD)/bridge_gl.v deps power.py
	$(PY) power.py --lib $(LIB) --netlist $(BUILD)/bridge_gl.v --vcd $(BUILD)/gls.vcd --out $@

clean:
	rm -rf $(BUILD)
