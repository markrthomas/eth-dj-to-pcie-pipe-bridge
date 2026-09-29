# formal — SymbiYosys

`*.sby` (bmc + cover tasks) + `*_fv.sv` property modules for CDC/credit/message-bus
safety. `make formal` delegates here. Populated at M5 (docs/PLAN.md T5.2). Keep a
plain-Verilog model for anything Yosys can't parse (SV struct literals bit a sibling).
