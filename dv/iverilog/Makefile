# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# smoke: M0 reset-default check (tb_smoke.sv).  tx: M1 frame->flit directed test (tb_tx.sv).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
COMMON   := ../common
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_framer.sv $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/eth_dj_pipe7_bridge.sv
BUILD    := sim_build

.PHONY: smoke tx clean
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -o $(BUILD)/smoke.vvp tb_smoke.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/smoke.vvp | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

tx:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -I $(COMMON) -o $(BUILD)/tx.vvp tb_tx.sv $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(RTL_SRCS)
	$(VVP) $(BUILD)/tx.vvp | tee $(BUILD)/tx.log
	@grep -q "TX PASS" $(BUILD)/tx.log

clean:
	rm -rf $(BUILD)
