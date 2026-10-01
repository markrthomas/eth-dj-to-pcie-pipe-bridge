"""pd_emu.py — UPF-like power-state emulation of PD_DP for the bridge (cocotb 1.8.1, Icarus).

No power tool and no UPF semantics: this emulates what lp/bridge.upf would do in a power-aware
simulator, driven by the DV-only PMU (lp/pipe7_pmu.sv) outputs:

  dp_pwr_en = 0   corrupt: every pclk, all state registers of the PD_DP instances get random values
                  (a powered-off domain holds nothing; random rather than X so Icarus keeps running)
  dp_save pulse   retention save: snapshot the *retained* state groups
  dp_restore      retention restore: write the snapshot back (same cycle semantics as a restore pulse)
  dp_iso_en = 1   isolation: the PD_DP outputs the always-on logic reads are FORCED to their clamp
                  values (lp/bridge.upf ISO_DP_1 / ISO_DP_0); the PD_DP outputs on the DUT ports are
                  ignored by the models via PdEmu.iso (clamp 0 = no handshake)

State groups = per PD_DP instance `<inst>/ctl` (registers narrower than WIDE_BITS), `<inst>/wide`
(registers of WIDE_BITS or more: flit buffers, accumulators) and `<inst>/mem` (register arrays, i.e.
the two CDC FIFO memories).  `retain` selects which groups are saved/restored; the rest
stay corrupt after power-up.  Limits: registers that are really combinational (always_comb targets)
are included too (harmless: recomputed); X-propagation / power-up glitches are not modelled; the
RTL has no datapath-local reset, so "corrupt + reset" is not an option here (an RTL change, D14).
"""
import random

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge

DP_INST = ["u_tx_gate", "u_tx_cdc", "u_tx_framer", "u_tx_egress",
           "u_rx_ingress", "u_rx_deframer", "u_rx_cdc", "u_eth_egress"]
# PD_DP outputs read by the always-on logic (net in eth_dj_pipe7_bridge) -> clamp value
WIDE_BITS = 64
ISO_NETS = {"tx_fifo_empty": 1, "framer_idle": 1, "rx_ing_idle": 1, "ingress_stopped_eth": 1,
            "egress_busy": 0, "rx_dropped_flits": 0, "rx_lock_errors": 0, "rx_bad_flits": 0,
            "rx_aborted_frames": 0}


def _regs(h, out, arrays):
    """Collect (handle, width) of every register below h; arrays (register memories) apart."""
    for c in h:
        t = c._type
        if t == "GPI_REGISTER":
            out.append((c, len(c)))
        elif t == "GPI_ARRAY":
            for i in range(len(c)):
                arrays.append((c[i], len(c[i])))
        elif t == "GPI_MODULE":
            _regs(c, out, arrays)


class PdEmu:
    def __init__(self, dut, retain=(), seed=1):
        self.dut = dut
        self.bridge = dut.top.dut
        self.rng = random.Random(seed)
        self.retain = set(retain)                    # group names, e.g. "u_tx_cdc/mem"; "all" = every group
        self.groups = {}
        for inst in DP_INST:
            regs, mem = [], []
            _regs(getattr(self.bridge, inst), regs, mem)
            self.groups[inst + "/ctl"] = [r for r in regs if r[1] < WIDE_BITS]
            self.groups[inst + "/wide"] = [r for r in regs if r[1] >= WIDE_BITS]
            if mem:
                self.groups[inst + "/mem"] = mem
        self.iso = False                             # DP outputs on the DUT ports are clamped (models read this)
        self.off = False
        self.n_corrupt = 0
        self.snap = {}
        self.forced = False

    def retained(self, g):
        return "all" in self.retain or g in self.retain

    def _corrupt_all(self):
        for regs in self.groups.values():
            for h, w in regs:
                h.value = self.rng.getrandbits(w)
        self.n_corrupt += 1

    def _save(self):
        self.snap = {g: [int(h.value) if h.value.is_resolvable else 0 for h, _ in regs]
                     for g, regs in self.groups.items() if self.retained(g)}

    def _restore(self):
        for g, vals in self.snap.items():
            for (h, _), v in zip(self.groups[g], vals):
                h.value = v

    def _force(self):
        for n, v in ISO_NETS.items():
            getattr(self.bridge, n).value = Force(v)
        self.forced = True

    def _release(self):
        for n in ISO_NETS:
            getattr(self.bridge, n).value = Release()
        self.forced = False

    async def run(self):
        d = self.dut
        while True:
            await RisingEdge(d.pclk)
            if not int(d.pipe_rst_n.value):
                if self.forced:
                    self._release()
                self.iso = self.off = False
                continue
            pwr, iso = int(d.dp_pwr_en.value), int(d.dp_iso_en.value)
            if int(d.dp_save.value):
                self._save()
            self.off = not pwr
            if self.off:
                self._corrupt_all()
            if int(d.dp_restore.value):
                self._restore()
            if iso and not self.forced:
                self._force()
            if not iso and self.forced:
                self._release()
            self.iso = bool(iso)
