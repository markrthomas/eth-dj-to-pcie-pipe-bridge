#!/usr/bin/env python3
"""Shared DV scenario set (docs/PLAN.md §5 cross-check contract).

Every DV environment (iverilog, vlt, uvm, systemc, cocotb) runs these five
scenarios on the loopback harness (PIPE Tx looped to PIPE Rx, PHY control model,
CSR driver) with a DUT reset at the start of each scenario, and writes
``results.json``::

    {"env": "<name>", "scenarios": {"<scenario>": {"frames": int, "bytes": int,
     "flits": int, "crc32": "xxxxxxxx", "pmcnt": int, "errors": int}}}

frames/bytes/crc32 are measured on the Ethernet Rx side (crc32 = zlib CRC-32 of
all received frame bytes concatenated in arrival order), flits on the PIPE Tx
side (start_block beats), pmcnt is CSR PMCNT read at the end of the scenario.
``crosscheck.py`` compares every env against ``expected()`` below.

The optional ``rand`` scenario (results.json top-level ``"rand": {seed, frames, maxlen}``, see
rand_plan()/expected_rand()) is checked by crosscheck.py only when an env reports it.  With ``+rand_ctl=E`` (B3) the rand scenario also
runs E seeded control-plane episodes (random CSR / msgbus / reset traffic, see ctl_plan()); the golden then
returns pmcnt / flits as [min, max] ranges where the exact value is not predictable.

Frame i of a scenario carries bytes pat(i, k) for k in 0..len-1.
Random lengths use the LCG in lcg_lengths() (same constants in SV/C++/Python).
"""
import json
import sys
import zlib

FLIT_PAYLOAD_B = 240
LINKUP_OPS = 2          # P1->P0 + PAM4 msgbus write after every reset

# Scenario table: name -> (lengths, control op, pmcnt ops added by the control op)
#   ctrl "none"        : send all frames
#   ctrl "pm_cycle"    : send first half, wait until received, CSR P0->P1, wait,
#                        CSR P1->P0, wait, send second half
#   ctrl "rate_change" : as pm_cycle but Gen6->Gen5->Gen6 (+1 PAM4 re-send)


def pat(frame_id: int, idx: int) -> int:
    return (frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 0xFF


def lcg_lengths(seed: int, n: int, max_len: int = 2000) -> list:
    x = seed & 0x7FFFFFFF
    out = []
    for _ in range(n):
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        out.append(1 + ((x >> 8) % max_len))
    return out


SCENARIOS = {
    "single":      (lambda: [64],                                         "none",        0),
    "corners":     (lambda: [1, 31, 32, 33, 239, 240, 241, 480, 481, 1500, 9000], "none", 0),
    "random":      (lambda: lcg_lengths(0xC0FFEE, 40),                    "none",        0),
    "pm_cycle":    (lambda: lcg_lengths(7, 16),                           "pm_cycle",    2),
    "rate_change": (lambda: lcg_lengths(11, 16),                          "rate_change", 3),
}
ORDER = ["single", "corners", "random", "pm_cycle", "rate_change"]


def lengths(name: str) -> list:
    return SCENARIOS[name][0]()


RAND_CORNERS = [1, 239, 240, 241, 480]
RAND_CTRL = ["none", "pm_cycle", "rate_change"]
RAND_CTRL_OPS = [0, 2, 3]
RAND_FRAMES_DEFAULT = 24
RAND_MAXLEN_DEFAULT = 2000


def rand_plan(seed: int, frames: int = RAND_FRAMES_DEFAULT, maxlen: int = RAND_MAXLEN_DEFAULT):
    """The optional ``rand`` scenario (+rand_seed=N +rand_frames=K +rand_maxlen=L): returns
    (lengths, ctrl, split).  ~30 % of the frames take a corner length (1,239,240,241,480; clamped to
    maxlen), the rest lcg_lengths(seed, K, L).  ctrl is one of none/pm_cycle/rate_change, picked from
    lcg_lengths(seed^0x1E3779B9, 1, 3); the control op runs after ``split`` frames (1..K-1,
    lcg_lengths(seed^0x7F4A7C15, 1, K-1)).  Mirrored in dv/common/cpp/bridge_bfm.h enable_rand()."""
    frames, maxlen = max(1, frames), max(1, maxlen)
    base = lcg_lengths(seed, frames, maxlen)
    sel = lcg_lengths(seed ^ 0x2545F491, frames, 100)
    lens = [min(RAND_CORNERS[s % 5], maxlen) if s <= 30 else b for b, s in zip(base, sel)]
    if frames < 2:
        return lens, "none", frames
    ctrl = RAND_CTRL[lcg_lengths(seed ^ 0x1E3779B9, 1, 3)[0] - 1]
    split = lcg_lengths(seed ^ 0x7F4A7C15, 1, frames - 1)[0]
    return lens, ctrl, split


# ---- B3: seeded random control-plane traffic (rand_ctl=E episodes) -------------------------------------------
# Op kinds of the plan; the numbers are the OpKind enum of dv/common/cpp/bridge_bfm.h.
K_SEND, K_WAIT_RX, K_CSR_WR, K_PHY_WR, K_PHY_RD = 0, 1, 2, 9, 10
K_SETTLE, K_CSR_CHK, K_CSR_MONO, K_RESET, K_IDLE = 11, 12, 13, 14, 4
CSR_CTRL, CSR_PAM4CFG, CSR_STATUS, CSR_ERR, CSR_RXCNT0, CSR_RXCNT1, CSR_PMCNT = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18
PAM4CFG_RST = 0x21
MB_WR_UC, MB_WR_C = 1, 2
NREG_WIN, WB_DEPTH = 29, 8
CTL_MAX_RESETS = 3


class Lcg:
    """Control-plane stream: same LCG as lcg_lengths(), r(m) = (x >> 8) % m (0-based)."""
    def __init__(self, seed: int):
        self.x = seed & 0x7FFFFFFF

    def r(self, m: int) -> int:
        self.x = (1103515245 * self.x + 12345) & 0x7FFFFFFF
        return (self.x >> 8) % m


def reg_idx(a: int) -> int:
    """MAC register file index of a 12-bit msgbus address (rtl/msgbus_mac_tgt.sv reg_idx), -1 = reserved."""
    o, base = a & 0x1FF, (NREG_WIN if a & 0x200 else 0)
    hi = (a >> 10) & 3
    if hi == 0:
        if o <= 7:
            return base + o
        if 10 <= o <= 16:
            return base + 8 + (o - 10)
    elif hi == 1:
        if o <= 12:
            return base + 15 + o
    elif hi == 2:
        if o == 0:
            return base + 28
    return -1


class CtlSim:
    """Behavioural model of bridge_rf + bridge_ctrl_fsm op counting for *settled* CSR sequences, and of the
    msgbus_mac_tgt register file.  settle() returns the number of control operations (PMCNT increments)
    the FSM performs to converge on the requested state."""
    def __init__(self):
        self.reset()

    def reset(self):
        self.pd, self.rate, self.wid, self.dirty = 2, 5, 0, True     # P1, Gen6, x1, PAM4 ctl to send
        self.rq = (0, 5, 0)                                          # pwr_req, rate_req, width_req
        self.pam, self.err = PAM4CFG_RST, 0
        self.regs, self.wb = {}, []

    def ctrl_val(self) -> int:
        return self.rq[0] | (self.rq[1] << 2) | (self.rq[2] << 5)

    def ctrl_wr(self, v: int):
        rate, wid, pwr = (v >> 2) & 7, (v >> 5) & 3, v & 3
        if rate > 5 or wid == 3:
            self.err |= 8                      # whole write ignored (D19)
            return
        if pwr == 1:
            self.err |= 4                      # P0s requested (treated as P0)
        self.rq = (pwr, rate, wid)

    def pam_wr(self, v: int):
        self.pam, self.dirty = v & 0x3F, True

    def err_clr(self, m: int):
        self.err &= ~m & 0xF

    def settle(self) -> int:
        n = 0
        pw, rr, ww = self.rq
        pe = 0 if pw == 1 else pw
        while True:
            if self.pd == 0:                   # ACTIVE / DRAIN: rate > width > cfg > power down
                if rr != self.rate:
                    self.rate, self.dirty = rr, True
                elif ww != self.wid:
                    self.wid = ww
                elif self.dirty and self.rate == 5:
                    self.dirty = False
                elif pe != 0:
                    self.pd = 2
                else:
                    return n
            else:                              # LOWPWR: only power steps (P2 -> P0 goes via P1)
                if pe == 0:
                    self.pd = 2 if self.pd == 3 else 0
                elif pe == 2 and self.pd == 3:
                    self.pd = 2
                elif pe == 3 and self.pd == 2:
                    self.pd = 3
                else:
                    return n
            n += 1

    # MAC register file (PHY-initiated accesses)
    def phy_wr(self, cmd: int, a: int, d: int):
        if cmd == MB_WR_UC:
            if len(self.wb) < WB_DEPTH:
                self.wb.append((a, d))
            return
        for wa, wd in self.wb + [(a, d)]:
            if reg_idx(wa) >= 0:
                self.regs[reg_idx(wa)] = wd
        self.wb = []

    def phy_rd(self, a: int) -> int:
        i = reg_idx(a)
        return self.regs.get(i, 0) if i >= 0 else 0


def _ctrl_val(g: Lcg, legal: bool, pwr_heavy: bool = False) -> int:
    pwr = g.r(4) if pwr_heavy else (0, 0, 2, 3, 1)[g.r(5)]
    if legal:
        rate, wid = g.r(6), g.r(3)
    else:
        k = g.r(3)                             # 0: reserved rate, 1: reserved width, 2: both
        rate = g.r(6) if k == 1 else 6 + g.r(2)
        wid = g.r(3) if k == 0 else 3
    v = pwr | (rate << 2) | (wid << 5)
    if g.r(4) == 0:
        v |= g.r(0x7FFF) << 7                  # junk in the reserved bits [31:7]
    return v


def _rnd_addr(g: Lcg) -> int:
    c = g.r(10)
    if c in (0, 1, 8):
        return g.r(17)                         # Rx 0-16 (8, 9 reserved)
    if c in (2, 3, 9):
        return 0x400 + g.r(16)                 # Tx 0-12 (13-15 reserved)
    if c == 4:
        return 0x800 + g.r(2)                  # Cmn (0x801 reserved)
    if c == 5:
        return (0x200, 0x600, 0xA00)[g.r(3)] + g.r(16)   # RX2 / TX2 / CMN2 windows
    if c == 6:
        return 0xC00 + g.r(256)                # vendor window (reserved)
    return g.r(0x1000)                         # anything


def ctl_plan(seed: int, frames: int, episodes: int):
    """Plan of the rand scenario's control traffic (+rand_ctl=E); mirrored in bridge_bfm.h gen_ctl_plan_().
    Returns (ops, info): ops = [(kind, a, b, c, d, e)], info = pm_lo/pm_hi (final PMCNT range), nresets, hash.
    Each CSR sequence is settled (SETTLE waits for the expected pins and a stable PMCNT) so PMCNT is exact,
    except after a P-state storm (writes back to back, FSM path-dependent), where it is a [lo, hi] range
    until the next reset.  Mid-traffic resets re-send the frames the Ethernet sink had not yet received, so
    frames/bytes/crc stay exact; flits can only grow."""
    g = Lcg(seed ^ 0xC71A5EED)
    sim = CtlSim()
    sim.settle()                               # link-up already done when the plan starts (LINKUP_OPS)
    ops = []
    pm = [2, 2]                                # [lo, hi] of PMCNT in the current reset epoch (link-up = 2)
    nres = 0
    splits = sorted(g.r(frames + 1) for _ in range(episodes))
    sent = 0

    def emit(*t):
        ops.append(tuple(t) + (0,) * (6 - len(t)))

    def chk_regs(full: bool):
        emit(K_CSR_CHK, CSR_CTRL, sim.ctrl_val(), 0x7F)
        emit(K_CSR_CHK, CSR_ERR, sim.err, 0xF)
        if full:
            emit(K_CSR_CHK, CSR_PAM4CFG, sim.pam, 0xFF)

    def settled():
        n = sim.settle()
        pm[0] += n
        pm[1] += n
        emit(K_SETTLE, sim.pd, sim.rate, sim.wid, pm[0], pm[1])

    def phy_ops(cnt: int):
        for _ in range(cnt):
            c = g.r(10)
            a = _rnd_addr(g)
            if c <= 2:
                d = g.r(256)
                emit(K_PHY_WR, MB_WR_C, a, d)
                sim.phy_wr(MB_WR_C, a, d)
            elif c <= 4:
                k = 1 + g.r(10)                # k > 8 overflows the write buffer
                for _ in range(k):
                    ua, d = _rnd_addr(g), g.r(256)
                    emit(K_PHY_WR, MB_WR_UC, ua, d)
                    sim.phy_wr(MB_WR_UC, ua, d)
                if g.r(3) < 2:
                    d = g.r(256)
                    emit(K_PHY_WR, MB_WR_C, a, d)
                    sim.phy_wr(MB_WR_C, a, d)
            else:
                emit(K_PHY_RD, a, 0, sim.phy_rd(a))

    def item():
        nonlocal nres, sent
        c = g.r(100)
        if c >= 90 and nres >= CTL_MAX_RESETS:
            c = 0
        if c < 30:                             # settled CTRL / PAM4 / ERR writes, legal and illegal
            for _ in range(1 + g.r(4)):
                k = g.r(12)
                if k <= 8:
                    v = _ctrl_val(g, k <= 6)
                    emit(K_CSR_WR, CSR_CTRL, v)
                    sim.ctrl_wr(v)
                elif k == 9:
                    v = g.r(0x7FFFFFFF)
                    emit(K_CSR_WR, CSR_PAM4CFG, v)
                    sim.pam_wr(v)
                elif k == 10:
                    m = g.r(16)
                    emit(K_CSR_WR, CSR_ERR, m)
                    sim.err_clr(m)
                else:
                    v = sim.ctrl_val()
                    emit(K_CSR_WR, CSR_CTRL, v)
                settled()
                chk_regs(g.r(2) == 0)
                if g.r(3) == 0:
                    emit(K_CSR_MONO, CSR_PMCNT)
        elif c < 45:                           # P-state storm: back-to-back CTRL writes, then recover to P0/Gen6
            n = 3 + g.r(6)
            for _ in range(n):
                k = g.r(10)
                if k < 6:
                    v = _ctrl_val(g, True, True)
                    emit(K_CSR_WR, CSR_CTRL, v)
                    sim.ctrl_wr(v)
                elif k < 8:
                    v = _ctrl_val(g, False, True)
                    emit(K_CSR_WR, CSR_CTRL, v)
                    sim.ctrl_wr(v)
                elif k < 9:
                    v = g.r(0x7FFFFFFF)
                    emit(K_CSR_WR, CSR_PAM4CFG, v)
                    sim.pam_wr(v)
                else:
                    m = g.r(16)
                    emit(K_CSR_WR, CSR_ERR, m)
                    sim.err_clr(m)
            v = (5 << 2) | (g.r(3) << 5)
            emit(K_CSR_WR, CSR_CTRL, v)
            sim.ctrl_wr(v)
            lo = sim.settle()                  # direct path (minimum); sim now holds the converged state
            pm[0] += lo
            pm[1] += lo + 6 * (n + 1)
            emit(K_SETTLE, sim.pd, sim.rate, sim.wid, pm[0], pm[1])
            chk_regs(True)
            emit(K_CSR_MONO, CSR_PMCNT)
            emit(K_CSR_MONO, CSR_RXCNT0)
            emit(K_CSR_MONO, CSR_RXCNT1)
        elif c < 70:                           # PHY-initiated MAC register accesses (quiet point)
            phy_ops(2 + g.r(6))
        elif c < 80:                           # ... racing the bridge's own PAM4 msgbus write
            v = g.r(0x7FFFFFFF)
            emit(K_CSR_WR, CSR_PAM4CFG, v)
            sim.pam_wr(v)
            phy_ops(2 + g.r(3))
            settled()
            chk_regs(True)
        elif c < 90:                           # writes that must be ignored: RO / unmapped / reserved bits
            for _ in range(2 + g.r(4)):
                k, u = g.r(8), g.r(32)
                a = (CSR_STATUS, CSR_RXCNT0, CSR_RXCNT1, CSR_PMCNT, 0x1C, 0x20, 0x80 + 4 * u, 0xFC)[k]
                emit(K_CSR_WR, a, g.r(0x7FFFFFFF))
                if a not in (CSR_STATUS, CSR_RXCNT0, CSR_RXCNT1, CSR_PMCNT):
                    emit(K_CSR_CHK, a, 0, 0xFFFFFFFF)
            chk_regs(True)
            emit(K_CSR_MONO, CSR_PMCNT)
        else:                                  # DUT reset mid-traffic (optionally mid control op)
            if g.r(2):
                emit(K_CSR_WR, CSR_CTRL, _ctrl_val(g, True))
            emit(K_RESET, 6 + g.r(19))
            nres += 1
            sim.reset()
            pm[0] = pm[1] = 0
            settled()                          # link-up: P1 -> P0 + PAM4 msgbus write
            chk_regs(True)

    for e in range(episodes):
        if splits[e] > sent:
            emit(K_SEND, sent, splits[e])
            sent = splits[e]
        for _ in range(1 + g.r(3)):
            item()
    if sent < frames:
        emit(K_SEND, sent, frames)
    if sim.rq[0] not in (0, 1):                # frames still queued: leave P1/P2 so they can flow
        emit(K_CSR_WR, CSR_CTRL, (sim.rq[1] << 2) | (sim.rq[2] << 5))
        sim.ctrl_wr((sim.rq[1] << 2) | (sim.rq[2] << 5))
        settled()
    chk_regs(True)
    h = 2166136261
    for t in ops:
        for v in t:
            h = ((h ^ (v & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
    return ops, {"pm_lo": pm[0], "pm_hi": pm[1], "nresets": nres, "hash": f"{h:08x}", "nops": len(ops)}


def expected_rand(seed: int, frames: int = RAND_FRAMES_DEFAULT, maxlen: int = RAND_MAXLEN_DEFAULT, ctl: int = 0) -> dict:
    lens, ctrl, _split = rand_plan(seed, frames, maxlen)
    crc = 0
    for i, n in enumerate(lens):
        crc = zlib.crc32(bytes(pat(i, k) for k in range(n)), crc)
    flits = sum((n + FLIT_PAYLOAD_B - 1) // FLIT_PAYLOAD_B for n in lens)
    res = {
        "frames": len(lens),
        "bytes": sum(lens),
        "flits": flits,
        "crc32": f"{crc & 0xFFFFFFFF:08x}",
        "pmcnt": LINKUP_OPS + RAND_CTRL_OPS[RAND_CTRL.index(ctrl)],
        "errors": 0,
    }
    if ctl > 0:
        _ops, info = ctl_plan(seed, len(lens), ctl)
        res["pmcnt"] = info["pm_lo"]
        if info["pm_hi"] != info["pm_lo"]:
            res["pmcnt_max"] = info["pm_hi"]
        if info["nresets"]:
            res["flits_max"] = flits * (1 + info["nresets"])    # a reset re-sends the frames not yet received
        res["plan"] = info["hash"]
    return res


def expected() -> dict:
    res = {}
    for name in ORDER:
        lens, _ctrl, ops = SCENARIOS[name]
        lens = lens()
        crc = 0
        for i, n in enumerate(lens):
            crc = zlib.crc32(bytes(pat(i, k) for k in range(n)), crc)
        res[name] = {
            "frames": len(lens),
            "bytes": sum(lens),
            "flits": sum((n + FLIT_PAYLOAD_B - 1) // FLIT_PAYLOAD_B for n in lens),
            "crc32": f"{crc & 0xFFFFFFFF:08x}",
            "pmcnt": LINKUP_OPS + ops,
            "errors": 0,
        }
    return res


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--rand":
        # --rand SEED [FRAMES [MAXLEN]]: print the rand scenario plan + expected values
        # (+ CTL: also the B3 control plan: episodes count; prints the plan ops and hash)
        a = [int(x, 0) for x in sys.argv[2:6]]
        print("rand", *rand_plan(*a[:3]))
        json.dump(expected_rand(*a), sys.stdout, indent=2)
        print()
        if len(a) == 4 and a[3] > 0:
            ops, info = ctl_plan(a[0], len(rand_plan(*a[:3])[0]), a[3])
            for t in ops:
                print("  ", *t)
            print("ctl plan", info)
    elif len(sys.argv) > 1 and sys.argv[1] == "--lengths":
        # used by env generators: print "name len0 len1 ..." per scenario
        for name in ORDER:
            print(name, SCENARIOS[name][1], *lengths(name))
    else:
        json.dump(expected(), sys.stdout, indent=2)
        print()
