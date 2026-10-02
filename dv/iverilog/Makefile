# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# smoke: reset + link-up contract (tb_smoke.sv).  tx: M1 frame->flit directed test (tb_tx.sv).
# loop: M2 eth->pipe->eth loopback (tb_loop.sv).  pm: M3 power/rate/width/cfg under traffic
# (tb_pm.sv).  rxovf: M3 Rx overload drop/abort policy (tb_rxovf.sv).
# scen: shared cross-env scenario set (tb_scen.sv, dv/common/scenarios.py).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
COMMON   := ../common
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
            $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/eth_egress.sv \
            $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/bridge_ctrl_fsm.sv $(RTL_DIR)/bridge_rf.sv \
            $(RTL_DIR)/eth_dj_pipe7_bridge.sv
BUILD    := sim_build
# WAVES=1: add dv/waves/wave_dump.sv as a second top and dump sim_build/<test>.vcd
WAVES    ?= 0
# extra iverilog flags (e.g. IVEXTRA=-DPIPE_NLANES_OVERRIDE=4 BUILD=sim_build_x4 for the lane check)
IVEXTRA  ?=
WFLAGS    = $(if $(filter 1,$(WAVES)),-DDUMP_TOP=tb_$@ ../waves/wave_dump.sv)
WRUN      = $(if $(filter 1,$(WAVES)),+dumpfile=$(BUILD)/$@.vcd)

.PHONY: smoke tx loop pm rxovf edge scen msgbus msgbus_mac link fc nodpr all clean
all: smoke tx loop pm rxovf edge scen msgbus msgbus_mac link fc nodpr

LOOP_TB_DEPS := $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(COMMON)/eth_sink_model.sv
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/smoke.vvp tb_smoke.sv $(COMMON)/pipe_phy_ctrl_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/smoke.vvp $(WRUN) | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

tx:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/tx.vvp tb_tx.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/tx.vvp $(WRUN) | tee $(BUILD)/tx.log
	@grep -q "TX PASS" $(BUILD)/tx.log

loop:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/loop.vvp tb_loop.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(COMMON)/eth_sink_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/loop.vvp $(WRUN) | tee $(BUILD)/loop.log
	@grep -q "LOOP PASS" $(BUILD)/loop.log

pm:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/pm.vvp tb_pm.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/pm.vvp $(WRUN) | tee $(BUILD)/pm.log
	@grep -q "PM PASS" $(BUILD)/pm.log

rxovf:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/rxovf.vvp tb_rxovf.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/rxovf.vvp $(WRUN) | tee $(BUILD)/rxovf.log
	@grep -q "RXOVF PASS" $(BUILD)/rxovf.log

edge:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/edge.vvp tb_edge.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/edge.vvp $(WRUN) | tee $(BUILD)/edge.log
	@grep -q "EDGE PASS" $(BUILD)/edge.log

# shared five-scenario set (dv/common/scenarios.py) -> sim_build/results.json
scen:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/scen.vvp tb_scen.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/scen.vvp $(WRUN) | tee $(BUILD)/scen.log
	@grep -q "SCEN PASS" $(BUILD)/scen.log
	python3 $(COMMON)/crosscheck.py $(BUILD)/results.json

# single-ended suite with flow control ON (D16): the DUT loops its own Tx back into Rx, so it
# sees its own credit advertisements.  loop + pm + the shared scenarios (checked against the
# golden model, flit/frame/crc/pmcnt identical to the flow-control-off run).  rxovf is NOT
# run: it forces Rx overload (drops), which flow control exists to prevent.
FCB := sim_build_fcl
FCX :=          # extra flags for the FC runs (e.g. -DPIPE_NLANES_OVERRIDE=4 from make lanes4)
fc:
	$(MAKE) BUILD=$(FCB) IVEXTRA="-DFLOW_CTRL_OVERRIDE $(FCX)" loop pm
	$(IVERILOG) -g2012 -DFLOW_CTRL_OVERRIDE $(FCX) -I $(RTL_DIR) -I $(COMMON) -I . -o $(FCB)/scen.vvp tb_scen.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(FCB)/scen.vvp +results=$(FCB)/results.json | tee $(FCB)/scen.log
	@grep -q "SCEN PASS" $(FCB)/scen.log
	python3 $(COMMON)/crosscheck.py $(FCB)/results.json

# datapath-local reset OFF (D18, -DDP_RESET_DISABLE = the pre-D18 behaviour; the default build now has the
# reset ON).  smoke + tx + loop + pm (P1/P2 episodes under traffic) + rxovf + the shared scenarios (golden
# model).  Separate build dir / results; default artefacts untouched.
DPRB := sim_build_nodpr
nodpr:
	$(MAKE) BUILD=$(DPRB) IVEXTRA=-DDP_RESET_DISABLE smoke tx loop pm rxovf
	$(IVERILOG) -g2012 -DDP_RESET_DISABLE -I $(RTL_DIR) -I $(COMMON) -I . -o $(DPRB)/scen.vvp tb_scen.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(DPRB)/scen.vvp +results=$(DPRB)/results.json | tee $(DPRB)/scen.log
	@grep -q "SCEN PASS" $(DPRB)/scen.log
	python3 $(COMMON)/crosscheck.py $(DPRB)/results.json

# unit test of pipe_msgbus against PIPE 7.1 6.1.4 (framing + P2M framer)
msgbus:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -o $(BUILD)/msgbus.vvp tb_msgbus.sv $(RTL_DIR)/pipe_msgbus.sv
	$(VVP) $(BUILD)/msgbus.vvp | tee $(BUILD)/msgbus.log
	@grep -q "MSGBUS PASS" $(BUILD)/msgbus.log

# MAC-side message-bus target + M2P arbiter with the master (PIPE 7.1 6.1.4)
msgbus_mac:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(IVEXTRA) -I $(RTL_DIR) -o $(BUILD)/msgbus_mac.vvp tb_msgbus_mac.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv $(RTL_DIR)/fc_ctl.sv
	$(VVP) $(BUILD)/msgbus_mac.vvp | tee $(BUILD)/msgbus_mac.log
	@grep -q "MSGBUS-MAC PASS" $(BUILD)/msgbus_mac.log

# TWO-ENDED link flow-control test (D16): two bridges cross-connected, built with flow control ON
link:
	@mkdir -p $(BUILD)_fc
	$(IVERILOG) -g2012 $(IVEXTRA) -DFLOW_CTRL_OVERRIDE -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)_fc/link.vvp tb_link.sv $(COMMON)/eth_mac_model.sv $(COMMON)/eth_sink_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)_fc/link.vvp | tee $(BUILD)_fc/link.log
	@grep -q "LINK PASS" $(BUILD)_fc/link.log

clean:
	rm -rf $(BUILD)
