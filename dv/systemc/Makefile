# dv/systemc — DV env 4: Verilator --sc model + SystemC testbench (sc_main.cpp),
# sharing the C++ BFMs/scenarios with dv/vlt.  smoke: build, run, crosscheck.
# Needs SystemC 2.3.x (apt: libsystemc-dev).  Override SYSTEMC_INCLUDE /
# SYSTEMC_LIBDIR for a non-apt install.  Do NOT set VERILATOR_ROOT.
VERILATOR ?= verilator
RTL_DIR   := ../../rtl
COMMON    := ../common
TOP       := eth_dj_pipe7_bridge
RTL_SRCS  := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
             $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
             $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
             $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/$(TOP).sv
export SYSTEMC_INCLUDE ?= /usr/include
export SYSTEMC_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
SVA       ?= 1
SVA_SRCS  := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/bridge_sva.sv)
SVA_FLAGS := $(if $(filter 1,$(SVA)),--assert)
JOBS      ?= $(shell nproc 2>/dev/null || echo 4)
BIN       := obj_dir/V$(TOP)

.PHONY: smoke build clean
build: $(BIN)

$(BIN): sc_main.cpp $(COMMON)/cpp/bridge_bfm.h $(RTL_SRCS) $(SVA_SRCS)
	$(VERILATOR) --sc --exe --build -j $(JOBS) -O2 $(SVA_FLAGS) -I$(RTL_DIR) --top-module $(TOP) \
	  -CFLAGS "-I$(abspath $(COMMON)/cpp) -std=c++17 -O1" -LDFLAGS "-L$(SYSTEMC_LIBDIR) -lsystemc" \
	  $(RTL_SRCS) $(SVA_SRCS) sc_main.cpp

smoke: $(BIN)
	@mkdir -p logs
	SC_COPYRIGHT_MESSAGE=DISABLE ./$(BIN) | tee logs/systemc.log
	@grep -q "SYSTEMC PASS" logs/systemc.log
	python3 $(COMMON)/crosscheck.py logs/results.json

clean:
	rm -rf obj_dir logs
