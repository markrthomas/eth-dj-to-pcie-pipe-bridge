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

## Tracking the swarm (status board)
Cloud workers can only talk through git, so each owns one file on its own branch,
`dv/random/board/<worker>.json`, written by `dv/random/board.py` (it commits; the worker pushes):

```
board.py start NAME --task TXT --steps N      # first thing a worker does
board.py update NAME --step K --msg TXT [--blocker TXT]   # every milestone, then `git push`
board.py result NAME --jobs J --fails F --clusters C      # after each batch
board.py done NAME --msg TXT   |   board.py fail NAME --msg WHY
```
Manager: `make board` (fetches `origin/swarm/*`, prints state / step / age / branch@sha / results; flags
`STALE` = running but silent > 30 min, `blocked`, `NO_REPORT`), `make board-wait` (blocks until all are
done/blocked/stale), `board.py assign NAME --task TXT` registers planned work in `board/tasks.json`
(committed on the manager branch). States: assigned -> running -> done | blocked.
Every worker brief must say: "report with board.py at start, each milestone, each batch, and the end, and push."

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

### B3 control-plane traffic (`+rand_ctl=E`, E = 0..16 episodes, rr.py draws 0/1/2/4/8)
Every episode (1-3 items) is drawn from one LCG stream (`seed ^ 0xC71A5EED`); plan = `scenarios.ctl_plan()`,
mirrored in `bridge_bfm.h gen_ctl_plan_()`; results.json `rand` carries `ctl` and the plan hash and `crosscheck.py` compares
it with the golden plan (a mismatch = the two generators drifted). Items (frames keep flowing around them):
- **settled CSR writes** (30 %): legal and illegal CTRL values (rate > Gen6 / width 3 -> whole write ignored + ERR[3],
  P0s -> ERR[2], junk in bits 31:7), PAM4CFG, ERR W1C, in any order incl. rate/width requested while in P1/P2.
  Each is followed by `SETTLE` (expected PIPE pins, busy = 0, PMCNT == golden op count, stable) and exact CTRL / ERR / PAM4CFG read-back.
  PMCNT is predicted by `scenarios.CtlSim` (mirror of bridge_ctrl_fsm priority: rate > width > cfg > power-down).
- **P-state storm** (15 %): 3-8 back-to-back CTRL/PAM4/ERR writes, then a recovery write (P0, Gen6). Path-dependent op count -> PMCNT is
  checked against `[direct path, direct + 6*(writes+1)]` (`pmcnt` / `pmcnt_max` in the golden) until the next reset.
- **PHY-initiated MAC register access** (25 %): `OP_PHY_WR/RD` over the msgbus incl. atomic uncommitted groups (buffer overflow at 8),
  reserved, vendor, RX2/TX2 windows; the golden register file is `CtlSim.phy_wr/phy_rd` (= `msgbus_mac_tgt`).
  10 % of the episodes issue them right after a PAM4CFG write (racing the bridge's own msgbus write).
- **ignored writes** (10 %): RO / unmapped CSR addresses, read-back must not change, unmapped reads 0.
- **mid-traffic DUT reset** (10 %, max 3): 6-24 pclk, sometimes right after an unsettled CTRL write. Frames the Ethernet sink has not yet
  received are re-sent, so frames/bytes/crc stay exact; flits can only grow (`flits_max = flits * (1 + resets)`); PMCNT restarts at the link-up 2.
- **invariants** (only with `rand_ctl > 0`): legal PIPE pin sequencing (one of powerdown/rate/width per change, P0<->P1<->P2 only,
  no P0s / reserved rate / width on the pins, rate/width only in P0, no change before the previous PhyStatus), PMCNT/RXCNT never decrease
  within a reset epoch (RXCNT is cleared by P1/P2, D18), no hang (`settle: no convergence` / `scenario op timeout`), frame content.
  Verilator is 2-state: "no X" is not checkable here (Icarus/UVM own that).
`python3 dv/common/scenarios.py --rand SEED [FRAMES [MAXLEN [E]]]` prints the plan. TB change: the PHY model holds a write_ack back while a
PHY-initiated transaction is being driven (it used to overwrite a byte).

## Stimulus envelope (what `rr.py` may generate)
A random job must lie inside the DUT contract, or its failure says nothing about the DUT (findings 2026-10-15 A-C):
- **Non-flow-control builds (`vlt`, `vlt-nodpr`)**: no Rx backpressure, D9 = drop + abort, and the fixed scenarios treat any abort as an error.
  `sink_pct` is drawn from (100, 90, 70). Measured: >= 50 never fails (20 seeds x mac_gap 0..90), 45 fails ~10 %, <= 40 fails; margin 20 points.
- **`vlt-fc`**: lossless; `sink_pct` 100/90/50/20/5 and `mac_gap` up to 90 are fine (rxovf and `rand` wait for their frames; `bridge_bfm.h`).
- `mac_gap` 0/5/10/30/60/90 for all configs. `rand_frames` x `rand_maxlen` need no cap: the rand wait times out only 400000 pclk after the last received frame.
- `rr.py run --legacy-knobs` draws the old sink set for every config (out of contract: reproduces A-C). `rr.py` asserts `in_envelope()` for every generated job.
- Overload (D9 contract under deliberate overload) is covered by the fixed `rxovf` scenario (sink forced to 4 %, flagged-or-exact frames, at least one abort required in non-FC builds).
  A randomised overload class is backlog (needs a `+overload` scenario that reuses the rxovf checker; the fixed-scenario checks must stay).

## Backlog (the manager hands these to agents)
- B1 DONE `dv/vlt/sim_main.cpp`: parse `+mac_gap`, `+sink_pct`.
- B2 DONE in vlt (other four envs still to mirror): add a `rand` scenario: lengths from `lcg_lengths(seed, n, max_len)`, random pm/rate op
  interleaving; extend `dv/common/scenarios.py` golden model (`expected_rand(seed)`) and
  `crosscheck.py`, keep the five fixed scenarios unchanged; mirror in the other four envs only after vlt is stable.
- B3 DONE in vlt: random CSR/msgbus traffic (PHY-initiated reads/writes, mid-traffic resets, P-state storms) = `+rand_ctl`, see above.
- B4 x4-lane (`PIPE_NLANES_OVERRIDE=4`) random configs; iverilog `tb_scen` seed plusarg.
- B5 random runs feed `metrics/` (pass rate, unique clusters, time-to-fix) and the dashboard.
