# PLAN — 802.3dj Ethernet → PCIe PIPE 7.1 Bridge (first cut)

**Repo:** `eth-dj-pcie-pipe7_1-bridge` (standalone git repo since 2026-09-29)
**Baseline:** **PAM4** — PIPE side = PCIe **Gen6 (64 GT/s, PAM4, FLIT mode)**;
802.3dj side = **200G/lane PAM4**. See [`pam4_notes.md`](pam4_notes.md).
**Author of this draft:** initial planning pass, 2026-09-29.
**Audience:** the next engineer or AI agent to work this repo. If a session
ends mid-task, read this file plus [`AGENT_HANDOFF.md`](AGENT_HANDOFF.md) and
you can resume from the task backlog in §11.

This is a **first-cut plan**, not final RTL. It fixes scope, interfaces,
microarchitecture, the five-environment verification strategy, the required
infra (coverage, SVA, UPF, dashboard, GTKWave, CI, Railway, agent swarm), and a
phased backlog with acceptance criteria. Where a decision is still open it is
marked **[OPEN]** with a recommended default.

---

## 0. Reference designs in this workspace (read these first)

Two sibling repos under `~/proj` already solve most of the hard parts. **Do not
reinvent — port and adapt.**

| Sibling | What to borrow |
|---|---|
| **`ucie_rdi_to_pcie6_pipe7`** | The **closest architectural twin**: a MAC-facing **PIPE 7.1** bridge with a framer/deframer/gearbox datapath, a DV-only `pipe7_pmu` power sequencer, PowerDown/Rate/Width message-bus handshakes, and a full **UPF** flow (`test/upf/bridge.upf`, `docs/power_intent.md`). Copy the PIPE 7.1 interface model, the PMU, and the UPF structure. |
| **`axi-on-ucie-to-mem`** | The **gold-standard DV+infra template**: five DV environments under `dv/`, `dv/sva/` bind-based assertions, `formal/*.sby`, a SQLite **metrics dashboard** (`metrics/` → `dashboard.html`), a **Docker + `.claude/agents/` agent swarm** (`docker/swarm.sh`), `railway.toml`, per-test **GTKWave** `.gtkw` sessions, and the standard `Makefile` target set. Clone its skeleton wholesale. |
| **`eth_axi4s_to_pcie_pipe_bypass`** | Prior art for the **Ethernet-AXI4-Stream → PCIe PIPE** direction (bypass/passthrough variant). Reference for the ingress packet interface shape. |
| **`~/proj/DV_STANDARDS.md`** | The mandatory Makefile targets, CI job layout, coverage/formal standards, and directory-layout standard every repo in this workspace must follow. |

**Tool version pins** come from `~/proj/dv_env.mk`: `OSS_CAD_SUITE_VERSION`
(currently `2026-04-13`) and `cocotb==1.8.1`. CI and Docker must pin the same.

---

## 1. Scope & goals

### In scope
- Synthesizable RTL bridge: **802.3dj MAC/PCS packet stream ⇄ PCIe PIPE 7.1**
  MAC-facing parallel interface, both directions.
- Clock-domain crossing, width gearbox, framing/deframing, elastic buffering
  with credit/backpressure flow control.
- PIPE 7.1 **message-bus** command/status handling for rate, width, and
  power-state (P0/P1/P2) transitions, driven by a small bridge control FSM.
- Five independent testbenches (§5), coverage, SVA, formal, and a UPF
  power-aware sim (§6–§9).
- Full build/run infra: `make` targets, Python tooling, GTKWave per test,
  metrics/coverage dashboard, GitHub Actions CI, Railway for larger runs, and
  an optional AI agent swarm (§10).

### Explicitly out of scope (first cut)
- Analog/SerDes PHY, 802.3dj RS-FEC/PAM4 electrical layer, PCIe LTSSM/link
  training beyond the PIPE MAC-facing handshakes. We model the PHY side with
  DV BFMs, not RTL.
- Full Ethernet MAC (preamble/IPG/CRC) and full PCIe TL/DL layers. The bridge
  sits **between** an existing MAC/PCS and an existing PIPE PHY; both peers are
  DV models.
- ASIC synthesis/PnR sign-off. Verilator `--lint-only` + Yosys generic
  elaboration is the synthesizability bar for the first cut.

### Success criteria (definition of done for the first cut)
1. `make regress` (lint + primary sim) green locally and in CI.
2. `make ci` (regress + coverage + formal) green; line coverage ≥ 80% on the
   bridge datapath and control modules.
3. All five DV environments build and pass their smoke test.
4. SVA assertions bound and passing in at least the Verilator and cocotb flows;
   formal proves the flow-control safety properties.
5. UPF power-aware sim documented and runnable (commercial tool; OSS-stubbed
   with a clear message — see §9).
6. Dashboard renders; GTKWave session opens per test; Railway job defined.

---

## 2. Interfaces

> Widths and exact signal lists are **[OPEN]** pending the parameter choices in
> §2.3; the defaults below are the first-cut target. Freeze them in
> `rtl/eth_dj_pipe7_pkg.sv` and keep this section in sync.

### 2.1 Ingress/egress — 802.3dj MAC/PCS side (`eth_*`)
Model the Ethernet side as an **AXI4-Stream packet interface** carrying MAC/PCS
payload (this matches `eth_axi4s_to_pcie_pipe_bypass` and keeps the bridge
PHY-agnostic):

| Signal | Dir (to bridge) | Notes |
|---|---|---|
| `eth_clk`, `eth_rst_n` | in | 802.3dj-side clock domain. |
| `eth_tvalid/tready` | in/out | AXI4-Stream handshake. |
| `eth_tdata[W-1:0]` | in | Packet data. **[OPEN]** `W` default **256b** (aligns to a 200G/lane-class MAC datapath at a sane PCLK). |
| `eth_tkeep[W/8-1:0]` | in | Byte enables for the final beat. |
| `eth_tlast` | in | End-of-frame. |
| `eth_tuser[U-1:0]` | in | Sideband: SOF, error, and an 802.3dj lane/channel tag. |

The reverse (PIPE → Ethernet) direction presents the mirror `eth_rx_*` stream.

### 2.2 PIPE 7.1 side (`pipe_*`)
Model per **PCIe PIPE 7.1** (MAC-facing, SerDes architecture). Port names track
`ucie_rdi_to_pcie6_pipe7`:

| Signal group | Dir (to bridge) | Notes |
|---|---|---|
| `pclk` | in | PIPE parallel clock (PHY-sourced). |
| `pipe_tx_data[D-1:0]`, `pipe_tx_data_valid` | out | Parallel Tx datapath. **[OPEN]** `D` default **64b/lane**. |
| `pipe_rx_data[D-1:0]`, `pipe_rx_data_valid` | in | Parallel Rx datapath. |
| `pipe_tx_start_block`, `pipe_rx_start_block` | out/in | **Gen6 FLIT-boundary** markers (start of a 256B flit). In Gen6 FLIT mode there is **no 128b/130b sync header** — encoding is 1b/1b; earlier gens' block framing is a fallback only. |
| `pipe_width[1:0]`, `pipe_rate[2:0]` | out | Requested PIPE width / data rate. Baseline `pipe_rate = Gen6 (PAM4)`. |
| `pipe_powerdown[1:0]` | out | P0/P0s/P1/P2 request. |
| `pipe_phy_status`, `pipe_rx_valid`, `pipe_rx_elec_idle` | in | PHY status. |
| **Message bus** `pipe_m2p_*` / `pipe_p2m_*` (4-bit cmd + data) | out/in | PIPE 7.x replaces most sidebands with the 4-bit message bus. Rate/width/power **and the PAM4 controls** (PhyTxControl, Tx precoding/Gray enable, PAM4 presets, RxMargin) are negotiated here. |

### 2.3 Parameters (frozen skeleton in `rtl/eth_dj_pipe7_pkg.sv`)
- `PAM4_BITS_PER_SYM = 2` (both sides are PAM4; digital adapter never sees levels).
- `ETH_DATA_W` (default 256), `ETH_KEEP_W`, `ETH_USER_W` (default 8).
- `PIPE_DATA_W` (default 64), `PIPE_NLANES` (default 1 for first cut; design the
  datapath lane-parametric so 2/4/8 lanes are a parameter bump later), `PIPE_BUS_W`.
- `FLIT_BYTES = 256` (Gen6 fixed flit: 242 TLP + 6 DLP + 8 FEC/CRC).
- `MSGBUS_CMD_W = 4`, `MSGBUS_DATA_W = 8`.
- `FIFO_DEPTH` for the async CDC + elastic buffers (default 32, sized for the
  worst-case burst; confirm against rate ratio).
- Enums: `pipe_rate_e` (baseline `RATE_GEN6`), `pipe_pwr_e`, `bridge_state_e`.

---

## 3. Microarchitecture

```
        802.3dj (eth_clk)                 bridge core                    PIPE 7.1 (pclk)
   ┌───────────────────────┐   ┌──────────────────────────────────┐   ┌────────────────────┐
   │ MAC/PCS  (DV model)   │   │                                  │   │  PIPE PHY (DV model)│
   │  eth_tx AXI4-S  ──────┼──▶│ ingress ─▶ tx_cdc ─▶ framer ─▶   │   │                    │
   │                       │   │            (async  (add PIPE     gearbox ─▶ egress ──────┼──▶ pipe_tx_data
   │                       │   │             FIFO)   block/hdr,   │   │                    │
   │                       │   │                     credit gate) │   │                    │
   │  eth_rx AXI4-S  ◀─────┼───┤ egress ◀─ deframer ◀─ rx_burst ◀─┼── rx_cdc ◀── ingress ◀─┼─── pipe_rx_data
   │                       │   │                                  │   │                    │
   └───────────────────────┘   │        ┌──────────────────┐      │   └────────────────────┘
                               │        │  ctrl FSM + rf   │◀────▶│  message bus (m2p/p2m):
                               │        │  (rate/width/PM) │      │  rate, width, powerdown,
                               │        └──────────────────┘      │  phy_status handshakes
                               │        + pmu (DV-only power seq) │
                               └──────────────────────────────────┘
```

### Module inventory (target `rtl/`)
| Module | Role |
|---|---|
| `eth_dj_pipe7_pkg.sv` | Params, typedefs, message-bus opcodes, FSM enums. |
| `eth_dj_pipe7_bridge.sv` | Top: instantiates the datapath + control, exposes the two interfaces. |
| `eth_ingress.sv` | 802.3dj AXI4-Stream sink; SOF/EOF/tkeep capture; packetization to internal flit. |
| `tx_cdc.sv` | Async FIFO, `eth_clk` → `pclk`. Reuse the workspace async-FIFO (see `axi4_to_dfi_ddr`/`axi-on-ucie-to-mem` FIFOs). |
| `tx_framer.sv` | Map internal packets into **Gen6 256B FLITs** on the PIPE Tx datapath; flit-boundary (`start_block`) generation; FEC/CRC bytes passthrough (first cut); credit gate. |
| `tx_gearbox.sv` | Width adaptation `ETH_DATA_W` ↔ `PIPE_DATA_W × PIPE_NLANES`. |
| `tx_egress.sv` | Drive `pipe_tx_data*`; honor `pipe_phy_status`/power state. |
| `rx_ingress.sv` | Capture `pipe_rx_data*`; **FLIT-lock** (align to 256B flit boundary via `start_block`). |
| `rx_cdc.sv` | Async FIFO, `pclk` → `eth_clk`. |
| `rx_deframer.sv` | Strip PIPE framing; reassemble Ethernet frames. |
| `rx_burst.sv` / `eth_egress.sv` | Emit `eth_rx_*` AXI4-Stream. |
| `pipe_msgbus.sv` | 4-bit message-bus master/target: rate/width/powerdown/margining commands + status. |
| `bridge_ctrl_fsm.sv` | Sequences P0↔P1↔P2, rate/width changes, drains datapath before power transitions. |
| `bridge_rf.sv` | Config/status register file (retained across low-power episodes — see UPF §9). |

### DV-only (not synthesized into the DUT)
| Module | Role |
|---|---|
| `pipe7_pmu.sv` | Power sequencer that drives UPF supply/isolation/retention controls (the DUT has no power ports — standard authored-TB pattern, per `ucie_rdi_to_pcie6_pipe7`). |
| `eth_mac_model` / `pipe_phy_model` | BFMs for the two peers, shared across the DV environments. |

---

## 4. Directory layout

Follows `~/proj/DV_STANDARDS.md` and the `axi-on-ucie-to-mem` skeleton:

```
rtl/                         synthesizable design (module inventory §3)
dv/
  iverilog/                  directed Icarus TB + Makefile          (env 1)
  vlt/                       simple Verilator C++ TB + sim_main.cpp  (env 2)
  uvm/                       UVM on Verilator (uvm-verilator flow)   (env 3)
  systemc/                   SystemC TB + sc_main.cpp                (env 4)
  cocotb/                    cocotb + PyUVM TB (Icarus/Verilator)    (env 5)
  sva/                       bind-based SystemVerilog assertions
  common/                    shared BFMs, flit logging, wave-dump helpers
  waves/                     per-test GTKWave .gtkw sessions + wave_check.py
formal/                      SymbiYosys .sby + *_fv.sv property modules
lp/                          UPF power intent (bridge.upf) + power-aware TB
metrics/                     schema.sql, collect.py, dashboard.py, dashboard.html, metrics.db
docker/                      Dockerfile helpers, swarm.sh, entrypoint.sh, swarm-task.md
.claude/agents/              swarm agent definitions (dv-env-tester, infra-agent, swarm-manager)
.github/workflows/           ci.yml (regress/coverage/formal), swarm.yml
docs/                        PLAN.md (this), AGENT_HANDOFF.md, verification_plan.md, power_intent.md
railway.toml                 Railway config-as-code (batch job runs `make ci`)
Makefile                     root targets (§8)
Dockerfile                   pinned OSS CAD Suite + cocotb image
```

---

## 5. The five verification environments

All five drive the **same DUT** and reuse the shared BFMs/checkers in
`dv/common/`. Each has its own `Makefile` and a `smoke` target.

| # | Env | Simulator | Bench style | Primary purpose |
|---|---|---|---|---|
| 1 | `dv/iverilog/` | Icarus Verilog | Directed SystemVerilog TB | Fast, dependency-light golden directed tests; first bring-up. |
| 2 | `dv/vlt/` | Verilator (C++) | `sim_main.cpp` harness | Fast regression + the **coverage** vehicle (`--coverage` → `coverage.info`). |
| 3 | `dv/uvm/` | Verilator + Accellera UVM | UVM (agents/seq/scoreboard) | UVM on Verilator >= 5.03x (pinned OSS CAD Suite 5.047; apt 5.020 cannot compile uvm-core). uvm-core cloned at a pinned commit by the Makefile; **keep `VERILATOR_ROOT` unset**. Runs in CI (~2 min, D12). |
| 4 | `dv/systemc/` | Verilator → SystemC | `sc_main.cpp` + verilated SystemC model | Transaction-level/system co-sim; reference model cross-check. |
| 5 | `dv/cocotb/` | cocotb + **PyUVM** | Python UVM (Icarus or Verilator) | Rich constrained-random + **functional coverage** (PyVSC per memory `[[pyvsc-functional-coverage]]`). Watch the cocotb handshake-race + `ICARUS_BIN_DIR=/usr/bin` gotchas in `[[cocotb-apb-slave-timing]]`. |

**Cross-check contract:** all five must agree on a common directed scenario set
(write-a-frame / read-a-frame / random-frames / power-cycle P0→P1→P0 /
rate-change) and a shared scoreboard result. This is the "5 DV envs cross-check"
pattern proven in `axi-on-ucie-to-mem`.

---

## 6. Coverage

Per `DV_STANDARDS.md`:
- **Line/toggle:** Verilator `--coverage` from `dv/vlt/` → `coverage.info`
  (lcov) at repo root, uploaded as a CI artifact. Floor **≥ 80%** on datapath +
  control before a module is "done".
- **Functional:** PyVSC covergroups in `dv/cocotb/` — cover frame sizes,
  tkeep-last patterns, width/rate combinations, power-state transitions, message-
  bus opcodes, back-to-back vs. gapped frames, CDC near-full/near-empty. Export
  `fcov.json` for the dashboard (pattern from `axi-on-ucie-to-mem/dv/cocotb`).
- **Assertion coverage:** every SVA `cover` in `dv/sva/` counted.

---

## 7. Assertions (SVA)

`dv/sva/` bind-based (DUT stays assertion-free), mirroring
`axi-on-ucie-to-mem/dv/sva`. First-cut property set:
- **AXI4-Stream legality** (both eth streams): `tvalid` stable until `tready`;
  no data change mid-beat; `tlast`/`tkeep` well-formed.
- **PIPE handshake:** `pipe_tx_data_valid` only in P0; no Tx during
  powerdown; sync-header/start-block legality; `phy_status` handshake
  completes rate/width/power requests within N cycles.
- **CDC/FIFO safety:** no overflow (write-while-full) or underflow
  (read-while-empty); occupancy ≤ depth.
- **Message bus:** request→ack ordering; no two outstanding power requests.
- Maintain `ASSERTIONS.md` (per the workspace TODO) listing each property, its
  file, and the tool that checks it.

---

## 8. Root Makefile targets (mandatory)

Exactly the `DV_STANDARDS.md` contract, plus this repo's extras:

| Target | Runs |
|---|---|
| `make lint` | Verilator `--lint-only -Wall` (+ Icarus lint) on all `rtl/`. Exit 0. |
| `make sim` | Primary directed sim (env 1 iverilog or env 2 vlt). |
| `make regress` | `lint` + `sim` — the fast CI gate. |
| `make coverage` | Verilator `--coverage` + lcov → `coverage.info`. |
| `make formal` | SymbiYosys PDR prove + cover (formal/*.sby; D13). |
| `make ci` | `regress` + `coverage` + `formal` + all-env smoke. |
| `make <env>` | `iverilog` / `vlt` / `uvm` / `systemc` / `cocotb` run each env. |
| `make waves` / `wave-<test>` | Run a test with dump + open its `dv/waves/*.gtkw`. |
| `make upf` | Power-aware sim (commercial; OSS prints a stub — §9). |
| `make metrics` / `make dashboard` | Collect run data → `metrics.db` → `dashboard.html`. |
| `make stress` | All scenarios on the Verilator env across `STRESS_SEEDS` seeds (gap/backpressure patterns). |
| `make clean` | Remove all build artifacts. |

Python is the glue (collectors, dashboard, wave-check, swarm task rendering) —
keep it in `metrics/` and `dv/waves/`, not scattered shell.

---

## 9. UPF power-aware simulation

Port the `ucie_rdi_to_pcie6_pipe7` UPF flow (`test/upf/bridge.upf`,
`docs/power_intent.md`):
- **Power architecture:** `PD_AON` always-on (ctrl FSM + message-bus master +
  top glue — must stay alive through P1/P2 to sequence link recovery); `PD_DP`
  switchable (the whole Tx/Rx datapath, gated off in P1/P2). `bridge_rf` sits in
  `PD_DP` but is **retained** so programmed config survives a low-power episode.
- **Binding:** UPF applied at a power-aware TB top (`tb_pipe7_upf_power`) that
  instantiates the DUT plus the DV-only `pipe7_pmu` sequencer (the DUT has no
  power ports — controls come from the PMU).
- **OSS reality:** Verilator/Icarus/Yosys do **not** model UPF supply/isolation/
  retention/corruption. `make upf` runs on a commercial power-aware flow
  (VCS-NLP / Questa-PA / Xcelium) and, in the OSS environment, prints a clear
  "authored, not run here" stub and exits 0 (same convention as the sibling).
  Document the intent in `docs/power_intent.md`; the file is review-validated,
  not CI-gated.

---

## 10. Infra: dashboard, CI, Railway, agent swarm

### Metrics / performance & coverage dashboard
Port `axi-on-ucie-to-mem/metrics/`: append-only SQLite (`schema.sql` →
`metrics.db`), `collect.py` reads real artifacts (logs, `coverage.info`,
`fcov.json`, `/usr/bin/time`, yosys stats), `dashboard.py` renders
`dashboard.html`. Every value carries a `kind` (`measured` / `estimated` /
`not_attributable`) — **never fabricate a measured number**; record the gap.
Dashboard sections: throughput/latency (perf), line+functional coverage,
resource (gate/Fmax estimates), and per-(agent×model) if the swarm ran.

### GitHub Actions CI (`.github/workflows/ci.yml`)
Jobs per `DV_STANDARDS.md`, all `ubuntu-latest`, OSS CAD Suite pinned to
`OSS_CAD_SUITE_VERSION`, `cocotb==1.8.1`:
- `regress` — `make regress` (blocks merge).
- `coverage` — `make coverage`, upload `coverage.info` (needs: regress).
- `formal` — `make formal` (needs: regress).
- (optional) `cocotb`, `systemc` env smokes.

### Railway (larger runs) — `railway.toml`
Config-as-code batch job (not a web service): `builder = DOCKERFILE`,
`restartPolicyType = "NEVER"`, no `startCommand` (image ENTRYPOINT runs
`make ci`), optional `cronSchedule` for a nightly full run. Use for long
stress/random regressions that exceed the GitHub runner budget. Port
`axi-on-ucie-to-mem/railway.toml` + `Dockerfile` + `docker/entrypoint.sh`.

### AI agent swarm (execution option)
Port `axi-on-ucie-to-mem/docker/swarm.sh` + `.claude/agents/`:
- Agents: `swarm-manager` (dispatch), one `dv-env-tester` per DV environment,
  `infra-agent` (CI/Docker/Railway), `dv-runner`.
- `docker/swarm-task.md` holds the default task; provider selectable
  (Anthropic default; Kimi K3 alt). `GITHUB_TOKEN` lets the swarm open a PR
  (a human merges). Runs Claude Code **non-bare** so `.claude/agents/` are
  discoverable. Trigger locally (`docker/swarm.sh`) or via `swarm.yml`.

---

## 11. Phased plan & task backlog (agent-resumable)

Each milestone ends green on the stated gate. Work top-to-bottom; the backlog
IDs are what `AGENT_HANDOFF.md` points at.

### M0 — Scaffold (no RTL behavior yet) ✅ done 2026-09-29
- [x] **T0.1** Standalone repo skeleton: root `Makefile` targets (§8), five `dv/`
  env dirs each with a Makefile + `smoke`, placeholder dirs for `metrics/`,
  `docker/`, `.claude/agents/`, `formal/`, `lp/`, `dv/{common,sva,waves}`,
  `.github/workflows/ci.yml`, `.gitignore`. Tool pins referenced from
  `~/proj/dv_env.mk`. (railway.toml + Dockerfile deferred to T7.3.)
- [x] **T0.2** `rtl/eth_dj_pipe7_pkg.sv` with §2.3 params + enums (PAM4/Gen6).
- [x] **T0.3** Interfaces §2 frozen in top stub `eth_dj_pipe7_bridge.sv`
  (ports + reset-value drives), `dv/iverilog/tb_smoke.sv` checks the PAM4/Gen6
  reset defaults. **Gate: `make regress` (lint + smoke) — GREEN.**

### M1 — Datapath bring-up (one direction, Tx: eth→pipe, Gen6 FLIT / PAM4)
- [x] **T1.1** (done; `async_fifo` as tx_cdc, `tx_framer` = byte packer + flit
  assembly, `tx_egress` = 256b->64b flit serialiser, i.e. the gearbox is folded into
  the framer/egress pair; no separate eth_ingress) `eth_ingress` + `tx_cdc` + `tx_gearbox` + `tx_framer` (256B FLIT
  assembly) + `tx_egress`. Reuse a workspace async FIFO. Remove the M0 lint
  waivers as signals get consumed.
- [x] **T1.2** `eth_mac_model` + `pipe_phy_model` (Gen6 FLIT-aware) BFMs in
  `dv/common/`.
- [x] **T1.3** Env 1 (iverilog) directed "send one frame → one FLIT" test
  (`dv/iverilog/tb_tx.sv`: 115 frames, 531 flits). **Gate: `make sim` — GREEN.**

### M2 — Reverse datapath (Rx: pipe→eth) + loopback
- [x] **T2.1** `rx_ingress`/`rx_cdc`/`rx_deframer`/`eth_egress`.
- [x] **T2.2** Loopback scoreboard (frame in == frame out): `dv/iverilog/tb_loop.sv`.
  **Gate: `make regress` — GREEN.**

### M3 — Control plane
- [x] **T3.1** `pipe_msgbus` + `bridge_ctrl_fsm` + `bridge_rf` (+ `tx_ingress_gate`,
  CSR port): P0↔P1↔P2, rate and width change with datapath drain, PAM4 Tx control
  over the message bus; Rx overload drop + frame-abort policy (OPEN_DECISIONS D7–D11).
- [x] **T3.2** Directed power-cycle + rate/width/cfg tests under traffic
  (`dv/iverilog/tb_pm.sv`), Rx overload test (`tb_rxovf.sv`), link-up smoke.
  **Gate: `make regress` incl. power-cycle scenario — GREEN.**

### M4 — Fill out the five environments
- [x] **T4.1** Env 2 (Verilator C++) + coverage vehicle → `coverage.info`
  (line+branch 95.7% with Verilator 5.047, floor 80%).
- [x] **T4.2** Env 5 (cocotb+PyUVM) with PyVSC functional coverage (`fcov.json`, reported, not gated).
- [x] **T4.3** Env 3 (UVM-on-Verilator, CI job with the pinned Verilator 5.047) and Env 4 (SystemC).
- [x] **T4.4** All five agree on the shared scenario set (`dv/common/scenarios.py`,
  `crosscheck.py`; decisions in OPEN_DECISIONS D12).
  **Gate: `make ci` green, coverage ≥ 80%.**

### M5 — SVA + formal
- [x] **T5.1** `dv/sva/` property set §7, bound in vlt + systemc + uvm (Verilator
  `--assert`); cocotb runs on Icarus, which has no concurrent SVA (D13).
- [x] **T5.2** `formal/*.sby` for CDC/credit/message-bus safety; PDR prove + cover
  (`async_fifo`, `ingress_gate`, `ctrl` = ctrl FSM + msgbus + tx_egress).
- [x] **T5.3** `ASSERTIONS.md`. **Gate: `make formal`** — GREEN locally (pinned OSS CAD Suite).

### M6 — Low power (UPF)
- [x] **T6.1** `lp/bridge.upf` + `pipe7_pmu` + `tb_pipe7_upf_power` +
  `docs/power_intent.md`; `make upf` (commercial run / OSS stub §9).
  UPF **authored, not run** (no PA simulator). `make upf-tb` = functional Icarus run
  of the TB (PMU sequencing + timing assumption), GREEN. rf moved to PD_AON (D14).

### M7 — Infra polish
- [x] **T7.1** GTKWave `.gtkw` per test + `wave_check.py` (7 sessions, checked vs fresh
  VCD dumps; loaded headless in GTKWave locally).
- [x] **T7.2** Metrics collectors + `dashboard.html` populated from real runs
  (measured / estimated / not_attributable per value).
- [x] **T7.3** Railway job defined (image built + run locally, green; not deployed to
  Railway); swarm task file + agents finalized (swarm itself not run: needs an API key).
  **Gate: `make dashboard`, CI green, Railway job defined.**

### M8 — Close-out
- [x] Self-review of the M4–M7 diffs; stale docs fixed (README, PLAN §5/§8/§12,
  handoff gotchas); `make stress` implemented (was a stub).
- [ ] ~~Update `~/proj/README.md` + `DV_STANDARDS.md` status table~~ — not possible:
  `~/proj` is not in this container (D5). PRs are opened as **drafts** and merged by
  the owner (session rule, D6); branch deletion is left to the owner.

**Success criteria (§1) status at close-out**

| # | Criterion | Status |
|---|---|---|
| 1 | `make regress` green locally + CI | Met |
| 2 | `make ci` green; line coverage ≥ 80% | Met locally (pinned suite); CI runs the same jobs split up. Line+branch 95.7% |
| 3 | Five envs build + pass smoke | Met (all five in CI; crosscheck job) |
| 4 | SVA bound + passing in Verilator and cocotb flows; formal proves flow-control safety | SVA in vlt/systemc/uvm, **not cocotb** (Icarus, D13); formal proofs pass |
| 5 | UPF documented + runnable (commercial; OSS stub) | Authored + documented; **never run** (no PA tool); `upf-tb` functional only |
| 6 | Dashboard renders; GTKWave per test; Railway job defined | Met; image built + run locally; **not deployed** to Railway |

---

## 12. Open decisions (resolve early, record here)
- **[OPEN]** `ETH_DATA_W` (256b default) and `PIPE_DATA_W`/`PIPE_NLANES`
  (64b×1 default) — pick to match a realistic 802.3dj-rate ÷ PIPE-rate ratio,
  which sizes the gearbox and CDC depth.
- **[OPEN]** Ethernet side as AXI4-Stream packets (recommended, matches
  `eth_axi4s_to_pcie_pipe_bypass`) vs. a raw 64/66b/MII-like stream.
- **RESOLVED (2026-09-29):** PIPE generation = **Gen6 (64 GT/s, PAM4, FLIT
  mode)** — pairs with the 802.3dj PAM4 side ("start with PAM4"). Keep the
  datapath rate-parametric so earlier NRZ gens remain a parameter fallback.
- **RESOLVED (M4, D12):** UVM-on-Verilator runs in CI (~2 min with the pinned
  Verilator 5.047); documented in `dv/uvm/README.md`.

## 13. Conventions
- Match surrounding workspace style; keep `rtl/` assertion-free (SVA via bind).
- PRs: ready for review, not drafts; finish what you open (review → merge →
  delete branch) unless it's an RTL-behavior change needing human sign-off —
  per `~/proj/CLAUDE.md`.
- Never fabricate a measured metric; use the `kind` field.
- Commit attribution and PR footer per the session's active attribution rule.
