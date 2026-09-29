"""PyUVM environment for eth_dj_pipe7_bridge (DV env 5).

Timing convention (handshake-race safe, docs/AGENT_HANDOFF.md): every model
drives its DUT inputs exactly once right after a RisingEdge and samples DUT
outputs at the following FallingEdge (the values the DUT flops will see at the
next rising edge).  Components:

  MacDriver      uvm_driver     : EthFrameItem -> eth_t* AXI4-Stream beats
  EthRxMonitor   uvm_component  : eth_rx_* reassembly, tready throttling -> ap
  FlitMonitor    uvm_component  : PIPE Tx start_block count + flit legality
  PhyCtrlModel   uvm_component  : PhyStatus + message-bus target + Tx checker
  CsrAgent       uvm_component  : CSR read/write coroutines (pclk)
  Scoreboard     uvm_subscriber : in-order byte check, CRC-32, per-scenario result
"""
import os
import random
import sys
import zlib

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge
from pyuvm import (ConfigDB, uvm_analysis_port, uvm_component, uvm_driver, uvm_env,
                   uvm_sequence_item, uvm_sequencer, uvm_subscriber)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import scenarios  # noqa: E402

ETH_BYTES = 32
PWR_P0, PWR_P0S, PWR_P1, PWR_P2 = 0, 1, 2, 3
RATE_GEN5, RATE_GEN6 = 4, 5
MB_NOP, MB_WR_C, MB_WR_ACK = 0, 2, 5
CSR_CTRL, CSR_PAM4CFG, CSR_STATUS, CSR_ERR, CSR_PMCNT = 0x00, 0x04, 0x08, 0x0C, 0x18


def ival(sig):
    """Integer value of a handle; X/Z resolve to 0 (reset-time only)."""
    try:
        return int(sig.value)
    except ValueError:
        return 0


class EthFrameItem(uvm_sequence_item):
    def __init__(self, name="frame", fid=0, length=64):
        super().__init__(name)
        self.fid = fid
        self.length = length

    def payload(self):
        return bytes(scenarios.pat(self.fid, k) for k in range(self.length))


class RxFrame:
    def __init__(self, data, err):
        self.data = data
        self.err = err


# ----------------------------------------------------------------------------- MAC
class MacDriver(uvm_driver):
    def build_phase(self):
        self.dut = cocotb.top
        self.gap_pct = 10
        self.rng = random.Random(1)
        self.beats = 0
        self.gapped_beats = 0

    async def run_phase(self):
        d = self.dut
        d.eth_tvalid.value = 0
        d.eth_tlast.value = 0
        d.eth_tkeep.value = 0
        d.eth_tdata.value = 0
        while True:
            item = await self.seq_item_port.get_next_item()
            data = item.payload()
            off = 0
            while off < len(data):
                await RisingEdge(d.eth_clk)
                if self.gap_pct and self.rng.randrange(100) < self.gap_pct:
                    d.eth_tvalid.value = 0
                    self.gapped_beats += 1
                    continue
                chunk = data[off:off + ETH_BYTES]
                d.eth_tdata.value = int.from_bytes(chunk, "little")
                d.eth_tkeep.value = (1 << len(chunk)) - 1
                d.eth_tlast.value = int(off + len(chunk) == len(data))
                d.eth_tvalid.value = 1
                while True:
                    await FallingEdge(d.eth_clk)
                    if ival(d.eth_tready):
                        break
                    await RisingEdge(d.eth_clk)
                self.beats += 1
                off += len(chunk)
            await RisingEdge(d.eth_clk)
            d.eth_tvalid.value = 0
            d.eth_tlast.value = 0
            self.seq_item_port.item_done()
            # the RisingEdge above already consumed the post-frame cycle


# ------------------------------------------------------------------------- Eth Rx
class EthRxMonitor(uvm_component):
    def build_phase(self):
        self.dut = cocotb.top
        self.ap = uvm_analysis_port("ap", self)
        self.ready_pct = 90
        self.rng = random.Random(2)
        self.errors = 0

    async def run_phase(self):
        d = self.dut
        d.eth_rx_tready.value = 0
        buf = bytearray()
        while True:
            await RisingEdge(d.eth_clk)
            ready = int(ival(d.eth_rst_n) and self.rng.randrange(100) < self.ready_pct)
            d.eth_rx_tready.value = ready
            await FallingEdge(d.eth_clk)
            if not (ready and ival(d.eth_rx_tvalid)):
                continue
            keep = ival(d.eth_rx_tkeep)
            last = ival(d.eth_rx_tlast)
            err = ival(d.eth_rx_tuser) & 1
            nb = bin(keep).count("1")
            if nb == 0 or keep != (1 << nb) - 1 or (not last and nb != ETH_BYTES) or (err and not last):
                self.errors += 1
                self.logger.error(f"illegal tkeep {keep:08x} last={last} err={err}")
            buf += ival(d.eth_rx_tdata).to_bytes(ETH_BYTES, "little")[:nb]
            if last:
                self.ap.write(RxFrame(bytes(buf), bool(err)))
                buf = bytearray()


# ----------------------------------------------------------------------- PIPE Tx
class FlitMonitor(uvm_component):
    def build_phase(self):
        self.dut = cocotb.top
        self.flits = 0
        self.errors = 0
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        d = self.dut
        beat = 0
        while True:
            await FallingEdge(d.pclk)
            if not ival(d.pipe_rst_n):
                beat = 0
                continue
            v, sb = ival(d.pipe_tx_data_valid), ival(d.pipe_tx_start_block)
            if v:
                if sb != (beat == 0):
                    self.errors += 1
                    self.logger.error("start_block not on flit beat 0")
                if beat == 0:
                    self.flits += 1
                beat = (beat + 1) % 32
            elif beat:
                self.errors += 1
                self.logger.error("data_valid dropped mid-flit")
                beat = 0


# --------------------------------------------------------------- PHY control model
class PhyCtrlModel(uvm_component):
    def build_phase(self):
        self.dut = cocotb.top
        self.ap = uvm_analysis_port("ap", self)       # (kind, value) control events
        self.errors = 0
        self.mute_status = False
        self.mb_writes = 0
        self.mb_last = (0, 0)
        self.lat = 8

    async def run_phase(self):
        d = self.dut
        d.pipe_phy_status.value = 1
        d.pipe_p2m_cmd.value = MB_NOP
        d.pipe_p2m_data.value = 0
        rst_cnt = st_cnt = ack_cnt = 0
        prev = None
        mb_addr_ph = False
        mb_addr = 0
        while True:
            await FallingEdge(d.pclk)
            rst = not ival(d.pipe_rst_n)
            pins = (ival(d.pipe_powerdown), ival(d.pipe_rate), ival(d.pipe_width))
            txv = ival(d.pipe_tx_data_valid)
            m2p_cmd, m2p_data = ival(d.pipe_m2p_cmd), ival(d.pipe_m2p_data)
            await RisingEdge(d.pclk)
            if rst:
                d.pipe_phy_status.value = 1
                d.pipe_p2m_cmd.value = MB_NOP
                rst_cnt = st_cnt = ack_cnt = 0
                prev = pins
                mb_addr_ph = False
                continue
            change = pins != prev
            if txv and (pins[0] != PWR_P0 or st_cnt or change):
                self.errors += 1
                self.logger.error(f"Tx data_valid outside P0 / during a change pins={pins}")
            status = 0
            if rst_cnt < 16:
                rst_cnt += 1
                status = 1
            elif change:
                for k, (a, b) in enumerate(zip(prev, pins)):
                    if a != b:
                        self.ap.write((("pd", "rate", "width")[k], a, b))
                st_cnt = self.lat
            elif st_cnt == 1:
                st_cnt = 0
                status = 0 if self.mute_status else 1
            elif st_cnt > 1:
                st_cnt -= 1
            prev = pins
            d.pipe_phy_status.value = status

            p2m_cmd, p2m_data = MB_NOP, 0
            if mb_addr_ph:
                self.mb_writes += 1
                self.mb_last = (mb_addr, m2p_data)
                self.ap.write(("mb", MB_WR_C, m2p_data))
                mb_addr_ph = False
                ack_cnt = self.lat
            elif m2p_cmd == MB_WR_C:
                mb_addr_ph, mb_addr = True, m2p_data
            elif m2p_cmd != MB_NOP:
                self.errors += 1
            if ack_cnt == 1:
                ack_cnt = 0
                p2m_cmd, p2m_data = MB_WR_ACK, mb_addr
                self.ap.write(("mb", MB_WR_ACK, mb_addr))
            elif ack_cnt > 1:
                ack_cnt -= 1
            d.pipe_p2m_cmd.value = p2m_cmd
            d.pipe_p2m_data.value = p2m_data


# ---------------------------------------------------------------------------- CSR
class CsrAgent(uvm_component):
    def build_phase(self):
        self.dut = cocotb.top
        self.ap = uvm_analysis_port("ap", self)

    def start_of_simulation_phase(self):
        d = self.dut
        d.csr_valid.value = 0
        d.csr_write.value = 0
        d.csr_addr.value = 0
        d.csr_wdata.value = 0

    async def write(self, addr, data):
        d = self.dut
        await RisingEdge(d.pclk)
        d.csr_valid.value, d.csr_write.value = 1, 1
        d.csr_addr.value, d.csr_wdata.value = addr, data
        await RisingEdge(d.pclk)
        d.csr_valid.value, d.csr_write.value = 0, 0
        self.ap.write(("csr_wr", addr, data))

    async def read(self, addr):
        d = self.dut
        await RisingEdge(d.pclk)
        d.csr_addr.value = addr
        await FallingEdge(d.pclk)
        return ival(d.csr_rdata)

    async def wait_status(self, pd, rate, width, timeout=20000):
        for _ in range(timeout):
            s = await self.read(CSR_STATUS)
            if (s & 3) == pd and ((s >> 2) & 7) == rate and ((s >> 5) & 3) == width and not (s >> 10) & 1:
                return True
        return False

    async def set_state(self, pd, rate, width=0):
        await self.write(CSR_CTRL, (width << 5) | (rate << 2) | pd)
        return await self.wait_status(pd, rate, width)


# ------------------------------------------------------------------ scoreboard
class Scoreboard(uvm_subscriber):
    def build_phase(self):
        self.reset_scenario("none", [])

    def reset_scenario(self, name, lens, lenient=False):
        self.name = name
        self.lens = lens
        self.lenient = lenient          # rxovf: aborted or exact-match-in-order
        self.frames = 0
        self.nbytes = 0
        self.crc = 0
        self.errors = 0
        self.err_frames = 0
        self.next_id = 0

    def write(self, fr):
        if self.lenient:
            if fr.err:
                self.err_frames += 1
            else:
                match = None
                for k in range(self.next_id, len(self.lens)):
                    if len(fr.data) == self.lens[k] and fr.data == bytes(
                            scenarios.pat(k, i) for i in range(self.lens[k])):
                        match = k
                        break
                if match is None:
                    self.errors += 1
                    self.logger.error(f"{self.name}: unflagged frame matches no sent frame")
                else:
                    self.next_id = match + 1
        else:
            fid = self.frames
            exp = bytes(scenarios.pat(fid, i) for i in range(self.lens[fid])) if fid < len(self.lens) else None
            if fr.err or fr.data != exp:
                self.errors += 1
                self.logger.error(f"{self.name}: frame {fid} mismatch (len {len(fr.data)}, err {fr.err})")
        self.crc = zlib.crc32(fr.data, self.crc)
        self.nbytes += len(fr.data)
        self.frames += 1


class BridgeEnv(uvm_env):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)
        self.mac = MacDriver("mac", self)
        self.rx = EthRxMonitor("rx", self)
        self.flit_mon = FlitMonitor("flit_mon", self)
        self.phy = PhyCtrlModel("phy", self)
        self.csr = CsrAgent("csr", self)
        self.sb = Scoreboard("sb", self)

    def connect_phase(self):
        self.mac.seq_item_port.connect(self.seqr.seq_item_export)
        self.rx.ap.connect(self.sb.analysis_export)
