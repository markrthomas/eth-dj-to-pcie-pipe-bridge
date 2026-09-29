# dv/iverilog — directed Icarus Verilog environment (DV env 1).
# M0: a smoke test (tb_smoke.sv). Directed frame tests land at M1 (docs/PLAN.md).
IVERILOG ?= iverilog
VVP      ?= vvp
RTL_DIR  := ../../rtl
BUILD    := sim_build

.PHONY: smoke clean
smoke:
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -I $(RTL_DIR) -o $(BUILD)/smoke.vvp tb_smoke.sv $(RTL_DIR)/eth_dj_pipe7_bridge.sv
	$(VVP) $(BUILD)/smoke.vvp | tee $(BUILD)/smoke.log
	@grep -q "SMOKE PASS" $(BUILD)/smoke.log

clean:
	rm -rf $(BUILD)
