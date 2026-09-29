# dv/uvm — DV env 3: Accellera UVM (uvm-core 2020.3.1) on Verilator --timing.
# smoke: build + run scen_test (shared five-scenario set) -> logs/results.json,
#        then crosscheck.  First build compiles UVM itself (~2-5 min).
# Needs a UVM-capable Verilator (>= 5.03x; the pinned OSS CAD Suite 2026-04-13
# ships 5.047).  apt Verilator 5.020 cannot build UVM.  Keep VERILATOR_ROOT unset.
# UVM_HOME: path to uvm-core/src; if unset, uvm-core is cloned at UVM_REF into
# ./uvm-core (git-ignored).
VERILATOR ?= verilator
UVM_REPO  ?= https://github.com/accellera-official/uvm-core
UVM_REF   ?= 78c06547a2a0a29b3dc9dcafae62b75b2ff61544
UVM_HOME  ?= $(abspath uvm-core/src)
RTL_DIR   := ../../rtl
COMMON    := ../common
RTL_SRCS  := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
             $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
             $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
             $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/eth_dj_pipe7_bridge.sv
SVA       ?= 1
SVA_SRCS  := $(if $(filter 1,$(SVA)),../sva/async_fifo_sva.sv ../sva/bridge_sva.sv)
JOBS      ?= $(shell nproc 2>/dev/null || echo 4)
BIN       := obj_dir/Vtb_uvm_top
VFLAGS    := --binary --timing -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-SYMRSVDWORD \
             -Wno-CONSTRAINTIGN -Wno-MISINDENT -Wno-ZERODLY +define+UVM_NO_DPI --assert \
             +incdir+$(UVM_HOME) -I$(RTL_DIR) -I$(COMMON) --top-module tb_uvm_top

.PHONY: smoke build clean
build: $(BIN)

$(UVM_HOME)/uvm_pkg.sv:
	git clone -q $(UVM_REPO) uvm-core && git -C uvm-core checkout -q $(UVM_REF)

$(BIN): $(UVM_HOME)/uvm_pkg.sv bridge_if.sv bridge_uvm_pkg.sv tb_uvm_top.sv $(RTL_SRCS) \
        $(COMMON)/scenarios.svh $(COMMON)/eth_dj_pat.svh $(SVA_SRCS)
	$(VERILATOR) $(VFLAGS) $(UVM_HOME)/uvm_pkg.sv $(RTL_SRCS) $(SVA_SRCS) bridge_if.sv bridge_uvm_pkg.sv tb_uvm_top.sv \
	  > build.log 2>&1 || (tail -40 build.log; exit 1)

smoke: $(BIN)
	@mkdir -p logs
	./$(BIN) +UVM_TESTNAME=scen_test | tee logs/uvm.log
	@grep -q "UVM PASS" logs/uvm.log
	@! grep -q "UVM_ERROR :\s*[1-9]" logs/uvm.log
	python3 $(COMMON)/crosscheck.py logs/results.json

clean:
	rm -rf obj_dir logs build.log
