# =============================================================================
# eth-dj-pcie-pipe7_1-bridge — root DV gate.
#
# Standard targets per ~/proj/DV_STANDARDS.md.  `lint` and `sim` (Icarus
# directed tests smoke/tx/loop/pm/rxovf) are real; `coverage`/`formal` and the non-Icarus
# environments are stubs that exit 0 until their milestone (see docs/PLAN.md §11).
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

.PHONY: default help lint sim regress coverage formal ci \
        iverilog vlt uvm systemc cocotb waves upf metrics dashboard stress clean

default: help

help:
	@echo "eth-dj-pcie-pipe7_1-bridge — targets:"
	@echo "  lint      Verilator --lint-only -Wall on rtl/            (M0: real)"
	@echo "  sim       Icarus directed tests: smoke tx loop pm rxovf  (real)"
	@echo "  regress   lint + sim  — the fast CI gate                 (M0: real)"
	@echo "  coverage  Verilator --coverage -> coverage.info          (M4 stub)"
	@echo "  formal    SymbiYosys BMC + cover                         (M5 stub)"
	@echo "  ci        regress + coverage + formal                    "
	@echo "  iverilog|vlt|uvm|systemc|cocotb   run one DV environment "
	@echo "  waves     run a test with dump + open its GTKWave session (M7)"
	@echo "  upf       power-aware sim (commercial; OSS stub)          (M6)"
	@echo "  metrics|dashboard   build metrics.db / dashboard.html     (M7)"
	@echo "  clean     remove build artifacts"

# ---- real M0 targets --------------------------------------------------------
lint:
	$(VERILATOR) --lint-only -Wall -I$(RTL_DIR) --top-module $(TOP) $(RTL_SRCS)
	@echo "lint: OK"

sim: iverilog

iverilog:
	$(MAKE) -C dv/iverilog smoke tx loop pm rxovf

regress: lint sim
	@echo "regress: OK"

# ---- stubs (exit 0) until their milestone ----------------------------------
coverage:
	@echo "coverage: [M4 stub] Verilator --coverage vehicle not built yet (docs/PLAN.md T4.1)"

formal:
	@echo "formal: [M5 stub] SymbiYosys properties not written yet (docs/PLAN.md T5.2)"

vlt:
	@$(MAKE) -C dv/vlt smoke

uvm:
	@$(MAKE) -C dv/uvm smoke

systemc:
	@$(MAKE) -C dv/systemc smoke

cocotb:
	@$(MAKE) -C dv/cocotb smoke

upf:
	@echo "upf: [M6] authored power intent runs on a commercial PA tool; no OSS"
	@echo "     power-aware simulator here. See docs/PLAN.md §9 / docs/power_intent.md."

metrics dashboard:
	@echo "$@: [M7 stub] metrics dashboard not wired yet (docs/PLAN.md T7.2)"

waves:
	@echo "waves: [M7 stub] per-test GTKWave sessions not added yet (docs/PLAN.md T7.1)"

stress:
	@echo "stress: [later] randomized long-run stimulus not added yet"

ci: regress coverage formal
	@echo "ci: OK"

clean:
	rm -rf dv/*/sim_build dv/*/obj_dir obj_dir coverage.info coverage.dat
	find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
