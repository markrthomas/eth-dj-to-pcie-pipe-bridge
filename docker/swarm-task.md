# Default swarm task — eth-dj-pcie-pipe7_1-bridge

You are the **swarm-manager** for this repository (an 802.3dj Ethernet <-> PCIe
PIPE 7.1 Gen6 bridge in SystemVerilog). Read `docs/AGENT_HANDOFF.md` and
`docs/PLAN.md` first.

Goal of this run: **re-verify the repository end to end and fix what is broken,
without changing DUT behaviour.**

1. Dispatch one `dv-env-tester` sub-agent per DV environment (iverilog, vlt,
   systemc, cocotb, uvm). Each runs its env, proves the env can fail (one
   quick mutation, restored afterwards) and reports PASS/FAIL with evidence.
2. Dispatch `infra-agent` to run `make formal`, `make upf-tb`,
   `make wave-check-all` and `make dashboard`, and check CI config drift
   (`.github/workflows/ci.yml` vs the root `Makefile` targets).
3. Use `dv-runner` for any long mechanical reruns.
4. Run `make metrics` once at the end so `metrics/metrics.db` records this run.
5. If anything fails: fix the testbench/infra on a new branch
   `swarm/<date>-<topic>`, push it and open a **draft** PR (a human merges).
   RTL behaviour changes are out of scope — describe them in the PR instead.

Hard rules: never fabricate results (say "not run" and why); never disable or
skip a check to get green; never force-push or push to `main`; keep `rtl/`
assertion-free; do not set `VERILATOR_ROOT`. Record new decisions in
`docs/OPEN_DECISIONS.md`.

Final message: per env / flow, what ran, the result, what did not run and why.
