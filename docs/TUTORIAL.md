# Tutorial: the buses, the design, the testbenches

This walks a newcomer from "what are these interfaces?" to "I can add a test". It is a tour, not a
spec: where the repo makes a simplification the text says so, and the decision log
([`OPEN_DECISIONS.md`](OPEN_DECISIONS.md), "D<n>") has the reasoning. Diagrams are in the
[README](../README.md#block-diagrams).

Contents: [1. Bus standards](#1-bus-standards) · [2. The design](#2-the-design) ·
[3. The testbenches](#3-the-testbenches) · [4. Hands-on path](#4-hands-on-path)

---

## 1. Bus standards

The bridge has three interfaces: an Ethernet packet stream, the PIPE data/pin interface, and the
PIPE message bus. A fourth, a small CSR port, is the bridge's own.

### 1.1 AXI4-Stream (the Ethernet side)

IEEE 802.3dj defines 200 Gb/s-per-lane Ethernet PAM4 signalling. The bridge does **not** implement a
MAC or PCS: it sits behind one and sees frames as an AXI4-Stream packet interface
(`eth_*` into the bridge, `eth_rx_*` out of it; 256-bit data, `ETH_DATA_W` in
`rtl/eth_dj_pipe7_pkg.sv`).

| Signal | Meaning |
|---|---|
| `tvalid` / `tready` | Handshake: a beat transfers on a clock edge where both are 1. The source must keep `tvalid` and the data stable until `tready`. |
| `tdata[255:0]` | 32 payload bytes per beat, byte 0 in bits [7:0]. |
| `tkeep[31:0]` | Which bytes of the beat are valid. Here: contiguous and low-aligned, and only the **last** beat of a frame may be partial. |
| `tlast` | Last beat of the frame. |
| `tuser[7:0]` | Sideband. Ingress `tuser` is not carried (D4). On egress, `tuser[0]` = 1 on the `tlast` beat marks an **aborted frame** (D9). |

Worked example: a 70-byte frame is three beats: 32 bytes (`tkeep` = all ones), 32 bytes, 6 bytes
(`tkeep` = `0x3F`, `tlast` = 1). Back-pressure is `tready` low; the bridge's `tx_ingress_gate`
also holds `tready` low to stop new frames while it drains.

### 1.2 PCIe Gen6: PAM4 and flits

PCIe 6.0 runs at 64 GT/s using **PAM4** (4 amplitude levels, 2 bits per symbol, so twice the bit rate
of NRZ at the same baud rate) and **FLIT mode**: the link carries fixed 256-byte flits, with
no 128b/130b block sync headers as in Gen3 to Gen5. The bridge never sees analog levels; PAM4 only
shows up as higher parallel throughput and as PHY configuration over the message bus
([`pam4_notes.md`](pam4_notes.md)).

The repo's flit layout (D2) tunnels Ethernet bytes opaquely in the flit; it is **a bridge format,
not a PCIe TLP encoding**, and the 242/6/8 byte split is the repo's simplification: check it against
the PCIe 6.0 base spec before relying on it for anything real.

### 1.3 PIPE 7.1 (MAC-facing)

PIPE (PHY Interface for PCI Express) is the parallel interface between a PCIe MAC and a PHY. The
bridge plays the **MAC** role. Groups used here:

| Group | Pins | Direction (bridge view) | Notes |
|---|---|---|---|
| Clock/reset | `pclk`, `pipe_rst_n` | in | `pclk` is PHY-sourced. |
| Tx data | `pipe_tx_data`, `pipe_tx_data_valid`, `pipe_tx_start_block` | out | 64 bits per lane per `pclk`; `start_block` marks the first beat of a flit. |
| Rx data | `pipe_rx_data`, `pipe_rx_data_valid`, `pipe_rx_start_block` | in | **No back-pressure** on Rx (D9). |
| Control | `pipe_rate[2:0]`, `pipe_width[1:0]`, `pipe_powerdown[1:0]` | out | `rate` 5 = Gen6 (64 GT/s PAM4); `powerdown` 0 = P0, 2 = P1, 3 = P2 (P0s, 1, is unsupported here). |
| Status | `pipe_phy_status`, `pipe_rx_valid`, `pipe_rx_elec_idle` | in | |
| Message bus | `pipe_m2p_msgbus[7:0]`, `pipe_p2m_msgbus[7:0]` | out / in | Section 1.4. |

Timing at x1: a 256-byte flit is `256*8/64` = 32 `pclk` beats. At x4 (`-DPIPE_NLANES_OVERRIDE=4`,
256 bits per beat) it is 8 beats.

**PhyStatus handshake.** To change rate, width or powerdown, the MAC drives the new value on
the pin and waits for the PHY to pulse `pipe_phy_status`. The bridge waits at most `PHY_TIMEOUT`
(1024) cycles; on timeout it sets a sticky error bit and carries on (D10).

**Power states.** P0 is active; P1 and P2 are low power (P2 the lowest). The bridge only
transmits in P0 and drains its datapath before leaving it.

### 1.4 The PIPE message bus

PIPE 7.x moves most side-band functions onto two 8-bit byte buses, `M2P` (MAC to PHY) and `P2M`
(PHY to MAC), clocked by `pclk`. Idle is `8'h00`; any non-idle byte starts a transaction whose
length its command fixes. Registers have 12-bit addresses.

| Command | Code | Cycles | Bytes |
|---|---|---|---|
| NOP | 0 | 1 | `{0, x}` |
| write_uncommitted | 1 | 3 | `{1, addr[11:8]}`, `addr[7:0]`, `data` |
| write_committed | 2 | 3 | `{2, addr[11:8]}`, `addr[7:0]`, `data` |
| read | 3 | 2 | `{3, addr[11:8]}`, `addr[7:0]` |
| read_completion | 4 | 2 | `{4, x}`, `data` |
| write_ack | 5 | 1 | `{5, x}` |

Worked example, the PAM4 setup the bridge sends at link-up (Gen6): write the preset index `6'h21`
to register `12'h405` (PHY Tx Control5). On M2P that is three bytes, `0x24, 0x05, 0x21`
(`{2, 4'h4}`, `8'h05`, data), then `0x00` idle; the PHY answers on P2M with one `{5, x}` byte.
Only the **first** byte of a transaction is a command; the following bytes are address or data
even if they look like commands (`pipe_msgbus.sv` frames P2M by length for this reason).

Both directions are used: the bridge **masters** its own writes (`pipe_msgbus`), and it is a
**target** for the PHY's reads and writes to the MAC register file (`msgbus_mac_tgt`, PIPE 7.1 section 7.2).
The two share the one M2P bus, so a response is never inserted inside the master's 3-byte frame.

### 1.5 The CSR port

`csr_valid`, `csr_write`, `csr_addr[7:0]`, `csr_wdata`, `csr_rdata`: an always-ready port in the
`pclk` domain (writes on `csr_valid && csr_write`; read data is combinational on `csr_addr`).

| Addr | Name | Access | Content |
|---|---|---|---|
| `0x00` | CTRL | RW | `[1:0]` pwr_req, `[4:2]` rate_req, `[6:5]` width_req |
| `0x04` | PAM4CFG | RW | `[5:0]` Tx preset index; a write re-sends it to the PHY |
| `0x08` | STATUS | RO | powerdown, rate, width, FSM state, busy, link active, elec idle, rx valid |
| `0x0C` | ERR | W1C | `[0]` PhyStatus timeout, `[1]` msgbus timeout, `[2]` P0s requested |
| `0x10` | RXCNT0 | RO | dropped flits, lock errors |
| `0x14` | RXCNT1 | RO | bad/orphan flits, aborted frames |
| `0x18` | PMCNT | RO | completed control operations |

Writing CTRL is how a test or a CPU asks for P1, a rate change, and so on (RTL is
`bridge_rf.sv`; the authority for fields is `bridge_rf.sv` and D7).

---

## 2. The design

### 2.1 A frame's journey (Tx)

1. **`tx_ingress_gate`** (`eth_clk`): passes beats while `tready`; when the control FSM asks to
   drain it closes at the next **frame boundary**, so a started frame always finishes.
2. **`tx_cdc`** (`async_fifo`, 32 entries): crosses `eth_clk` to `pclk`. Gray-coded pointers; the FIFO
   word is `{tlast, tkeep, tdata}`.
3. **`tx_framer`** (`pclk`): packs up to **240 payload bytes** into one flit buffer.
4. **`tx_egress`**: serialises the flit LSB byte first, `PIPE_BUS_W` bits per `pclk`, asserting
   `pipe_tx_start_block` on the first beat. Only starts a flit in P0; once started it completes.

**Flit format** (D2), 256 bytes:

| Bytes | Content |
|---|---|
| 0 | `{5'b0, eof, sof, valid}` (valid = bit 0, sof = bit 1, eof = bit 2) |
| 1 | payload byte count, 0 to 240 |
| 2 to 241 | frame bytes, zero padded |
| 242 to 247 | DLP placeholder (carries `seq`/`cl` when flow control is on) |
| 248 to 255 | FEC/CRC placeholder (zero) |

Example: a 300-byte frame becomes two flits: flit 0 header `0x03` (valid + sof), count 240;
flit 1 header `0x05` (valid + eof), count 60. A frame of 240 bytes or fewer is one flit with header
`0x07`.

### 2.2 A frame's journey (Rx)

1. **`rx_ingress`**: ignores beats until `pipe_rx_start_block` (**flit lock**); a start_block
   in mid-flit restarts capture. One slot: PIPE Rx cannot be back-pressured, so a flit that
   completes while the previous one is still held is **dropped and counted**, and the next flit
   carries a *gap* marker.
2. **`rx_deframer`**: unpacks payload bytes into 256-bit Ethernet beats. If a flit follows a gap,
   has `sof` while a frame is open, or has a bad header, the open frame is **aborted**: it is closed with
   `tlast` and `err = 1` instead of splicing old bytes onto new ones (D9). Orphan
   continuation flits are dropped.
3. **`rx_cdc`** and **`eth_egress`**: cross to `eth_clk` and present `eth_rx_*`. The sink sees either
   a byte-exact frame or a frame flagged with `tuser[0]`, never silent corruption
   (`tb_rxovf` checks exactly this).

### 2.3 Control plane

`bridge_ctrl_fsm` converges the PIPE pins on what `bridge_rf` requests, **one operation at a time,
always after a drain** (state diagram in the README):

- **Link-up after reset**: RESET (powerdown P1, wait PhyStatus low) → LOWPWR → PWR_CHG to P0 → DRAIN →
  CFG (the PAM4 message-bus write of section 1.4) → DRAIN → ACTIVE. That is the 2 operations
  every scenario's `PMCNT` counts (`LINKUP_OPS`).
- **Drain** = ingress gate stopped, Tx pipeline empty, and (with the datapath reset on) the Rx path
  empty. Priority when several changes are pending: rate, width, PAM4 write, power down.
- **Power-down**: P0 to P1 to P2 and back (P2 returns via P1). A request cancelled before the drain
  completes causes no powerdown change.

### 2.4 Clock domains and CDC

Two clocks, `eth_clk` and `pclk`, asynchronous to each other. Data crosses only through the two
`async_fifo` instances. Single-bit handshakes cross with synchronisers (for example the gate's
`stopped` flag goes through 3 flops into `pclk`). `formal/` proves FIFO and gate properties and
`dv/sva/async_fifo_sva.sv` checks Gray-pointer behaviour in simulation.

### 2.5 Optional and compile-time features

| Feature | Switch | Effect |
|---|---|---|
| x4 lanes | `-DPIPE_NLANES_OVERRIDE=4` | datapath is lane-parametric; `make lanes4` runs the suite |
| Link flow control (D16) | `-DFLOW_CTRL_OVERRIDE` | credits + sequence numbers in the DLP bytes; both ends must agree; needs `fc_ctl` |
| Datapath-local reset (D18) | default on; `-DDP_RESET_DISABLE` off | PD_DP held in reset in LOWPWR so it needs no retention; clears the Rx counters per P1/P2 episode; flow-control builds turn it off |

### 2.6 Power intent

`lp/bridge.upf` describes an always-on domain and a switchable datapath domain `PD_DP`;
`lp/pipe7_pmu.sv` is a DV-only sequencer (isolate, save, power off; power on, restore, de-isolate).
There is no open-source power-aware simulator, so the UPF is *authored, not run*; the
power-state emulation in `lp/cocotb` ([`power_state_emulation.md`](power_state_emulation.md))
checks the retention requirement by corrupting state during low power.

---

## 3. The testbenches

### 3.1 Shared building blocks (`dv/common/`)

| Block | Role |
|---|---|
| `eth_mac_model.sv` | AXI4-S source: `send_frame(id, len)`, random gaps via `gap_pct` |
| `eth_sink_model.sv` | AXI4-S sink: random `tready` via `ready_pct`, tkeep legality, reassembles frames |
| `pipe_phy_model.sv` | PIPE Tx monitor: decodes flits, checks the format, reassembles frames |
| `pipe_phy_ctrl_model.sv` | PhyStatus responder, message-bus target, "no Tx outside P0" check |
| `eth_dj_pat.svh` | `pat(id, k)` = `(id*37 + k*13 + (k>>8) + 5) & 0xFF`: frame bytes are a pure function of frame id and offset, so every scoreboard (SV, C++, Python) needs no stored data |
| `scenarios.py` | the **golden model**; `scenarios.svh` and `cpp/bridge_bfm.h` mirror it |

### 3.2 The loopback harness and the scenario contract

Every environment instantiates the bridge with **PIPE Tx wired to PIPE Rx**, so a frame goes
Ethernet in, flits out, the same flits back in, Ethernet out. The scoreboard then needs no
reference datapath: the received frames must equal the sent ones.

Five scenarios are shared (`scenarios.py`): `single`, `corners` (lengths around flit and beat
boundaries), `random`, `pm_cycle` (P0 to P1 to P0 mid-traffic) and `rate_change` (Gen6 to Gen5
to Gen6 mid-traffic). Each env resets the DUT, runs the scenario and writes `results.json`: frames,
bytes, flits, **CRC-32 of all received bytes**, `PMCNT`, error count. `make crosscheck`
compares each env with `expected()` in the golden model, so five independently written benches
have to agree on the numbers.

### 3.3 The five environments

| Env | Path | Style | Why it exists |
|---|---|---|---|
| Icarus | `dv/iverilog/` | directed SV, `tb_*.sv` | fast, few dependencies; where the directed corner tests live |
| Verilator C++ | `dv/vlt/` | `sim_main.cpp` + `bridge_bfm.h` | speed, **line/branch coverage** (`make coverage`, floor 80%), SVA |
| UVM | `dv/uvm/` | UVM on Verilator | agents, sequences, scoreboard; needs the pinned OSS CAD Suite |
| SystemC | `dv/systemc/` | verilated SystemC | transaction-level co-simulation |
| cocotb | `dv/cocotb/` | cocotb + PyUVM, `fcov.py` | constrained random and functional coverage |

Icarus-only directed tests: `tb_smoke` (reset to P0/Gen6, CSRs), `tb_tx` (Tx flit format),
`tb_loop`, `tb_pm`, `tb_rxovf`, `tb_msgbus`, `tb_msgbus_mac`, `tb_link` (two bridges
cross-connected, with flow control, a flit killer on the wire and a stalled sink).
Icarus-safe SV only: no `break`, no array literals (D12).

### 3.4 Checkers beyond the scoreboard

- **SVA** (`dv/sva/`, bound in, DUT stays assertion-free): AXI-S legality, PIPE Tx legality, pin
  changes only in their state, PhyStatus/message-bus ordering, FIFO guards. Evaluated by Verilator
  (`vlt`, `systemc`, `uvm`); Icarus and cocotb cannot evaluate concurrent assertions.
- **Formal** (`formal/`, SymbiYosys PDR): `async_fifo`, `ctrl`, `ingress_gate`, `fc`.
- **Power**: `make upf-tb` (PMU sequencing under Icarus, no power semantics), `make pd-emu`
  (retention emulation) and `make pd-emu-ret` (the same on the no-reset build, as the negative control).

### 3.5 Reading results

| You want | Run | Look at |
|---|---|---|
| fast gate | `make regress` | the `*PASS` lines |
| one directed test | `make -C dv/iverilog loop` (or `pm`, `rxovf`, ...) | `sim_build/<test>.log` |
| waveform | `make wave-loop` | `dv/waves/loop.gtkw` in GTKWave |
| coverage | `make coverage` | `coverage.info`, per-module table |
| agreement | `make envs crosscheck` | `CROSSCHECK PASS: 5 env(s)` |
| x4 | `make lanes4` | the same suite at x4 |

---

## 4. Hands-on path

1. **Watch a frame go through.** `make -C dv/iverilog smoke` then `make wave-loop`; in GTKWave follow
   `eth_tvalid`, `u_tx_cdc`, `pipe_tx_start_block`, then the same flit on `pipe_rx_*` and
   `eth_rx_tvalid`.
2. **Decode a flit by hand.** In `tb_tx` print the first two bytes of a flit and compare with
   the table in section 2.1 (`0x03`, count 240 for the first flit of a long frame).
3. **Read the message bus.** `tb_msgbus` (T1) checks the write_committed framing on M2P
   (`{WR_C, addr[11:8]}`, `addr[7:0]`, data, then idle); `tb_smoke` checks that link-up sends exactly one
   write, to `MB_ADDR_TX_PRESET` with `PAM4CFG_RST` (bytes `0x24 0x05 0x21`). Dump a wave of either
   (`make wave-smoke`) and find the three bytes on `pipe_m2p_msgbus`, then the PHY's `write_ack`.
4. **Break something and see which bench notices.** Change `FLIT_PAYLOAD_B` consumers or flip one
   bit in `tx_framer`, run `make regress`; then repeat with an Rx-side drop to see why
   `tb_rxovf` accepts missing frames but never corrupt ones.
5. **Add a directed test.** Copy `tb_pm.sv`, which already `include`s `loop_harness.svh`
   (bridge + MAC + PHY models + CSR tasks), add a target to `dv/iverilog/Makefile`, and add it to
   the root `regress` list.
6. **Add a shared scenario.** Add it to `scenarios.py` and `scenarios.svh`, then to each env's
   sequencer; `make crosscheck` will tell you which env disagrees.

Further reading: [`PLAN.md`](PLAN.md) (scope, backlog), [`OPEN_DECISIONS.md`](OPEN_DECISIONS.md)
(why each choice), [`AGENT_HANDOFF.md`](AGENT_HANDOFF.md) (current state),
[`pam4_notes.md`](pam4_notes.md), [`power_intent.md`](power_intent.md).
