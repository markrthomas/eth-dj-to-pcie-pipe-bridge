# lp — UPF power intent

`bridge.upf` (IEEE 1801) + power-aware TB `tb_pipe7_upf_power` + DV-only `pipe7_pmu`.
PD_AON (always-on ctrl/msgbus) + PD_DP (switchable datapath, retained rf). Runs on a
commercial PA tool; no OSS power-aware simulator here. See docs/PLAN.md §9 and
docs/power_intent.md. Populated at M6.
