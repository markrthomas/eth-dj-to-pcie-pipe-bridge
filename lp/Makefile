# lp — power intent.  `make -C lp upf-tb`: functional (NON power-aware) Icarus run
# of the power-aware TB: PMU sequencing + the no-handshake timing assumption +
# traffic across P1/P2 episodes.  The UPF itself needs a power-aware simulator (commercial runs are out of scope here).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../rtl
COMMON   := ../dv/common
RTL_SRCS := $(RTL_DIR)/async_fifo.sv $(RTL_DIR)/tx_ingress_gate.sv $(RTL_DIR)/tx_framer.sv \
            $(RTL_DIR)/tx_egress.sv $(RTL_DIR)/rx_ingress.sv $(RTL_DIR)/rx_deframer.sv \
            $(RTL_DIR)/eth_egress.sv $(RTL_DIR)/pipe_msgbus.sv $(RTL_DIR)/msgbus_mac_tgt.sv $(RTL_DIR)/fc_ctl.sv $(RTL_DIR)/bridge_ctrl_fsm.sv \
            $(RTL_DIR)/bridge_rf.sv $(RTL_DIR)/eth_dj_pipe7_bridge.sv
TB_DEPS  := $(COMMON)/eth_mac_model.sv $(COMMON)/pipe_phy_model.sv $(COMMON)/pipe_phy_ctrl_model.sv \
            $(COMMON)/eth_sink_model.sv
BUILD    := sim_build
WAVES    ?= 0
WFLAGS    = $(if $(filter 1,$(WAVES)),-DDUMP_TOP=tb_pipe7_upf_power ../dv/waves/wave_dump.sv)
WRUN      = $(if $(filter 1,$(WAVES)),+dumpfile=$(BUILD)/upf_tb.vcd)

.PHONY: upf-tb clean
upf-tb:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I ../dv/iverilog -o $(BUILD)/upf_tb.vvp \
	  tb_pipe7_upf_power.sv pipe7_pmu.sv $(TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/upf_tb.vvp $(WRUN) | tee $(BUILD)/upf_tb.log
	@grep -q "UPF-TB PASS" $(BUILD)/upf_tb.log

clean:
	rm -rf $(BUILD)
