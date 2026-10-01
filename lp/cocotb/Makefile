# lp/cocotb — UPF-like power-state emulation of PD_DP with cocotb on Icarus (no power tool):
# the PMU (lp/pipe7_pmu.sv) sequences power-down/up; lp/cocotb/pd_emu.py corrupts PD_DP state while
# "off", clamps the PD_DP outputs the always-on logic reads while isolated, and saves/restores the
# retained state.  `make -C lp/cocotb pd` runs the matrix and writes pd_results.json.
# Same tool gotchas as dv/cocotb (apt Icarus; cocotb 1.8.1 python3 first on PATH).
SIM             ?= icarus
TOPLEVEL_LANG   ?= verilog
export ICARUS_BIN_DIR ?= /usr/bin
RTL_DIR         := $(abspath ../../rtl)
LP_DIR          := $(abspath ..)
COCOTB_DV       := $(abspath ../../dv/cocotb)
COMMON          := $(abspath ../../dv/common)
VERILOG_SOURCES := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
                   $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
                   $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv \
                   $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/bridge_ctrl_fsm.sv $(RTL_DIR)/bridge_rf.sv \
                   $(RTL_DIR)/eth_dj_pipe7_bridge.sv $(COCOTB_DV)/cocotb_top.sv $(LP_DIR)/pipe7_pmu.sv \
                   $(abspath pd_top.sv)
TOPLEVEL        := pd_top
MODULE          ?= test_pd
COMPILE_ARGS    += -g2012 -I $(RTL_DIR)
export PYTHONPATH := $(abspath .):$(COMMON):$(PYTHONPATH)
COCOTB_SCRIPTS := $(shell python3 -c "import cocotb,os,sys,shutil;print(os.path.dirname(shutil.which('cocotb-config',path=os.path.dirname(sys.executable)+os.pathsep+os.environ['PATH'])))")
export PATH := $(COCOTB_SCRIPTS):$(PATH)

.PHONY: pd pd-dpr
pd:
	rm -f results.xml pd_results.json
	$(MAKE) sim PD_RESULTS=$(abspath pd_results.json)
	python3 check_pd.py results.xml pd_results.json

# datapath-local reset build (-DDP_RESET_OVERRIDE, D18): retaining NOTHING must pass
pd-dpr:
	rm -rf results_dpr.xml pd_results_dpr.json
	$(MAKE) sim SIM_BUILD=sim_build_dpr COMPILE_ARGS="-g2012 -I $(RTL_DIR) -DDP_RESET_OVERRIDE" \
	  COCOTB_RESULTS_FILE=results_dpr.xml PD_DP_RESET=1 PD_RESULTS=$(abspath pd_results_dpr.json)
	python3 check_pd.py results_dpr.xml pd_results_dpr.json

include $(shell python3 -m cocotb.config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build sim_build_dpr __pycache__ results.xml pd_results.json results_dpr.xml pd_results_dpr.json
