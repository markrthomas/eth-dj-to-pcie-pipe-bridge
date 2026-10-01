# =============================================================================
# eth-dj-pcie-pipe7_1-bridge — root DV gate.
#
# Standard targets per ~/proj/DV_STANDARDS.md.  All targets are real except
# `upf`, which prints an "authored, not run" notice (no OSS power-aware
# simulator; `upf-tb` runs the power-aware TB functionally).  See docs/PLAN.md §8.
#
# Toolchain: Verilator + Icarus from the workspace OSS CAD Suite. Do NOT set
# VERILATOR_ROOT (breaks the UVM-on-Verilator flow — see docs/AGENT_HANDOFF.md).
# Version pins: ~/proj/dv_env.mk (OSS_CAD_SUITE_VERSION, cocotb==1.8.1).
# =============================================================================

VERILATOR ?= verilator
IVERILOG  ?= iverilog

RTL_DIR := rtl
TOP     := eth_dj_pipe7_bridge
RTL_TOP := $(RTL_DIR)/$(TOP).sv
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/bridge_ctrl_fsm.sv $(RTL_DIR)/bridge_rf.sv $(RTL_TOP)

.PHONY: default help lint sim regress coverage formal ci envs envs-fc vlt-fc systemc-fc uvm-fc cocotb-fc pd-emu crosscheck \
        iverilog vlt uvm systemc cocotb waves wave-check-all upf upf-tb metrics dashboard stress clean

default: help

help:
	@echo "eth-dj-pcie-pipe7_1-bridge — targets:"
	@echo "  lint       Verilator --lint-only -Wall on rtl/"
	@echo "  sim        Icarus directed tests: smoke tx loop pm rxovf scen msgbus msgbus_mac link (flow control, 2 bridges)"
	@echo "  regress    lint + sim  — the fast CI gate"
	@echo "  coverage   Verilator C++ env with --coverage -> coverage.info (floor 80%)"
	@echo "  formal     SymbiYosys prove (PDR) + cover on formal/*.sby (OSS CAD Suite)"
	@echo "  iverilog|vlt|uvm|systemc|cocotb   run one DV environment (shared scenarios)"
	@echo "  crosscheck all five envs agree with dv/common/scenarios.py"
	@echo "  ci         regress + coverage + formal + all envs + crosscheck"
	@echo "  waves|wave-<test>  run a test with a VCD dump, check + open dv/waves/<test>.gtkw"
	@echo "  wave-check-all     check every test's .gtkw against a fresh dump (no GUI)"
	@echo "  upf        power-aware sim: commercial only -> prints authored-not-run notice"
	@echo "  upf-tb     functional Icarus run of the power-aware TB (PMU sequencing, no UPF)"
	@echo "  metrics    run+time METRICS_FLOWS, collect artifacts -> metrics/metrics.db"
	@echo "  dashboard  render metrics/metrics.db -> metrics/dashboard.html"
	@echo "  envs-fc    vlt/systemc/uvm/cocotb with link flow control ON (vlt-fc systemc-fc uvm-fc cocotb-fc)"
	@echo "  stress     vlt env, all scenarios x STRESS_SEEDS (default 20) seeds"
	@echo "  clean      remove build artifacts"
	@echo "  note: uvm needs a UVM-capable Verilator (>= 5.03x, e.g. OSS CAD Suite 2026-04-13)"

# ---- real M0 targets --------------------------------------------------------
lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -DFLOW_CTRL_OVERRIDE -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	@echo "lint: OK (default + FLOW_CTRL_OVERRIDE)"

sim: iverilog

iverilog:
	$(MAKE) -C dv/iverilog smoke tx loop pm rxovf scen msgbus msgbus_mac link fc

regress: lint sim
	@echo "regress: OK"

# ---- coverage / formal / environments ---------------------------------------
coverage:
	$(MAKE) -C dv/vlt coverage

# SymbiYosys prove + cover (formal/*.sby); needs the pinned OSS CAD Suite on PATH
formal:
	$(MAKE) -C formal

vlt:
	$(MAKE) -C dv/vlt smoke

uvm:
	$(MAKE) -C dv/uvm smoke

systemc:
	$(MAKE) -C dv/systemc smoke

cocotb:
	$(MAKE) -C dv/cocotb smoke

# Link flow control ON (D16, -DFLOW_CTRL_OVERRIDE) in the four non-iverilog envs; each runs
# the shared scenarios + its own (FC-aware) checkers + crosscheck.  iverilog: `make -C dv/iverilog fc`
# (part of `sim`).  Separate build/result dirs, default targets are unaffected.
vlt-fc:
	$(MAKE) -C dv/vlt fc

systemc-fc:
	$(MAKE) -C dv/systemc fc

uvm-fc:
	$(MAKE) -C dv/uvm fc

# UPF-like power-state emulation of PD_DP (cocotb on Icarus, ~45 s): corruption / isolation / retention matrix
pd-emu:
	$(MAKE) -C lp/cocotb pd

cocotb-fc:
	$(MAKE) -C dv/cocotb fc

envs-fc: vlt-fc systemc-fc uvm-fc cocotb-fc

ENV_RESULTS := dv/iverilog/sim_build/results.json dv/vlt/logs/results.json dv/uvm/logs/results.json \
               dv/systemc/logs/results.json dv/cocotb/results.json

crosscheck:
	python3 dv/common/crosscheck.py --require iverilog,vlt,uvm,systemc,cocotb $(ENV_RESULTS)

envs: iverilog vlt uvm systemc cocotb

upf:
	@echo "upf: AUTHORED, NOT RUN.  lp/bridge.upf (IEEE 1801 / UPF 2.1) needs a commercial"
	@echo "     power-aware simulator (VCS-NLP / Questa-PA / Xcelium-LP); none is available"
	@echo "     here and no OSS tool models supplies/isolation/retention.  The UPF has not"
	@echo "     been parsed or simulated.  See docs/power_intent.md for how to run it."
	@echo "     'make upf-tb' runs the power-aware TB functionally (no power semantics)."

# functional (NOT power-aware) Icarus run of lp/tb_pipe7_upf_power: PMU sequencing
upf-tb:
	$(MAKE) -C lp upf-tb

# metrics: run + time the flows, then collect real artifacts into metrics/metrics.db
# (every value tagged measured / estimated / not_attributable); dashboard: render it.
METRICS_FLOWS ?= regress,coverage,systemc,cocotb,formal,upf-tb
metrics:
	python3 metrics/collect.py --run $(METRICS_FLOWS) --note "$(METRICS_NOTE)"

dashboard:
	python3 metrics/dashboard.py

# per-test waves: run with a VCD dump, check the GTKWave session against it, open it
# if gtkwave + a display are available.  `make waves` = loop; tests: WAVE_TESTS.
WAVE_TESTS := smoke tx loop pm rxovf scen upf
waves: wave-loop

wave-%:
	@if [ "$*" = "upf" ]; then $(MAKE) -C lp upf-tb WAVES=1; else $(MAKE) -C dv/iverilog $* WAVES=1; fi
	python3 dv/waves/wave_check.py check $* $$(if [ "$*" = "upf" ]; then echo lp/sim_build/upf_tb.vcd; else echo dv/iverilog/sim_build/$*.vcd; fi)
	@if command -v gtkwave >/dev/null 2>&1 && [ -n "$$DISPLAY" ]; then \
	  gtkwave -a dv/waves/$*.gtkw $$(if [ "$*" = "upf" ]; then echo lp/sim_build/upf_tb.vcd; else echo dv/iverilog/sim_build/$*.vcd; fi) & \
	else echo "wave-$*: gtkwave/DISPLAY not available; open with: gtkwave -a dv/waves/$*.gtkw <dump>"; fi

# every test's session checked against a fresh dump (no GUI)
wave-check-all:
	@for t in $(WAVE_TESTS); do $(MAKE) --no-print-directory wave-$$t DISPLAY= || exit 1; done

# multi-seed Verilator run of all scenarios (seed = MAC gap / sink backpressure pattern)
stress:
	$(MAKE) -C dv/vlt stress STRESS_SEEDS=$(or $(STRESS_SEEDS),20)

# x4-lane elaboration check (OPEN_DECISIONS D1): Verilator lint + the whole iverilog
# suite with PIPE_NLANES_OVERRIDE=4 (256b PIPE bus, 8 beats/flit). Not part of `regress`.
LANES ?= 4
.PHONY: lanes4
lanes4:
	$(VERILATOR) --lint-only -Wall -DPIPE_NLANES_OVERRIDE=$(LANES) -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	$(VERILATOR) --lint-only -Wall -DPIPE_NLANES_OVERRIDE=$(LANES) -DFLOW_CTRL_OVERRIDE -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	$(MAKE) -C dv/iverilog BUILD=sim_build_x$(LANES) IVEXTRA=-DPIPE_NLANES_OVERRIDE=$(LANES) smoke tx loop pm rxovf
	$(MAKE) -C dv/iverilog IVEXTRA=-DPIPE_NLANES_OVERRIDE=$(LANES) scen
	$(MAKE) -C dv/iverilog fc FCB=sim_build_x$(LANES)fc FCX=-DPIPE_NLANES_OVERRIDE=$(LANES)
	$(MAKE) -C dv/iverilog link BUILD=sim_build_x$(LANES) IVEXTRA=-DPIPE_NLANES_OVERRIDE=$(LANES)
	@echo "lanes4: OK (x$(LANES), incl. flow control)"

ci: regress coverage formal envs crosscheck envs-fc upf-tb lanes4
	@echo "ci: OK"

# zero-cost area/power estimate (Yosys -> Nangate45 -> OpenSTA); ~30 min, ~10-14 GB RAM, needs network (lp/oss/README.md)
.PHONY: power-oss
power-oss:
	$(MAKE) -C lp/oss deps generic map gls-verify gls power

clean:
	rm -rf lp/sim_build metrics/_capture dv/*/sim_build dv/*/sim_build_x* dv/*/obj_dir dv/*/obj_dir_fc dv/*/fc_run dv/*/logs_fc dv/*/logs obj_dir coverage.info coverage.dat formal/*_prove formal/*_cover
	rm -f dv/cocotb/results.xml dv/cocotb/results.json dv/cocotb/fcov.json dv/uvm/build.log dv/uvm/build_fc.log dv/cocotb/results_fc.xml dv/cocotb/results_fc.json dv/cocotb/fcov_fc.json
	find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
