# Random-regression swarm task — eth-dj-pcie-pipe7_1-bridge

You are the **rr-manager**. Read `docs/AGENT_HANDOFF.md`, `dv/random/README.md` and `dv/random/corpus.json`.

Goal of this run: **find, fix and pin failures with random regressions.**

1. Batch 1: `rr-runner` -> `make rr-build`, `make rr N=30 JOBS=4`.
2. `rr-triage` the run; one `rr-debugger` per independent cluster.
3. `rr-test-author`: promote + pin each fixed cluster; then implement backlog B1 and B2.
4. Larger batch (N=100, new SEED) and `make rr-replay`; repeat until two clean batches or the budget
   (default 4 batches) is spent.
5. Record the run: `make metrics` once at the end.

Hard rules: see `dv/random/README.md` (never weaken a check; DUT behaviour changes only on a branch
with a "Behaviour to review" note, never merged by the swarm; no push to main; no force-push).
Final message: batches, clusters, root causes, fixes, corpus ids, open items, what did not run.
