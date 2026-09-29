# dv/cocotb — DV env 5: cocotb 1.8.1 + PyUVM + PyVSC functional coverage, on Icarus.
# smoke: test_scenarios (shared five-scenario set + pm_full + rxovf coverage runs)
#        -> results.json (crosschecked) and fcov.json (PyVSC coverage).
# GOTCHAS (docs/AGENT_HANDOFF.md): ICARUS_BIN_DIR=/usr/bin (apt Icarus, not the OSS
# CAD Suite one, whose Python differs); pyvsc/pyuvm/cocotb in /usr/bin/python3;
# drive once after RisingEdge, sample at FallingEdge.
# Requirements: requirements.txt (pip install -r).
SIM             ?= icarus
TOPLEVEL_LANG   ?= verilog
export ICARUS_BIN_DIR ?= /usr/bin
RTL_DIR         := $(abspath ../../rtl)
COMMON          := $(abspath ../common)
VERILOG_SOURCES := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
                   $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
                   $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
                   $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/eth_dj_pipe7_bridge.sv $(abspath cocotb_top.sv)
TOPLEVEL        := cocotb_top
MODULE          := test_bridge
COMPILE_ARGS    += -g2012 -I $(RTL_DIR)
export PYTHONPATH := $(abspath .):$(COMMON):$(PYTHONPATH)
# cocotb's Makefile.sim calls `cocotb-config`; make sure it is the one that belongs
# to this python3's cocotb 1.8.1, not the OSS CAD Suite's (cocotb 2.x) if that is
# first on PATH.
COCOTB_SCRIPTS := $(shell python3 -c "import cocotb,os,sys,shutil;print(os.path.dirname(shutil.which('cocotb-config',path=os.path.dirname(sys.executable)+os.pathsep+os.environ['PATH'])))")
export PATH := $(COCOTB_SCRIPTS):$(PATH)

.PHONY: smoke
smoke:
	rm -f results.xml results.json fcov.json
	$(MAKE) sim
	python3 check_results.py results.xml
	python3 $(COMMON)/crosscheck.py results.json

include $(shell python3 -m cocotb.config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build __pycache__ results.xml results.json fcov.json
