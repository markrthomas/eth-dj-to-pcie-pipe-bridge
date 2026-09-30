# PAM4 / Gen6 notes — design baseline

This bridge is **PAM4-first**: both ends run PAM4 signaling, so the digital
datapath and framing are designed around Gen6/802.3dj semantics from day one
rather than starting NRZ and retrofitting. This file records what "PAM4" means
for the *digital* design (the bridge never touches analog levels) and the
decisions that follow.

## What PAM4 changes for a digital bridge

PAM4 = 4 amplitude levels = **2 bits per symbol** (vs. NRZ's 1 bit/symbol). At
the same symbol (baud) rate PAM4 doubles the bit rate — how PCIe Gen6 reaches
64 GT/s and how 802.3dj reaches 200 Gb/s/lane. The bridge is a digital adapter
sitting above the PHY, so it sees **parallel data**, not levels; PAM4 shows up
here as:

1. **Higher parallel throughput** at a given `pclk` → wider datapath / gearbox
   ratios. Size `PIPE_DATA_W`, `ETH_DATA_W`, and the CDC/elastic FIFO depth
   against the PAM4 bit-rate ratio (still `[OPEN]` in PLAN §2.3).
2. **New PHY control handshakes** carried on the PIPE message bus (8-bit byte bus, 12-bit register addresses — OPEN_DECISIONS D8):
   `PhyTxControl`, **Tx precoding / Gray-code enable**, **PAM4 Tx presets**
   (equalization), and **RxMargin** (eye-margining). The bridge control FSM must
   drive/observe these during bring-up and rate/width changes. (The sibling
   `ucie_rdi_to_pcie6_pipe7` already models `PAM4RestrictedLevels` / PhyTxControl
   in its UPF/PMU flow — reuse that.)
3. **Precoding**: PAM4 links often enable Tx precoding to limit DFE error
   propagation. It's a PHY function; the bridge just enables/sequences it via the
   message bus — no precoder RTL in the bridge.

## PCIe Gen6 FLIT mode (the PIPE side)

Gen6 mandates **FLIT mode**, which changes framing vs. Gen1–5:

- **Fixed 256-byte flits**, regardless of link/data-rate state: **242 B** TLP
  payload + **6 B** DLP (sequence/ack) + **8 B** FEC + CRC.
- **1b/1b encoding — no 128b/130b sync header.** So the bridge's framer/deframer
  align to **flit boundaries** (`pipe_tx_start_block` / `pipe_rx_start_block`
  mark a flit start), not to 130-bit blocks. Earlier-gen block framing is only a
  parametric fallback.
- **Lightweight FEC + CRC** per flit. **First-cut scope:** the bridge treats the
  FEC/CRC bytes as **passthrough** (the PHY/controller peers own generate/check);
  revisit if the bridge must terminate them.

## 802.3dj (the Ethernet side)

IEEE 802.3dj targets **200 Gb/s per lane** (PAM4) and 200G/400G/800G/1.6T MAC
rates, with RS-FEC in the PCS. We model this side as an **AXI4-Stream packet
interface** off the MAC/PCS (payload + tkeep/tlast/tuser), keeping the bridge
PHY-agnostic — the PAM4 electrical/FEC layer is out of scope (see PLAN §1).

## Consequences captured in the RTL skeleton

- `rtl/eth_dj_pipe7_pkg.sv`: `PAM4_BITS_PER_SYM=2`, `FLIT_BYTES=256`,
  `pipe_rate_e` with `RATE_GEN6` as the baseline, `MSGBUS_*` for the PAM4/PM
  handshakes.
- `rtl/eth_dj_pipe7_bridge.sv` resets with `pipe_rate = RATE_GEN6` and `PWR_P1`;
  the M3 control FSM brings the link to P0 and sends the PAM4 Tx control
  (precoding/preset, `PAM4CFG`) over the message bus whenever the link is at Gen6
  (docs/OPEN_DECISIONS.md D8).
- `docs/PLAN.md` §2–§3: framer/deframer are FLIT-based; message bus carries the
  PAM4 controls.

## Open PAM4-related decisions
- Exact `PIPE_DATA_W` × `pclk` operating point for 64 GT/s (sets gearbox ratio).
- Whether the bridge ever **terminates** Gen6 FEC/CRC or always passes it through.
- Lane count roadmap (x1 first cut → x2/x4/x8 parametric).
