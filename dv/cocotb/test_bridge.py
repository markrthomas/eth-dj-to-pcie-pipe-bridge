"""cocotb + PyUVM tests for eth_dj_pipe7_bridge (DV env 5).

test_scenarios : the shared five-scenario set (dv/common/scenarios.py) followed by
                 two coverage-only scenarios (pm_full, rxovf).  Writes
                 results.json (cross-check scenarios only) and fcov.json (PyVSC).
"""
import json
import os

import cocotb
import pyuvm
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from pyuvm import ConfigDB, uvm_sequence, uvm_subscriber, uvm_test

import bridge_env as be
import scenarios
from fcov import Coverage

HERE = os.path.dirname(os.path.abspath(__file__))


class FrameSeq(uvm_sequence):
    """Sends frames [lo, hi) of the current scenario (lengths from the golden model)."""

    def __init__(self, name, lens, lo, hi):
        super().__init__(name)
        self.lens, self.lo, self.hi = lens, lo, hi

    async def body(self):
        for i in range(self.lo, self.hi):
            item = be.EthFrameItem(f"f{i}", i, self.lens[i])
            await self.start_item(item)
            await self.finish_item(item)


class ScenarioTest(uvm_test):
    def build_phase(self):
        self.env = be.BridgeEnv("env", self)
        self.cov = Coverage()
        self.fcs = FrameCovSub("fcs", self)
        self.ccs = CtrlCovSub("ccs", self)
        self.fcs.cov = self.cov
        self.ccs.cov = self.cov
        self.results = {}
        self.errors = 0

    def connect_phase(self):
        self.env.rx.ap.connect(self.fcs.analysis_export)       # frame coverage
        self.env.phy.ap.connect(self.ccs.analysis_export)      # control coverage

    def end_of_elaboration_phase(self):
        self.dut = cocotb.top
        self.seqr = ConfigDB().get(None, "", "SEQR")

    async def reset(self):
        d = self.dut
        d.eth_rst_n.value = 0
        d.pipe_rst_n.value = 0
        await ClockCycles(d.pclk, 10)
        await RisingEdge(d.pclk)
        d.eth_rst_n.value = 1
        d.pipe_rst_n.value = 1
        for _ in range(20000):
            s = await self.env.csr.read(be.CSR_STATUS)
            if (s >> 11) & 1:
                return
        raise AssertionError("link-up timeout")

    async def wait_frames(self, n, cycles=400000):
        for _ in range(cycles // 64):
            if self.env.sb.frames >= n:
                return True
            await ClockCycles(self.dut.pclk, 64)
        return self.env.sb.frames >= n

    async def cdc_sampler(self):
        d = self.dut
        last = None
        while True:
            await FallingEdge(d.eth_clk)
            try:
                txf = int(d.dut.u_tx_cdc.wfull.value)
                rxf = int(d.dut.u_rx_cdc.wfull.value)
            except (ValueError, AttributeError):
                continue
            cur = (txf, rxf, int(self.env.mac.gap_pct > 0))
            if cur != last:                      # sample on change: PyVSC sampling is slow
                self.cov.sample_cdc(*cur)
                last = cur

    async def run_scenario(self, name, lens, ctrl, crosscheck=True):
        env = self.env
        env.sb.reset_scenario(name, lens, lenient=(name == "rxovf"))
        env.phy.mute_status = False
        env.phy.mb_writes = 0
        await self.reset()
        f0, e0 = env.flit_mon.flits, env.flit_mon.errors + env.phy.errors + env.rx.errors
        n = len(lens)
        csr = env.csr
        ok = True
        if ctrl == "none":
            await FrameSeq("s", lens, 0, n).start(self.seqr)
        elif ctrl in ("pm_cycle", "rate_change"):
            await FrameSeq("a", lens, 0, n // 2).start(self.seqr)
            ok &= await self.wait_frames(n // 2)
            if ctrl == "pm_cycle":
                ok &= await csr.set_state(be.PWR_P1, be.RATE_GEN6)
                await ClockCycles(self.dut.pclk, 200)
                ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6)
            else:
                ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN5)
                await ClockCycles(self.dut.pclk, 200)
                ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6)
            await FrameSeq("b", lens, n // 2, n).start(self.seqr)
        elif ctrl == "pm_full":
            await FrameSeq("a", lens, 0, 4).start(self.seqr)
            ok &= await self.wait_frames(4)
            for pd in (be.PWR_P1, be.PWR_P2, be.PWR_P0):
                ok &= await csr.set_state(pd, be.RATE_GEN6)
            ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6, 1)
            ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6, 0)
            await csr.write(be.CSR_PAM4CFG, 0x35)
            await ClockCycles(self.dut.pclk, 200)
            ok &= env.phy.mb_last == (0x405, 0x35)   # MB_ADDR_TX_PRESET, 12-bit
            await csr.write(be.CSR_CTRL, (be.RATE_GEN6 << 2) | be.PWR_P0S)
            await ClockCycles(self.dut.pclk, 50)
            ok &= bool((await csr.read(be.CSR_ERR)) & 4)
            ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6)
            await csr.write(be.CSR_ERR, 4)
            env.phy.mute_status = True
            ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN5)
            env.phy.mute_status = False
            ok &= bool((await csr.read(be.CSR_ERR)) & 1)
            await csr.write(be.CSR_ERR, 1)
            ok &= await csr.set_state(be.PWR_P0, be.RATE_GEN6)
            await FrameSeq("b", lens, 4, n).start(self.seqr)
        elif ctrl == "rxovf":
            env.rx.ready_pct = 4
            env.mac.gap_pct = 0
            await FrameSeq("a", lens, 0, n).start(self.seqr)
            await ClockCycles(self.dut.pclk, 20000)
            env.rx.ready_pct = 100
            await ClockCycles(self.dut.pclk, 20000)
            env.rx.ready_pct = 90
            env.mac.gap_pct = 10
            ok &= env.sb.err_frames > 0
        if ctrl != "rxovf":
            ok &= await self.wait_frames(n)
        await ClockCycles(self.dut.pclk, 200)
        pmcnt = await csr.read(be.CSR_PMCNT)
        errs = env.sb.errors + (env.flit_mon.errors + env.phy.errors + env.rx.errors - e0) + (0 if ok else 1)
        self.errors += errs
        r = {"frames": env.sb.frames, "bytes": env.sb.nbytes, "flits": env.flit_mon.flits - f0,
             "crc32": f"{env.sb.crc & 0xFFFFFFFF:08x}", "pmcnt": pmcnt, "errors": errs}
        self.logger.info(f"SCEN {name:<11} {r}{'' if crosscheck else '  (coverage-only)'}")
        if crosscheck:
            self.results[name] = r

    async def run_phase(self):
        self.raise_objection()
        d = self.dut
        cocotb.start_soon(Clock(d.eth_clk, 5, units="ns").start())
        cocotb.start_soon(Clock(d.pclk, 2, units="ns").start())
        cocotb.start_soon(self.cdc_sampler())
        for name in scenarios.ORDER:
            await self.run_scenario(name, scenarios.lengths(name), scenarios.SCENARIOS[name][1])
        await self.run_scenario("pm_full", scenarios.lcg_lengths(13, 16), "pm_full", crosscheck=False)
        ovf = [n + 60 if n < 60 else n for n in scenarios.lcg_lengths(17, 60)]
        await self.run_scenario("rxovf", ovf, "rxovf", crosscheck=False)
        with open(os.path.join(HERE, "results.json"), "w") as fh:
            json.dump({"env": "cocotb", "scenarios": self.results}, fh, indent=2)
        fc = self.cov.export(os.path.join(HERE, "fcov.json"))
        self.logger.info(f"functional coverage overall {fc['overall']}%")
        self.drop_objection()


class FrameCovSub(uvm_subscriber):
    cov = None

    def write(self, fr):
        self.cov.sample_frame(len(fr.data), fr.err)


class CtrlCovSub(uvm_subscriber):
    cov = None
    KINDS = {"pd": 0, "rate": 1, "width": 2}

    def write(self, ev):
        if ev[0] == "mb":
            self.cov.sample_ctrl(3, ev[1], 0)
        else:
            self.cov.sample_ctrl(self.KINDS[ev[0]], ev[1], ev[2])


@pyuvm.test()
class test_scenarios(ScenarioTest):
    """Shared scenario set + coverage scenarios."""

    def final_phase(self):
        assert self.errors == 0, f"{self.errors} error(s)"
        assert set(self.results) == set(scenarios.ORDER), "missing scenario results"
