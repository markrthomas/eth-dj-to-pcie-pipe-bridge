# =============================================================================
# eth-dj-pcie-pipe7_1-bridge — root DV gate.
#
# Standard targets per ~/proj/DV_STANDARDS.md.  `lint`, `sim` (Icarus directed
# tests + shared scenario set), `coverage` (Verilator, >= 80% line+branch) and
# the five DV environments are real; see docs/PLAN.md §11 for what is still a stub.
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
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv $(RTL_DIR)/bridge_rf.sv $(RTL_TOP)

.PHONY: default help lint sim regress coverage formal ci envs crosscheck \
        iverilog vlt uvm systemc cocotb waves upf metrics dashboard stress clean

default: help

help:
	@echo "eth-dj-pcie-pipe7_1-bridge — targets:"
	@echo "  lint       Verilator --lint-only -Wall on rtl/"
	@echo "  sim        Icarus directed tests: smoke tx loop pm rxovf scen"
	@echo "  regress    lint + sim  — the fast CI gate"
	@echo "  coverage   Verilator C++ env with --coverage -> coverage.info (floor 80%)"
	@echo "  formal     SymbiYosys prove (PDR) + cover on formal/*.sby (OSS CAD Suite)"
	@echo "  iverilog|vlt|uvm|systemc|cocotb   run one DV environment (shared scenarios)"
	@echo "  crosscheck all five envs agree with dv/common/scenarios.py"
	@echo "  ci         regress + coverage + formal + all envs + crosscheck"
	@echo "  waves      run a test with dump + open its GTKWave session (M7)"
	@echo "  upf        power-aware sim (commercial; OSS stub)          (M6)"
	@echo "  metrics|dashboard   build metrics.db / dashboard.html      (M7)"
	@echo "  clean      remove build artifacts"
	@echo "  note: uvm needs a UVM-capable Verilator (>= 5.03x, e.g. OSS CAD Suite 2026-04-13)"

# ---- real M0 targets --------------------------------------------------------
lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	@echo "lint: OK"

sim: iverilog

iverilog:
	$(MAKE) -C dv/iverilog smoke tx loop pm rxovf scen

regress: lint sim
	@echo "regress: OK"

# ---- stubs (exit 0) until their milestone ----------------------------------
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

ENV_RESULTS := dv/iverilog/sim_build/results.json dv/vlt/logs/results.json dv/uvm/logs/results.json \
               dv/systemc/logs/results.json dv/cocotb/results.json

crosscheck:
	python3 dv/common/crosscheck.py --require iverilog,vlt,uvm,systemc,cocotb $(ENV_RESULTS)

envs: iverilog vlt uvm systemc cocotb

upf:
	@echo "upf: [M6] authored power intent runs on a commercial PA tool; no OSS"
	@echo "     power-aware simulator here. See docs/PLAN.md §9 / docs/power_intent.md."

metrics dashboard:
	@echo "$@: [M7 stub] metrics dashboard not wired yet (docs/PLAN.md T7.2)"

waves:
	@echo "waves: [M7 stub] per-test GTKWave sessions not added yet (docs/PLAN.md T7.1)"

stress:
	@echo "stress: [later] randomized long-run stimulus not added yet"

ci: regress coverage formal envs crosscheck
	@echo "ci: OK"

clean:
	rm -rf dv/*/sim_build dv/*/obj_dir dv/*/logs obj_dir coverage.info coverage.dat formal/*_prove formal/*_cover
	rm -f dv/cocotb/results.xml dv/cocotb/results.json dv/cocotb/fcov.json dv/uvm/build.log
	find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
