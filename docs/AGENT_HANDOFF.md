# AGENT_HANDOFF — resume this repo

If a session ended, this is where you pick up. Read this, then
[`PLAN.md`](PLAN.md).

## Where things stand (update this block every session)

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
  control, MAC register map (§7.2), commercial UPF run, Railway deploy, first real swarm run.

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
  running `lp/bridge.upf` on a commercial PA tool; a Railway deploy; a first swarm
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

3. **Verify against the gate**, check the box in `PLAN.md`, update the "Where
   things stand" block above, and commit.

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
- **UPF:** no OSS power-aware simulator exists here; `make upf` is authored +
  documented, run on a commercial tool, OSS-stubbed. (see `PLAN.md` §9)
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
