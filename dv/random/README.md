# dv/random — random regression, triage and replay corpus

Loop run by the **rr swarm** (`.claude/agents/rr-*.md`, task `docker/rr-swarm-task.md`):

```
rr-runner (haiku)  ->  rr-triage (sonnet)  ->  rr-debugger (opus)  ->  rr-test-author (sonnet)
   random jobs         cluster failures        root cause + fix        promote repro into corpus
        ^                                                                       |
        +------------------------ rr-manager (opus) <---------------------------+
```

| Command | What |
|---|---|
| `make rr-build` | build the three Verilator binaries (default, `fc`, `nodpr`) |
| `make rr N=60 JOBS=6` | run N random (config, seed, plusargs) jobs -> `dv/random/runs/<ts>/results.jsonl` |
| `make rr-triage RUN=<dir>` | cluster failures by normalised signature -> `triage.json` |
| `make rr-replay` | rerun `corpus.json`; **gates** on entries with status `fixed` |

`corpus.json` is the permanent record: every failure found by a random run is promoted
(`rr.py promote`), reproduced, root-caused, fixed, then marked `fixed` (`rr.py fixed ID --by PR/commit`)
so it can never regress silently. `rr-replay` is part of `make ci`.

## Rules
- Never weaken a checker, scenario, golden model or SVA to get green. A failure is a DUT bug,
  a TB/model bug, or a harness bug - find out which, with evidence (log, waveform window, minimal repro).
- **DUT (rtl/) behaviour changes are the owner's call** (docs/AGENT_HANDOFF.md working agreement):
  the debugger writes the fix on a branch + a "Behaviour to review" note in `docs/OPEN_DECISIONS.md`;
  the swarm does not merge. TB/harness/infra fixes follow the same branch+draft-PR flow.
- A promoted repro must fail before the fix and pass after (record both in the corpus `note`).
- Open corpus entries are reported, not gating, until fixed.

## Current stimulus knobs
The runner randomises config (`vlt`, `vlt-fc`, `vlt-nodpr`), `+seed` (MAC gaps / sink backpressure RNG),
`+mac_gap=PCT +sink_pct=PCT` (B1, parsed by `dv/vlt/sim_main.cpp`; defaults 10 / 90) and the **`rand`
scenario** (B2): `+rand_seed=N [+rand_frames=K] [+rand_maxlen=L]` appends an 8th scenario after the
seven fixed ones. Plan = `scenarios.rand_plan()` (~30 % corner lengths 1/239/240/241/480, rest
`lcg_lengths`; one of none/pm_cycle/rate_change split at a seeded frame), mirrored in
`bridge_bfm.h enable_rand()`; golden = `scenarios.expected_rand()`. `results.json` then carries a
top-level `"rand": {seed, frames, maxlen}` and `crosscheck.py` checks it automatically. Without
`+rand_seed` results.json is bit-identical to before. The args are recorded per job, so corpus entries replay them.
`python3 dv/common/scenarios.py --rand SEED [K [L]]` prints a plan + expected values.

## Backlog (the manager hands these to agents)
- B1 DONE `dv/vlt/sim_main.cpp`: parse `+mac_gap`, `+sink_pct`.
- B2 DONE in vlt (other four envs still to mirror): add a `rand` scenario: lengths from `lcg_lengths(seed, n, max_len)`, random pm/rate op
  interleaving; extend `dv/common/scenarios.py` golden model (`expected_rand(seed)`) and
  `crosscheck.py`, keep the five fixed scenarios unchanged; mirror in the other four envs only after vlt is stable.
- B3 random CSR/msgbus traffic (PHY-initiated reads/writes, mid-traffic resets, P-state storms).
- B4 x4-lane (`PIPE_NLANES_OVERRIDE=4`) random configs; iverilog `tb_scen` seed plusarg.
- B5 random runs feed `metrics/` (pass rate, unique clusters, time-to-fix) and the dashboard.
