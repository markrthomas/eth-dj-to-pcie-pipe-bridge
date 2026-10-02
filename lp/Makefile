# lp — power intent.  `make -C lp upf-tb`: functional (NON power-aware) Icarus run
# of the power-aware TB: PMU sequencing + the no-handshake timing assumption +
# traffic across P1/P2 episodes.  The UPF itself needs a commercial power-aware simulator: `make -C lp upf-pa` runs it if one is on PATH, else prints a notice and exits 0.
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

# ---- UPF on a commercial power-aware simulator (optional) -------------------------------------
# Picks the first of vcs (VCS-NLP), xrun (Xcelium), vsim (Questa-PA) found on PATH.  With none of
# them it prints a notice and exits 0: the tool is not available in the OSS environment, so the UPF
# stays authored-not-run there.  The per-tool command lines below are UNTESTED (no licence has ever
# been available here); adjust the flags to your tool version.  Pass/fail = "UPF-TB PASS" in the log.
PA_SRCS := tb_pipe7_upf_power.sv pipe7_pmu.sv $(TB_DEPS) $(RTL_SRCS)
PA_TOOL := $(firstword $(foreach t,vcs xrun vsim,$(if $(shell command -v $(t) 2>/dev/null),$(t))))
.PHONY: upf-pa
upf-pa:
ifeq ($(PA_TOOL),)
	@echo "upf: no commercial power-aware simulator on PATH (looked for vcs, xrun, vsim) - skipping."
	@echo "     lp/bridge.upf stays AUTHORED, NOT RUN here (no OSS tool models UPF supplies /"
	@echo "     isolation / retention).  'make upf-tb' runs the same TB functionally (no power semantics)."
else
	@mkdir -p $(BUILD)/pa
	@echo "upf: using $(PA_TOOL) (command line untested - see lp/Makefile)"
ifeq ($(PA_TOOL),vcs)
	cd $(BUILD)/pa && vcs -full64 -sverilog -timescale=1ns/1ps +define+UPF_SIM -debug_access+all \
	  -upf $(abspath bridge.upf) -top tb_pipe7_upf_power -I $(abspath $(RTL_DIR)) -I $(abspath $(COMMON)) -I $(abspath ../dv/iverilog) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) -o simv && ./simv | tee ../upf_pa.log
endif
ifeq ($(PA_TOOL),xrun)
	cd $(BUILD)/pa && xrun -64bit -sv -timescale 1ns/1ps +define+UPF_SIM -lps_1801 -upf $(abspath bridge.upf) \
	  -top tb_pipe7_upf_power -incdir $(abspath $(RTL_DIR)) -incdir $(abspath $(COMMON)) -incdir $(abspath ../dv/iverilog) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) | tee ../upf_pa.log
endif
ifeq ($(PA_TOOL),vsim)
	cd $(BUILD)/pa && vlog -sv +define+UPF_SIM +incdir+$(abspath $(RTL_DIR)) +incdir+$(abspath $(COMMON)) +incdir+$(abspath ../dv/iverilog) \
	  $(addprefix $(CURDIR)/,$(PA_SRCS)) && vopt -pa -pa_upf $(abspath bridge.upf) tb_pipe7_upf_power -o tb_pa_opt \
	  && vsim -c -pa tb_pa_opt -do "run -all; quit" | tee ../upf_pa.log
endif
	@grep -q "UPF-TB PASS" $(BUILD)/upf_pa.log
endif

.PHONY: upf-tb clean
upf-tb:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 $(WFLAGS) -I $(RTL_DIR) -I $(COMMON) -I ../dv/iverilog -o $(BUILD)/upf_tb.vvp \
	  tb_pipe7_upf_power.sv pipe7_pmu.sv $(TB_DEPS) $(RTL_SRCS)
	$(VVP) $(BUILD)/upf_tb.vvp $(WRUN) | tee $(BUILD)/upf_tb.log
	@grep -q "UPF-TB PASS" $(BUILD)/upf_tb.log

clean:
	rm -rf $(BUILD)
