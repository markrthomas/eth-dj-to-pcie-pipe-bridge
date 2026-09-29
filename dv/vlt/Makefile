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
            $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
            $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/$(TOP).sv
COV_FLOOR ?= 80
# bind-based SVA (dv/sva): on by default; SVA=0 builds without it
SVA      ?= 1
SVA_SRCS := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/bridge_sva.sv)
SVA_FLAGS := $(if $(filter 1,$(SVA)),--assert --coverage-user)
JOBS     ?= $(shell nproc 2>/dev/null || echo 4)
BIN      := obj_dir/V$(TOP)

.PHONY: smoke build coverage trace clean
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

clean:
	rm -rf obj_dir logs coverage.info coverage.dat
