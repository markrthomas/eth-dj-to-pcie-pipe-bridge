# AGENT_HANDOFF — resume this repo

If a session ended, this is where you pick up. Read this, then
[`PLAN.md`](PLAN.md).

## Current state — 2026-10-01 (read this first; the log below is history)

**`main` carries everything; all PRs through #30 are merged, none are open, and `main` is the only
remote branch** (the 24 merged `claude/*` branches were deleted by the owner on 2026-10-01 — the cloud
git proxy answers branch deletion with HTTP 403, so a session cannot do it; list leftovers for the
owner instead). "Still open" notes inside the dated entries below are superseded by this block.

**What exists**
- **RTL** (`rtl/`): Eth AXI-S <-> Gen6 FLIT bridge (x1 default, `PIPE_NLANES_OVERRIDE` for x4): async CDC FIFOs, framer / egress,
  Rx ingress / deframer / eth egress, `bridge_ctrl_fsm` (P-state / rate / width + PAM4 preset write), `pipe_msgbus` master,
  `msgbus_mac_tgt` (MAC-side target **with the §7.2 register file**, write buffer depth 8, D17), `bridge_rf` CSR.
  **Opt-in two-ended link flow control** (`-DFLOW_CTRL_OVERRIDE`, credits + seq loss repair, D16; default off, default results unchanged).
- **DV:** five envs (iverilog, vlt, systemc, cocotb, uvm) cross-checked against `dv/common/scenarios.py`; every env also has a flow-control-on
  `fc` target (CI); two-bridge `dv/iverilog/tb_link.sv` (flit killer); UVM FC overload test; SVA (`dv/sva`); formal
  (`async_fifo`, `ingress_gate`, `ctrl` + `ctrl` with FC, `fc` credit invariants by k-induction); `make lanes4` incl. FC; coverage 92.1 % (floor 80);
  waves, metrics DB + dashboard.
- **Power (zero-cost, no commercial tool):** `lp/oss` (Yosys+slang -> Nangate45 -> Verilator gate-level equivalence -> Icarus activity ->
  OpenSTA via the pip `openroad` wheel): 378,070 um2, **154.1 mW** on the default (D18 reset) build (PD_DP 97.6 %; CDC FIFOs ~73 %, flop arrays so pessimistic), on the dashboard,
  *estimates only*. `lp/cocotb` **`make pd-emu`** (CI): UPF-like PD_DP corruption / isolation / retention emulation on the real PMU — retain-all PASS,
  retain-nothing FAIL, minimal retained set **318 of 31,751 register bits (1 %)**, `lp/cocotb/retention_min.txt`
  (docs/power_state_emulation.md, D14 follow-up). `lp/bridge.upf` itself is still authored, never run.
- **Spec:** the real PIPE 7.1 PDF (Rev 7.1, Ref 643108) is in the **public repo `markrthomas/summary`, `docs/`**
  (`add_repo` gives a read-only clone; `pdftotext -layout` works). `~/proj` does not exist in the cloud container.
- **Decisions:** `OPEN_DECISIONS.md` D1–D17 + follow-ups (D14: power-state emulation; D16: flow control; D17: MAC regs + multi-lane).
- **Swarm:** `.claude/agents` (manager `opus`, `dv-env-tester`/`infra-agent` `sonnet`, `dv-runner` `haiku`). One run done: the manager had no sub-agent
  dispatch tool, so it ran the four envs itself sequentially (still useful; no per-agent token data — `swarm.sh` only records tokens per model).

**Scope decision (owner, 2026-10-02): no commercial-tool runs.** `bridge.upf` stays *authored, not run* for good; there is no plan to run it on a
commercial power-aware simulator, so no UPF/retention item is open. The power work that is done is OSS only: `make pd-emu` / `pd-emu-ret`, `make upf-tb`, `make power-oss`.

**Owner's open items (nothing below needs more code from a session unless noted)**
1. **Railway deploy and a first real swarm run** — need the owner's Railway account / an API key.
2. **`msgbus_mac_tgt` register file costs ~4 % of the area** for registers nothing reads — shrink or make optional? (D17)
3. **Datapath-local reset is the DEFAULT** (D18; opt out with `-DDP_RESET_DISABLE`; flow-control builds turn it off). Retain-nothing passes in
   `make pd-emu`. `bridge.upf` still carries the retention block (marked in a note, kept for `-DDP_RESET_DISABLE` builds). `lp/oss` numbers were re-measured on this
   build (378,070 um2, 154.1 mW). The `uvm` env was not runnable in the authoring container (UVM core vs Verilator); CI runs it.
4. Known unmodelled: MAC register field attributes / reserved-bit masking; per-lane message-bus replication (only for a *Variable* PHY, D17);
   mid-frame power-down; X-propagation in the power emulation; iverilog `rxovf` with FC on (it forces overload); vlt/systemc/uvm/cocotb at x4 with FC.

**Working agreement in these sessions (owner's instructions, overriding the generic Guardrails below where they differ):** open PRs as
**draft against `main`** (never stack PRs — it stranded merges twice), **the owner merges** (a session never merges unless told to), record every
design choice in `OPEN_DECISIONS.md` and list RTL behaviour changes under "Behaviour to review" in the PR body, never claim an untested thing
ran, commit/PR trailers as in the existing history.

**Commands** (pinned OSS CAD Suite 2026-04-13 on `PATH`, `VERILATOR_ROOT` unset): `make regress` (lint x2 configs + all Icarus tests incl. `link`, `fc`) ·
`make lanes4` · `make -C formal` · `make envs envs-fc crosscheck` · `make coverage` · `make pd-emu` · reset-disabled build (D18 opt-out): `make -C dv/iverilog nodpr`, `make vlt-nodpr`, `make pd-emu-ret` · `make upf-tb` · `make metrics` / `make dashboard` ·
`make power-oss` (**~30 min, 10–14 GB RAM, network** — `lp/oss/README.md`; then `python3 metrics/collect.py --power-into-latest && make dashboard`).

**New gotchas**
- Yosys `.ys` scripts do not expand `${VAR}` (`lp/oss` uses `sed`); flat synthesis of the 2 x (32 x 289-bit) FIFOs OOMs at ~8.6 GB, the hierarchical flow
  peaks ~14 GB; Verilator `--trace-underscore` on the mapped netlist OOMs (>14 GB) — activity comes from an Icarus run; OpenSTA `read_vcd` needs the VCD
  rebased to start at #0 (`lp/oss/vcd_rebase.py`) and the Nangate tech + macro LEF to link a netlist.
- Never `pkill -f <pattern>` from a tool shell whose own command line contains the pattern — it kills the shell (happened twice).
- cocotb 1.8.1 on Icarus: registers are `GPI_REGISTER`, memories `GPI_ARRAY` (indexable, elements deposit-able); a multi-case cocotb test must
  `kill()` every coroutine it started between cases or clocks / models pile up (`lp/cocotb/test_pd.py`).
- Merging PRs that all append to `.gitignore` / the shared docs conflicts trivially: merge `origin/main` into the branch and keep both sides.
- Icarus on CI is stricter than local (declare-before-use, no `break`, no array literals).

---

### History (newest first; "Still open" lines in old entries are superseded by the block above)

- **2026-10-01 (v)** — **Datapath-local reset made the default** (branch `claude/dp-reset-default`, D18): the reset is on unless
  `-DDP_RESET_DISABLE` (or `-DFLOW_CTRL_OVERRIDE`). Flipping it exposed that the Rx path was never drained (D11): at x4 a frame in flight to the
  sink was cut by the reset, so with the reset on `rx_idle` also requires an empty Rx path (`rx_out_idle`). Also fixed a latent race in
  `eth_sink_model` (frame buffer overwritten by a back-to-back frame). Targets renamed: `dpr` -> `nodpr`, `pd-emu-dpr` -> `pd-emu-ret`
  (the reset-disabled builds, in CI). Rx counters are now cleared per P1/P2 episode by default.

- **2026-10-01 (u)** — **Datapath-local reset, opt-in** (PR #30; since made the default, see (v)): `-DDP_RESET_OVERRIDE` resets the PD_DP instances
  from ST_LOWPWR to the next ST_DRAIN (no new ports / FSM change; default build wired textually to the plain resets, bit-identical).
  `make -C dv/iverilog dpr`, `make vlt-dpr`, `make pd-emu-dpr` (CI): retain-nothing PASSES (default build needs 318 bits), mutation-checked.
  Behaviour change when on: Rx diagnostic counters cleared per P1/P2 episode; mutually exclusive with link flow control. Owner to decide
  default-on and a retention-free UPF variant. Also fixed a latent race in `tb_pm` (PAM4CFG data check waits 4 pclk).

- **2026-10-01 (t)** — **PD_DP power-state emulation** (branch `claude/pd-emu`): `make pd-emu` (`lp/cocotb`: `pd_top.sv` = bridge
  loopback + real PMU, `pd_emu.py` corruption/isolation/retention, `test_pd.py` matrix; in the CI cocotb job). Retain-all PASS,
  retain-nothing FAIL (negative control), minimal retained set 318/31,751 bits (`retention_min.txt`). docs/power_state_emulation.md,
  D14 follow-up. Not tested: DP-reset alternative (needs RTL change), mid-frame power-down, X-propagation. Open: PR #27 (OSS power flow).

- **2026-09-30 (s)** — **Real spec found** (`markrthomas/summary`, `docs/PHY Interface ... .pdf`, PIPE 7.1 Rev 7.1; clone
  read-only via `add_repo`). **MAC register file §7.2 implemented** in `msgbus_mac_tgt` (defined addresses, RX2/TX2/CMN2
  windows, write buffer with atomic commit, reserved -> 0) + `tb_msgbus_mac` cases I-K; **multi-lane message bus:** no RTL
  change - the single shared bus pair is the spec-permitted form for a Fixed PHY (D17; per-lane replication only needed for a
  Variable PHY). Branch `claude/mac-regs`. Not modelled: field attributes / reserved-bit masking. The spec PDF is a 7.8 MB
  public-repo file; `pdftotext -layout` works on it.

- **2026-09-30 (r)** — **UVM FC overload** (branch `claude/uvm-fc-overload`): `fc_overload` in
  `scen_test` (FC only) stalls the sink and floods; must see 0 drops/aborts and 40 intact frames.
  Mutation `credit_ok=1` fails it. Closes the UVM credit-gate gap. Remaining: iverilog rxovf with FC,
  vlt/systemc/uvm/cocotb at x4, spec-dependent items.

- **2026-09-30 (q)** — **FC formal + x4** (branch `claude/fc-formal-lanes`): `ctrl.sby` gains
  `prove_fc`/`cover_fc` (credit-only flits free); `make lanes4` covers FC (lint, fc suite, `tb_link`).
  Details in D16 follow-up 3. Still open: UVM overload scenario (UVM cannot catch a broken credit
  gate), iverilog rxovf with FC on (MAC reg map and multi-lane msgbus: see D17, done).

- **2026-09-30 (p)** — **Flow control ON in vlt/systemc/uvm/cocotb** (branch `claude/fc-dv-envs`):
  `make vlt-fc systemc-fc uvm-fc cocotb-fc` (= `make -C dv/<env> fc`, `make envs-fc`; hooked into the
  CI jobs of each env and into `make ci`). Hypothesis confirmed: all four envs already loop pipe_tx
  into pipe_rx, so **no credit-advertising peer was needed**; only a define (`-DFLOW_CTRL_OVERRIDE`)
  plus FC-aware flit checkers. Each env's flit monitor now assembles the 32 beats and applies the
  `pipe_phy_model.sv` checks (header, length, sof/eof, zero padding, seq == data flits since reset;
  with FC on DLP bytes 242..245 exempt, credit-only flits legal, counted separately) - also with FC
  off (new checks, default results unchanged). Each FC run also fails if no credit-only flit was seen.
  vlt/systemc/cocotb run the coverage-only `rxovf` scenario with the expectation flipped (FC on:
  0 aborted, all 60 frames good); UVM has no rxovf scenario. Details/mutation evidence: OPEN_DECISIONS D16.
- **2026-09-30 (o)** — **Flow-control verification** (branch `claude/fc-verify`): `make -C dv/iverilog fc`
  (loop + pm + 5 scenarios with `-DFLOW_CTRL_OVERRIDE`, in regress) found and fixed a real bug
  (credit-only flit racing the DRAIN->change transition; `tx_idle` now includes `!fc_cr_req`).
  `pipe_phy_model` counts expected seq since DUT reset. `tb_link` failure on credit leak is now clean.
  Still open: vlt/systemc/uvm/cocotb with FC on (need a credit-sourcing peer BFM).

- **2026-09-30 (n)** — **Infra follow-up to D16** (branch `claude/infra-fc`). D16 flow control
  (PR #19, merged) is opt-in; infra now covers it: `make lint` also lints with
  `-DFLOW_CTRL_OVERRIDE`; `tb_link` (two bridges, flit killer) is in `make regress` (CI);
  `formal/fc.sby` proves the `fc_ctl` credit invariants (k-induction, mutation-checked: gating removed -> F-FC2 fails). Still NOT run
  with flow control on: vlt/systemc/uvm/cocotb envs, lanes4. Known gap: removing the loss
  repair stalls `tb_link` until the global timeout rather than failing cleanly.

- **2026-09-30 (l)** — **MAC-side message-bus target added** (`rtl/msgbus_mac_tgt.sv`, branch
  `claude/msgbus-mac-target`): answers PHY write_committed with write_ack and PHY read with
  read_completion (data 0 — no MAC register map, §7.2 unavailable), discards write_uncommitted, arbitrates
  the M2P bus with the master (frame never interrupted; master priority). New `make -C dv/iverilog
  msgbus_mac` (in `make regress`), mutation-checked; SVA MB6 added, MB5 bound +8. Formal (master+FSM) and all
  envs incl. UVM re-run and pass locally. `pipe_msgbus` gained a `tx_active` output only. Removed the stale
  `.claude/worktrees/` checkouts. **Still open:** multi-lane bus scaling (needs spec text), real Rx flow
  control, MAC register map (§7.2), Railway deploy, first real swarm run (the commercial UPF run was dropped from the plan 2026-10-02).

- **2026-09-30 (k)** — Owner pasted the PIPE 7.1 Rx Control tables (7.1.4..7.1.11). **PAM4RestrictedLevels
  is Rx Control1 `12'h004` bit 2** (not 12'h406); it is LTSSM-timed (set after a Gen6 rate change if Tx EQ
  is expected, cleared at TS0->TS1, PHY clears it on rate change). Owner chose **document-only**: the
  bridge does not write it (integrator's LTSSM must own 12'h004). **No precoding-enable register exists
  in the PHY register map**. Docs only (`OPEN_DECISIONS` D8, `pam4_notes.md`). The message-bus register
  work is now complete; open: multi-lane bus scaling, MAC-side msgbus target (PHY-initiated requests).

- **2026-09-30 (j)** — Owner pasted the PIPE 7.1 Tx Control tables (7.1.12..7.1.21). **Found a
  real defect and fixed it:** `12'h406` is Tx Control6 = **FS**, not a PAM4 register, so every Gen6
  link-up wrote a bogus FS. No PAM4-precoding register exists in Tx Control0..10. Owner chose to
  write the **Tx preset index** instead: `MB_ADDR_TX_PRESET = 12'h405` (LocalPresetIndex[5:0];
  bit 7 = GetLocalPresetCoefficients strobe, so the RF masks [7:6]); `PAM4CFG` reset 0x21 = 64 GT/s
  P0. Precoding-enable is dropped (register not found). All envs + formal + SVA re-run and pass;
  reserved-bit masking mutation-checked in `tb_pm`. **Still unknown:** where PAM4 precoding is
  controlled (need the Rx Control registers), multi-lane bus scaling.

- **2026-09-30 (i)** — Owner pasted PIPE 7.1 §6.1.4. **Message-bus framing + opcodes are now
  verified against the spec text** (Tables 6-9..6-14, Fig 6-1). Found + fixed a real bug: the
  master decoded every P2M byte as a command (a read_completion data byte `5_` looked like a
  write_ack); `pipe_msgbus` now frames P2M by transaction length. New unit test
  `make -C dv/iverilog msgbus` (in `make regress`), mutation-checked. Formal (pinned suite),
  vlt(SVA), cocotb, systemc, lanes4, upf-tb, wave-check all pass; UVM left to CI (PHY driver
  unchanged). **Still open:** PAM4 register function + PAM4CFG byte (need Tx Control0..10 bit
  fields), no MAC-side msgbus target (PHY-initiated requests are never answered), multi-lane bus.

- **2026-09-30 (h)** — Owner pasted PIPE 7.1 (ref 643108) **Table 7-1 (PHY register map)**.
  Confirmed: 12-bit message-bus address space; `12'h406` = TX1 "PHY Tx Control6" is a real
  register (old `8'h01` would have hit Rx Margin Control1). **Still unconfirmed:** that Tx
  Control6 carries PAM4 controls, the meaning of our PAM4CFG byte, and the framing/opcodes
  (§6.1.4, Table 6-10 not seen). Next: ask for §6.1.4.x + the Tx Control0..10 bit-field
  tables (7.1.x), then verify/fix `pipe_msgbus` and `MB_ADDR_TX_PRESET`/PAM4CFG.

- **2026-09-30 (g)** — **D8 message-bus interface fixed** (branch `claude/d8-msgbus-spec`).
  Cross-checking against the sibling `ucie-rdi-to-pcie6-pipe7` (which cites PIPE 7.1
  §6.1.4.2) showed the real bus is **one 8-bit M2P + one 8-bit P2M byte bus, idle 8'h00,
  12-bit addresses**; the old 4-bit cmd + 8-bit data split ports were wrong. Top ports
  `pipe_m2p_msgbus[7:0]` / `pipe_p2m_msgbus[7:0]` replace the four old ones;
  `pipe_msgbus` sends `{WR_C,addr[11:8]}`, `addr[7:0]`, `data` and accepts `p2m[7:4]==WR_ACK`;
  `MB_ADDR_TX_PRESET` = 12'h406 (sibling's working offset — the PAM4 offset and the PAM4CFG
  byte meaning remain **unverified vs the spec**, which is unreachable from this container).
  All envs ported and run: iverilog (`make regress`, `lanes4`), vlt (SVA on), systemc, cocotb,
  upf-tb, wave-check-all, formal (pinned OSS CAD Suite: all prove PASS, covers reached);
  mutations caught by iverilog smoke, vlt SVA `a_mb3_byte1`, formal `a_fmb3_byte1`.
  **Gotchas:** `make formal` needs the pinned OSS CAD Suite (yosys-slang) — apt yosys lacks
  it; `Agent` worktree isolation is unreliable about its base commit (check
  `grep pipe_m2p_msgbus rtl/eth_dj_pipe7_bridge.sv` in a worktree before working).

- **2026-09-29 (f)** — Owner delegated D1/D8/D10/D14 ("most logical action"); recorded
  in `OPEN_DECISIONS.md`. **D1:** x1 default kept; `PIPE_NLANES_OVERRIDE` + `make lanes4`
  (lint + iverilog suite at x4, in CI) added and passing. **D8:** could NOT verify the
  msgbus encodings/address against PIPE 7.1 (spec unavailable) — still a placeholder,
  flagged for the integrator. **D10, D14:** kept as-is with rationale (no RTL change);
  `PHY_TIMEOUT=1024` is a sim value, real ~10 ms. Not verified at x4: vlt/systemc/uvm/
  cocotb, formal, SVA.

- **2026-09-29 (k)** — **M8 close-out** (branch `claude/m8-closeout`). Self-review of
  M4–M7; docs refreshed (README status/quick start, PLAN §5/§8/§12 + success-criteria
  table, gotchas); `make stress` implemented (vlt, 20 seeds, all checks). All of
  M4–M7 landed via PRs #5–#8 (the owner merged #5–#7). **Open for the owner:** D14
  (DP reset/power-good vs full retention; FSM<->PMU handshake), D10 (timeout
  proceeds), D8 msgbus address/framing vs the PIPE 7.1 spec, D1 lane count;
  a Railway deploy; a first swarm
  run. Known gaps: framer single-buffered (`c_b2b_flits` unhit), no latency metric,
  cocotb has no SVA.

- **2026-09-29 (j)** — **M7 done** (branch `claude/m7-infra`, on top of M6).
  `dv/waves/` (7 generated `.gtkw`, `wave_dump.sv` behind `WAVES=1`, `wave_check.py`;
  `make wave-<test>`, `wave-check-all`), `metrics/` (schema, `collect.py`,
  `dashboard.py`, committed `metrics.db` + `dashboard.html` from a real run),
  `Dockerfile` + `.dockerignore` + `docker/{entrypoint,swarm}.sh` + `swarm-task.md`,
  `railway.toml`, `.claude/agents/*` (4 agents), `.github/workflows/swarm.yml`
  (manual). The image was built and run here (all 7 flows + crosscheck green inside
  the container); **not deployed to Railway; swarm not run** (no API key). D15.
  **Gotcha:** `.dockerignore` strips trailing slashes — `formal/*/` excluded all of
  `formal/`. **Next: M8** close-out.

- **2026-09-29 (i)** — **M6 done** (branch `claude/m6-upf`, on top of M5). `lp/bridge.upf`
  (UPF 2.1: PD_AON = ctrl/msgbus/rf/glue, PD_DP = datapath, header switch, iso clamp 0 /
  clamp 1 on drain flags, full PD_DP retention), `lp/pipe7_pmu.sv` (DV-only),
  `lp/tb_pipe7_upf_power.sv`, `docs/power_intent.md`, D14. **The UPF has never been
  parsed or simulated** (no PA tool). `make upf` prints that; `make upf-tb` runs the TB
  functionally on Icarus (PMU order + no-handshake timing assumption + traffic across
  P1/P2) and is a CI regress-job step. Open items needing the owner: DP reset/power-good
  (RTL) vs full retention; FSM<->PMU handshake. **Next: M7** (infra).

- **2026-09-29 (h)** — **M5 done** (branch `claude/m5-sva-formal`, on top of M4).
  `dv/sva/{bridge_sva,async_fifo_sva}.sv` bound (`bind`) into the DUT in the Verilator
  envs (vlt/systemc/uvm, `--assert`; `SVA=0` to drop); 21 property groups + 12 covers
  (11 hit; `c_b2b_flits` unhit because the framer is single-buffered). `formal/`:
  `async_fifo.sby` (multiclock, black-box, W=4/DEPTH=4), `ingress_gate.sby`, `ctrl.sby`
  (ctrl FSM + msgbus + tx_egress, via yosys-slang); all PDR-proven + covers reached,
  `make formal` ~75 s. `ASSERTIONS.md` lists every property + mutation evidence.
  Decisions D13. **Gotchas:** `make formal` needs the pinned OSS CAD Suite (slang
  plugin); Yosys' native parser silently turns hierarchical refs into free wires —
  never use them outside slang-read harnesses. **Next: M6** (UPF).

- **2026-09-29 (g)** — **M4 done** (branch `claude/m4-dv-envs`, stacked on the
  unmerged M3 branch). All five DV envs run the shared scenario set
  (`dv/common/scenarios.py` golden model, `crosscheck.py`): `dv/iverilog/tb_scen.sv`
  (in `make regress`), `dv/vlt` (C++ harness `dv/common/cpp/bridge_bfm.h` + coverage:
  line+branch 95.7% on Verilator 5.047 / 95.3% on 5.020, floor 80%), `dv/systemc`
  (same C++ harness under Verilator `--sc`), `dv/cocotb` (cocotb 1.8.1 + pyuvm 5.0.0
  + PyVSC `fcov.json`, apt Icarus), `dv/uvm` (Accellera uvm-core cloned at a pinned
  commit, Verilator `--binary --timing`). `make crosscheck`: all five agree. Two
  mutants (last-byte corruption in `eth_egress`, PMCNT off-by-one) killed in all
  five envs. No RTL changes. Decisions in `OPEN_DECISIONS.md` D12. **Env gotchas:**
  `make uvm` needs Verilator >= 5.03x (apt 5.020 fails on uvm-core); cocotb Makefile
  forces the python3 cocotb-config ahead of the OSS CAD Suite's. **Next: M5** (SVA +
  formal).

- **2026-09-29 (f)** — **M3 done** (branch `claude/m3-control-plane`, based on main
  after PR #3 merged). Added `rtl/{pipe_msgbus,bridge_ctrl_fsm,bridge_rf,tx_ingress_gate}.sv`,
  a pclk-domain CSR port on the top, `dv/common/pipe_phy_ctrl_model.sv` (PhyStatus +
  msgbus target + "no Tx outside P0/during a change" checker), `dv/iverilog/{tb_pm,tb_rxovf}.sv`
  + `loop_harness.svh`; smoke now checks the reset/link-up contract. Decisions D7–D11 in
  `OPEN_DECISIONS.md` (CSR port, msgbus usage, Rx drop+abort with `eth_rx_tuser[0]`,
  timeout-proceeds, drain at frame boundary / no P0s). `make regress` (lint + smoke tx
  loop pm rxovf) GREEN on apt Icarus 12 / Verilator 5.020 **and** on the CI-pinned OSS
  CAD Suite 2026-04-13 (Icarus 14-devel, Verilator 5.047) unpacked locally. New checks
  mutation-tested (5 mutants, all killed). **Icarus gotcha:** a bare wildcard-imported
  pkg constant used directly in a port connection becomes an implicit 1-bit net — copy
  it to a local wire first. Limitations: width change is handshake-only; pclk assumed
  running in P2; Rx frame-level state not drained. **Next action: M4** (five DV envs).

- **2026-09-29 (e)** — **M2 done** (branch `claude/m2-rx-loopback`). Added
  `rtl/{rx_ingress,rx_deframer,eth_egress}.sv` (Rx CDC = second `async_fifo`),
  `dv/common/eth_sink_model.sv`, `dv/iverilog/tb_loop.sv` (eth->bridge->PIPE looped
  to Rx->bridge->eth, 115 frames incl. gapped source + 90%-ready sink).
  `make regress` GREEN (lint + smoke + tx + loop); Rx mutation-checked.
  Limitations: PIPE Rx has no backpressure — a flit completing while the previous
  is still being deframed is DROPPED (`dut.rx_dropped_flits`, checked 0 in the TB);
  a sink slower than ~4 GB/s or long stalls would drop. Real credit/flow control
  is undesigned (needs an owner decision, likely M3). sof not checked in RTL.
  **CI gotcha:** the pinned OSS CAD Suite Icarus is stricter than apt Icarus 12 —
  declare nets before use. **Next action: T3.1** control plane (`pipe_msgbus`,
  `bridge_ctrl_fsm`, `bridge_rf`; P0/P1/P2, rate/width change with drain) — this
  replaces the M1 hardwired P0 / `tx_en=1`.

- **2026-09-29 (d)** — **M1 done** (branch `claude/m1-tx-datapath`). Owner delegated
  D1/D2/D5, recommended defaults adopted (see `OPEN_DECISIONS.md`). Added
  `rtl/{async_fifo,tx_framer,tx_egress}.sv`, flit-format params in the pkg,
  `dv/common/{eth_mac_model,pipe_phy_model}.sv`, `dv/iverilog/tb_tx.sv`.
  `make regress` GREEN (lint + smoke + tx). Behaviour notes: `pipe_powerdown` is now
  held at **P0** (M1 placeholder, was P1; M3 ctrl FSM must own it); `eth_tuser` not
  carried; DLP/FEC/CRC zero; framer is single-buffered (half throughput); Rx path
  still a stub. Environment: needed `apt install iverilog verilator` (Icarus 12,
  Verilator 5.020); Icarus lacks `break`, array literals, and mis-drives an enum
  output that is also read internally. **Next action: T2.1** Rx path
  (`rx_ingress`/`rx_cdc`/`rx_deframer`/`eth_egress`) + loopback scoreboard.

- **2026-09-29 (c)** — Pickup session (cloud). Re-read all docs/RTL. Wrote
  [`OPEN_DECISIONS.md`](OPEN_DECISIONS.md): lane count vs. 200G rate (x1 can't carry
  it), flit payload semantics, widths/PCLK, tuser, missing `~/proj` siblings.
  **M1/T1.1 is BLOCKED on owner answers to D1, D2, D5** (it is RTL behaviour).
  `make regress` could not be re-run this session (shell tool unavailable); last
  known state is green per (b).
- **2026-09-29 (b)** — **Baseline set to PAM4 / PCIe Gen6 FLIT mode** (PLAN §12
  resolved) and **M0 scaffold landed**. This is now a **standalone git repo**
  (`git init`; remote `origin` = github.com/markrthomas/**eth-dj-to-pcie-pipe-bridge**
  — note the GitHub repo name differs from this local dir name). Present:
  `rtl/eth_dj_pipe7_pkg.sv` (PAM4/
  Gen6 params + enums), `rtl/eth_dj_pipe7_bridge.sv` (top stub, ports frozen per
  §2), `dv/iverilog/tb_smoke.sv` + Makefile, stub Makefiles for `dv/{vlt,uvm,
  systemc,cocotb}`, placeholder READMEs for `dv/{common,sva,waves}`, `formal/`,
  `lp/`, `metrics/`, `docker/`, `.claude/agents/`, root `Makefile`, `.gitignore`,
  `.github/workflows/ci.yml`, `docs/pam4_notes.md`. **`make regress` (lint +
  Icarus smoke) is GREEN; `make ci` exits 0 (coverage/formal are stubs).**
  **Next action: `PLAN.md` task T1.1** — Tx datapath (eth→pipe) with 256B FLIT
  assembly; remove the M0 lint waivers as signals get consumed.
- **2026-09-29 (a)** — First-cut plan written (`docs/PLAN.md`).

## How to resume in three steps

1. **Read the two reference repos** (do not reinvent):
   - `~/proj/axi-on-ucie-to-mem` — copy the `Makefile` targets, `dv/` five-env
     layout, `dv/sva/`, `formal/`, `metrics/` dashboard, `docker/` + `.claude/agents/`
     swarm, `railway.toml`, `Dockerfile`, GTKWave `dv/waves/*.gtkw`.
   - `~/proj/ucie_rdi_to_pcie6_pipe7` — copy the PIPE 7.1 interface model, the
     `pipe7_pmu`, the message-bus handshakes, and the UPF flow
     (`test/upf/bridge.upf`, `docs/power_intent.md`).
   - Also `~/proj/DV_STANDARDS.md` (mandatory targets/CI) and `~/proj/dv_env.mk`
     (version pins: OSS CAD Suite + `cocotb==1.8.1`).

2. **Find the next unchecked task** in `PLAN.md` §11 (milestones M0→M8). Work
   top-to-bottom; each milestone has a `make` gate that must go green before the
   next.

3. **Verify against the gate**, check the box in `PLAN.md`, update the "Current state"
   block at the top (and add a dated line to the History), and commit.

## Environment gotchas (from workspace memory — heed these)

- **cocotb + Icarus:** set `ICARUS_BIN_DIR=/usr/bin` to avoid the OSS CAD Suite
  Python mismatch; drive valid/ready exactly once *after* the clock edge to
  avoid handshake races. (memory `cocotb-apb-slave-timing`,
  `pyvsc-functional-coverage`)
- **PyVSC functional coverage:** install pyvsc into `/usr/bin/python3`.
- **UVM on Verilator:** needs Verilator >= 5.03x. The pinned OSS CAD Suite
  2026-04-13 (Verilator 5.047) works; apt Verilator 5.020 fails on uvm-core
  (`PKGNODECL`). `dv/uvm/Makefile` clones uvm-core at a pinned commit.
  **Keep `VERILATOR_ROOT` unset.**
- **Formal:** `make formal` needs the pinned suite (yosys-slang plugin; native
  Yosys rejects module-header package imports). Native Yosys silently turns
  hierarchical references into free wires — only use them in slang-read harnesses.
- **Docker:** `.dockerignore` strips trailing slashes (`dir/*/` excludes files).
  Behind a TLS-intercepting proxy build with `--network host`, proxy build args
  and `--secret id=extra_ca,src=<pem>`.
- **UPF:** no OSS power-aware simulator exists and commercial-tool runs are out of scope (owner, 2026-10-02); `make upf` is authored +
  documented and prints a stub. (see `PLAN.md` §9)
- **Icarus + SV struct literals:** Icarus-11 can't compile SV struct literals /
  `return` in some forms — keep a plain-Verilog model for anything that must run
  under Icarus or Yosys formal (this bit `IP-ucie-rdi-to-pcie-pipe`).

## Guardrails (from `~/proj/CLAUDE.md`)

- Open PRs **ready for review**, not drafts.
- Finish what you open: CI green + no conflicts → self-review the diff → merge →
  delete branch (remote + local). **Stop and leave the PR for the human** when
  it's an RTL/DUT behavior change, a change to what a regression checks, or
  anything you couldn't verify end-to-end (e.g. UPF, UVM without a license).
- If branch deletion is blocked (git proxy 403), list the leftover branches for
  the user instead of skipping silently.

## Don't

- Don't fabricate coverage/perf numbers — the metrics DB has a `kind` field
  (`measured`/`estimated`/`not_attributable`); record gaps honestly.
- Don't put assertions in `rtl/` — SVA goes in `dv/sva/` via `bind`.
- Don't set `VERILATOR_ROOT`.
