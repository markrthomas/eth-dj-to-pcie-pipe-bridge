# dv/vlt — DV env 2: plain Verilator C++ harness (sim_main.cpp) + coverage vehicle.
# smoke    : build + run the five cross-check scenarios and two coverage-only
#            scenarios (logs/results.json, logs/coverage.dat), then crosscheck.
# coverage : smoke, then verilator_coverage -> ../../coverage.info (lcov format)
#            and a line-coverage summary for rtl/ (floor COV_FLOOR %).
# trace    : rerun with +trace -> logs/vlt.fst
# SVA      : dv/sva checkers are bound in (--assert); a failing assertion aborts the run.
# Do NOT set VERILATOR_ROOT.
VERILATOR    ?= verilator
VERILATOR_COV ?= verilator_coverage
RTL_DIR  := ../../rtl
COMMON   := ../common
TOP      := eth_dj_pipe7_bridge
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
            $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
            $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
            $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/$(TOP).sv
COV_FLOOR ?= 80
# bind-based SVA (dv/sva): on by default; SVA=0 builds without it
SVA      ?= 1
SVA_SRCS := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/bridge_sva.sv)
SVA_FLAGS := $(if $(filter 1,$(SVA)),--assert --coverage-user)
JOBS     ?= $(shell nproc 2>/dev/null || echo 4)
BIN      := obj_dir/V$(TOP)

.PHONY: smoke build coverage trace stress fc clean
build: $(BIN)

$(BIN): sim_main.cpp $(COMMON)/cpp/bridge_bfm.h $(RTL_SRCS) $(SVA_SRCS)
	$(VERILATOR) --cc --exe --build -j $(JOBS) -O2 --x-assign unique --x-initial unique \
	  --coverage-line --coverage-toggle $(SVA_FLAGS) --trace-fst \
	  -I$(RTL_DIR) --top-module $(TOP) -CFLAGS "-I$(abspath $(COMMON)/cpp) -O1" \
	  $(RTL_SRCS) $(SVA_SRCS) sim_main.cpp

smoke: $(BIN)
	@mkdir -p logs
	./$(BIN) | tee logs/vlt.log
	@grep -q "VLT PASS" logs/vlt.log
	python3 $(COMMON)/crosscheck.py logs/results.json

coverage: smoke
	VERILATOR_COV=$(VERILATOR_COV) python3 cov_summary.py logs/coverage.dat --info ../../coverage.info \
	  --json logs/coverage_summary.json --floor $(COV_FLOOR)

trace: $(BIN)
	@mkdir -p logs
	./$(BIN) +trace | tee logs/vlt.log
	@grep -q "VLT PASS" logs/vlt.log

# stress: rerun all 7 scenarios with STRESS_SEEDS different seeds (the seed drives
# MAC gaps / sink backpressure; every scoreboard, SVA and golden-model check applies)
STRESS_SEEDS ?= 20
stress: $(BIN)
	@mkdir -p logs
	@set -e; for s in $$(seq 1 $(STRESS_SEEDS)); do \
	  ./$(BIN) +seed=$$s > logs/stress_$$s.log 2>&1 || { tail -5 logs/stress_$$s.log; echo "STRESS FAIL: seed $$s"; exit 1; }; \
	  grep -q "VLT PASS" logs/stress_$$s.log || { echo "STRESS FAIL: seed $$s"; exit 1; }; \
	  python3 $(COMMON)/crosscheck.py logs/results.json > logs/stress_$$s.xchk || { cat logs/stress_$$s.xchk; echo "STRESS FAIL: seed $$s crosscheck"; exit 1; }; \
	done; echo "STRESS PASS: $(STRESS_SEEDS) seeds x 7 scenarios"

# fc: same harness and checkers with link flow control ON (-DFLOW_CTRL_OVERRIDE, D16).  The
# PIPE Rx side is the Tx loopback, so the DUT sees its own credit advertisements.  Separate
# build dir and run dir (default smoke artefacts are untouched).
FCDIR := obj_dir_fc
fc: sim_main.cpp $(COMMON)/cpp/bridge_bfm.h $(RTL_SRCS) $(SVA_SRCS)
	$(VERILATOR) --cc --exe --build -j $(JOBS) -O2 --x-assign unique --x-initial unique \
	  $(SVA_FLAGS) -DFLOW_CTRL_OVERRIDE --Mdir $(FCDIR) \
	  -I$(RTL_DIR) --top-module $(TOP) -CFLAGS "-I$(abspath $(COMMON)/cpp) -O1 -DFLOW_CTRL_OVERRIDE" \
	  $(RTL_SRCS) $(SVA_SRCS) sim_main.cpp
	@mkdir -p fc_run/logs
	cd fc_run && ../$(FCDIR)/V$(TOP) | tee logs/vlt.log
	@grep -q "VLT PASS" fc_run/logs/vlt.log
	python3 $(COMMON)/crosscheck.py fc_run/logs/results.json

clean:
	rm -rf obj_dir obj_dir_fc fc_run logs coverage.info coverage.dat
