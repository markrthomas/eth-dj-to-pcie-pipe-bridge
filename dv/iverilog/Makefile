# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# smoke: reset + link-up contract (tb_smoke.sv).  tx: M1 frame->flit directed test (tb_tx.sv).
# loop: M2 eth->pipe->eth loopback (tb_loop.sv).  pm: M3 power/rate/width/cfg under traffic
# (tb_pm.sv).  rxovf: M3 Rx overload drop/abort policy (tb_rxovf.sv).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
COMMON   := ../common
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv \
            $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv $(RTL_DIR)/eth_egress.sv \
            $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/bridge_ctrl_fsm.sv $(RTL_DIR)/bridge_rf.sv \
            $(RTL_DIR)/eth_dj_pipe7_bridge.sv
BUILD    := sim_build

.PHONY: smoke tx loop pm rxovf all clean
all: smoke tx loop pm rxovf

LOOP_TB_DEPS := $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(COMMON)/eth_sink_model.sv
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/smoke.vvp tb_smoke.sv $(COMMON)/pipe_phy_ctrl_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/smoke.vvp | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

tx:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/tx.vvp tb_tx.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/tx.vvp | tee $(BUILD)/tx.log
	@grep -q "TX PASS" $(BUILD)/tx.log

loop:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/loop.vvp tb_loop.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv $(COMMON)/eth_sink_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/loop.vvp | tee $(BUILD)/loop.log
	@grep -q "LOOP PASS" $(BUILD)/loop.log

pm:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/pm.vvp tb_pm.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/pm.vvp | tee $(BUILD)/pm.log
	@grep -q "PM PASS" $(BUILD)/pm.log

rxovf:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -I . -o $(BUILD)/rxovf.vvp tb_rxovf.sv $(LOOP_TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/rxovf.vvp | tee $(BUILD)/rxovf.log
	@grep -q "RXOVF PASS" $(BUILD)/rxovf.log

clean:
	rm -rf $(BUILD)
