"""test_pd.py — PD_DP power-cycle matrix with the UPF-like emulation (pd_emu.py).

Each test: reset, link up, send frames A, power the datapath down through the PMU (CSR request P1),
hold it off, wake it (CSR request P0), send frames B, and require every frame of A and B to arrive
intact and in order with no drop / abort and the control FSM back in ST_ACTIVE.  Tests differ in
which state groups are retained.  Pass criteria asserted: baseline (no power cycle), retain-all
(D14's decision) and the minimal retained set found by the matrix must pass; retain-nothing is the
negative control and must FAIL (otherwise the emulation does not bite).  Per-group results are data
(written to $PD_RESULTS), not assertions.
"""
import json
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout

import scenarios
from pd_emu import DP_INST, PdEmu

ETH_BYTES = 32
PWR_P0, PWR_P1 = 0, 2
RATE_GEN6 = 5
CSR_CTRL, CSR_STATUS, CSR_RXCNT0, CSR_RXCNT1 = 0x00, 0x08, 0x10, 0x14
MB_WR_C, MB_WR_ACK = 2, 5
RESULTS = {}
DPR = os.environ.get("PD_DP_RESET", "0") == "1"      # build has -DDP_RESET_OVERRIDE (D18): no retention needed


def ival(s):
    try:
        return int(s.value)
    except ValueError:
        return 0


class Env:
    def __init__(self, dut, emu):
        self.d, self.emu = dut, emu
        self.rx = []               # (bytes, err)
        self.ready_pct = 90
        self.rng = random.Random(5)
        self.errors = 0
        self.mute = False
        self.tasks = []

    def stop(self):
        """Kill every coroutine of this case (clocks, models, emulation) so cases do not pile up."""
        for t in self.tasks:
            t.kill()
        if self.emu.forced:
            self.emu._release()

    # ---- sink (eth_clk): drive tready after the edge, sample at the falling edge
    async def sink(self):
        d = self.d
        d.eth_rx_tready.value = 0
        buf = bytearray()
        while True:
            await RisingEdge(d.eth_clk)
            ready = int(ival(d.eth_rst_n) and self.rng.randrange(100) < self.ready_pct)
            d.eth_rx_tready.value = ready
            await FallingEdge(d.eth_clk)
            # PD_DP outputs are clamped to 0 while isolated: no beat can be seen
            if self.emu.iso or not (ready and ival(d.eth_rx_tvalid)):
                continue
            keep, last = ival(d.eth_rx_tkeep), ival(d.eth_rx_tlast)
            err = ival(d.eth_rx_tuser) & 1
            nb = bin(keep).count("1")
            if nb == 0 or keep != (1 << nb) - 1 or (not last and nb != ETH_BYTES):
                self.errors += 1
            buf += ival(d.eth_rx_tdata).to_bytes(ETH_BYTES, "little")[:nb]
            if last:
                self.rx.append((bytes(buf), bool(err)))
                buf = bytearray()

    # ---- MAC source
    async def send(self, fid, length):
        d = self.d
        data = bytes(scenarios.pat(fid, k) for k in range(length))
        off = 0
        while off < len(data):
            await RisingEdge(d.eth_clk)
            chunk = data[off:off + ETH_BYTES]
            d.eth_tvalid.value = 1
            d.eth_tdata.value = int.from_bytes(chunk.ljust(ETH_BYTES, b"\0"), "little")
            d.eth_tkeep.value = (1 << len(chunk)) - 1
            d.eth_tlast.value = int(off + len(chunk) >= len(data))
            await FallingEdge(d.eth_clk)
            if ival(d.eth_tready) and not self.emu.iso:      # clamped tready reads 0 while isolated
                off += len(chunk)
        await RisingEdge(d.eth_clk)
        d.eth_tvalid.value = 0
        d.eth_tlast.value = 0

    # ---- PHY control model (PhyStatus + message-bus target), as dv/cocotb PhyCtrlModel
    async def phy(self):
        d = self.d
        d.pipe_phy_status.value = 1
        d.pipe_p2m_msgbus.value = 0
        rst_cnt = st_cnt = ack_cnt = 0
        prev, mb_ph = None, 0
        while True:
            await FallingEdge(d.pclk)
            rst = not ival(d.pipe_rst_n)
            pins = (ival(d.pipe_powerdown), ival(d.pipe_rate), ival(d.pipe_width))
            m2p = ival(d.pipe_m2p_msgbus)
            await RisingEdge(d.pclk)
            if rst:
                d.pipe_phy_status.value = 1
                d.pipe_p2m_msgbus.value = 0
                rst_cnt = st_cnt = ack_cnt = 0
                prev, mb_ph = pins, 0
                continue
            status = 0
            if rst_cnt < 16:
                rst_cnt += 1
                status = 1
            elif pins != prev:
                st_cnt = 8
            elif st_cnt == 1:
                st_cnt = 0
                status = 1
            elif st_cnt > 1:
                st_cnt -= 1
            prev = pins
            d.pipe_phy_status.value = status
            p2m = 0
            if mb_ph == 1:
                mb_ph = 2
            elif mb_ph == 2:
                mb_ph, ack_cnt = 0, 8
            elif m2p != 0 and (m2p >> 4) == MB_WR_C:
                mb_ph = 1
            if ack_cnt == 1:
                ack_cnt, p2m = 0, MB_WR_ACK << 4
            elif ack_cnt > 1:
                ack_cnt -= 1
            d.pipe_p2m_msgbus.value = p2m

    # ---- CSR
    async def csr_write(self, addr, data):
        d = self.d
        await RisingEdge(d.pclk)
        d.csr_valid.value, d.csr_write.value = 1, 1
        d.csr_addr.value, d.csr_wdata.value = addr, data
        await RisingEdge(d.pclk)
        d.csr_valid.value, d.csr_write.value = 0, 0

    async def csr_read(self, addr):
        d = self.d
        await RisingEdge(d.pclk)
        d.csr_addr.value = addr
        await FallingEdge(d.pclk)
        return ival(d.csr_rdata)

    async def wait_status(self, pd, timeout=3000):
        for _ in range(timeout):
            s = await self.csr_read(CSR_STATUS)
            if (s & 3) == pd and ((s >> 2) & 7) == RATE_GEN6 and not (s >> 10) & 1:
                return True
        return False

    async def wait_link_up(self, timeout=20000):
        for _ in range(timeout):
            if (await self.csr_read(CSR_STATUS) >> 11) & 1:
                return True
        return False

    async def wait_cycles_until(self, cond, timeout):
        for _ in range(timeout):
            if cond():
                return True
            await RisingEdge(self.d.pclk)
        return cond()


async def bring_up(dut, retain, seed=1):
    tasks = [cocotb.start_soon(Clock(dut.eth_clk, 5, units="ns").start()),
             cocotb.start_soon(Clock(dut.pclk, 2, units="ns").start())]
    for s in (dut.eth_tvalid, dut.eth_tlast, dut.eth_tkeep, dut.eth_tdata, dut.csr_valid,
              dut.csr_write, dut.csr_addr, dut.csr_wdata):
        s.value = 0
    dut.eth_rst_n.value = 0
    dut.pipe_rst_n.value = 0
    await ClockCycles(dut.pclk, 10)
    emu = PdEmu(dut, retain, seed)
    env = Env(dut, emu)
    env.tasks = tasks + [cocotb.start_soon(env.sink()), cocotb.start_soon(env.phy()), cocotb.start_soon(emu.run())]
    dut.eth_rst_n.value = 1
    dut.pipe_rst_n.value = 1
    return env


async def frames(env, fids, lens, timeout_cycles=200000):
    start = len(env.rx)
    for f, n in zip(fids, lens):
        await with_timeout(env.send(f, n), timeout_cycles * 2, "ns")
    ok = await env.wait_cycles_until(lambda: len(env.rx) >= start + len(fids), 40000)
    return ok


async def scenario(dut, retain, power_cycle=True, nframes=6, seed=1):
    """Run one power-cycle scenario; return (ok, reason)."""
    env = await bring_up(dut, retain, seed)
    lens = scenarios.lcg_lengths(11, 2 * nframes, 900)
    try:
        if not await env.wait_link_up():
            return False, "link-up timeout"
        if not await frames(env, range(nframes), lens[:nframes]):
            return False, "frames A not delivered"
        if power_cycle:
            await env.csr_write(CSR_CTRL, (RATE_GEN6 << 2) | PWR_P1)
            if not await env.wait_status(PWR_P1):
                return False, "P1 entry timeout"
            if not await env.wait_cycles_until(lambda: int(dut.dp_off.value) == 1, 2000):
                return False, "PD_DP never powered off"
            await ClockCycles(dut.pclk, 120)
            await env.csr_write(CSR_CTRL, (RATE_GEN6 << 2) | PWR_P0)
            if not await env.wait_status(PWR_P0):
                return False, "P0 wake timeout (FSM stuck)"
            if not await env.wait_cycles_until(lambda: int(dut.dp_off.value) == 0 and not env.emu.iso, 500):
                return False, "PD_DP never powered back up / de-isolated"
            await ClockCycles(dut.pclk, 20)
            if int(dut.n_down.value) != 1 or int(dut.n_up.value) != 1:
                return False, "PMU episodes %d/%d" % (int(dut.n_down.value), int(dut.n_up.value))
        if not await frames(env, range(nframes, 2 * nframes), lens[nframes:]):
            return False, "frames B not delivered after the power cycle"
        await ClockCycles(dut.pclk, 200)
        want = [bytes(scenarios.pat(f, k) for k in range(n)) for f, n in zip(range(2 * nframes), lens)]
        got = env.rx
        if len(got) != len(want):
            return False, "frame count %d != %d" % (len(got), len(want))
        for i, (w, (g, err)) in enumerate(zip(want, got)):
            if err or g != w:
                return False, "frame %d corrupt/flagged (len %d vs %d, err %s)" % (i, len(g), len(w), err)
        if env.errors:
            return False, "illegal tkeep at the sink"
        c0, c1 = await env.csr_read(CSR_RXCNT0), await env.csr_read(CSR_RXCNT1)
        if (c0 & 0xFFFF) or (c1 >> 16):
            return False, "Rx drop/abort counters non-zero (%08x %08x)" % (c0, c1)
        return True, "ok"
    except Exception as e:                           # timeouts surface as failures of this configuration
        return False, "exception: %s" % str(e)[:80]
    finally:
        env.stop()


SEEDS = (1, 2, 3)          # corruption values differ per seed; a configuration passes only if all seeds pass


async def run_case(dut, name, retain, power_cycle=True):
    why_all = []
    ok = True
    for sd in SEEDS:
        o, why = await scenario(dut, retain, power_cycle, seed=sd)
        ok &= o
        if not o:
            why_all.append("seed %d: %s" % (sd, why))
            break
    why = "ok" if ok else "; ".join(why_all)
    RESULTS[name] = {"retain": sorted(retain), "ok": ok, "reason": why}
    dut._log.info("PD-CASE %-34s %s  (%s)" % (name, "PASS" if ok else "FAIL", why))
    return ok


def groups_of(dut):
    emu = PdEmu(dut, ())
    return [g for g, regs in emu.groups.items() if regs]      # empty groups (e.g. combinational eth_egress) have no state


@cocotb.test()
async def t0_baseline(dut):
    """No power cycle: the lean environment itself works."""
    assert await run_case(dut, "baseline_no_power_cycle", {"all"}, power_cycle=False)


@cocotb.test()
async def t1_retain_all(dut):
    """D14 decision: full PD_DP retention survives a P1 power cycle."""
    assert await run_case(dut, "retain_all", {"all"})


@cocotb.test()
async def t2_retain_none(dut):
    """Retain nothing.  Default build (negative control): the emulation must break the design.
    DP_RESET build (D18): the datapath-local reset must make retention unnecessary."""
    ok = await run_case(dut, "retain_none", set())
    if DPR:
        assert ok, "DP_RESET build: retain-nothing must pass (datapath reset on low-power exit)"
    else:
        assert not ok, "retain-nothing passed: the corruption emulation does not bite"


@cocotb.test()
async def t3_single(dut):
    """Corrupt exactly one group, retain the rest (single-group sensitivity; not additive)."""
    gs = groups_of(dut)
    sens = []
    for g in gs:
        ok = await run_case(dut, "corrupt_only:" + g, set(gs) - {g})
        if not ok:
            sens.append(g)
    RESULTS["_single_sensitive"] = sens
    dut._log.info("PD-SINGLE sensitive groups: %s" % sens)


@cocotb.test()
async def t4_greedy_minimal(dut):
    """Greedy elimination: drop a group from the retained set whenever the power cycle still passes."""
    cur = set(groups_of(dut))
    for g in groups_of(dut):
        if await run_case(dut, "greedy_drop:" + g, cur - {g}):
            cur -= {g}
    RESULTS["_minimal_retain"] = sorted(cur)
    dut._log.info("PD-MINIMAL retained set: %s" % sorted(cur))
    assert await run_case(dut, "retain_minimal_verify", cur)


@cocotb.test()
async def t8_bits(dut):
    """State size per group (RTL register bits; includes always_comb targets, so an upper bound of flops)."""
    emu = PdEmu(dut, ())
    bits = {g: sum(w for _, w in regs) for g, regs in emu.groups.items() if regs}
    RESULTS["_bits"] = bits
    must = set(RESULTS.get("_minimal_retain", []))
    RESULTS["_dp_reset"] = DPR
    RESULTS["_bits_total"] = sum(bits.values())
    RESULTS["_bits_retained_minimal"] = sum(b for g, b in bits.items() if g in must)
    RESULTS["_minimal_regs"] = sorted("%s.%s[%d]" % (g.split("/")[0], h._name, w)
                                      for g, regs in emu.groups.items() if g in must for h, w in regs)
    dut._log.info("PD-BITS total %d, minimal retained set %d" % (RESULTS["_bits_total"], RESULTS["_bits_retained_minimal"]))


@cocotb.test()
async def t9_write_results(dut):
    path = os.environ.get("PD_RESULTS")
    if path:
        json.dump(RESULTS, open(path, "w"), indent=1, sort_keys=True)
