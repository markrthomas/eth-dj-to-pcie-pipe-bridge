"""PyVSC functional coverage for the bridge (docs/PLAN.md §6) + fcov.json export.

Covergroups
  frame_cg : frame length classes, last-beat byte count, frame err flag
  ctrl_cg  : powerdown transitions, rate values, width values, msgbus opcodes
  cdc_cg   : Tx/Rx CDC FIFO full seen, source gapped vs back-to-back beats
"""
import json

import vsc


@vsc.covergroup
class FrameCg:
    def __init__(self):
        self.with_sample(dict(length=vsc.uint16_t(), last_bytes=vsc.uint8_t(), err=vsc.bit_t(1)))
        self.cp_len = vsc.coverpoint(self.length, bins={
            "one": vsc.bin(1),
            "sub_beat": vsc.bin([2, 31]),
            "one_beat": vsc.bin(32),
            "sub_flit": vsc.bin([33, 239]),
            "one_flit": vsc.bin(240),
            "two_flits": vsc.bin([241, 480]),
            "mtu": vsc.bin([481, 1500]),
            "jumbo": vsc.bin([1501, 9000]),
        })
        self.cp_last = vsc.coverpoint(self.last_bytes, bins={
            "b1": vsc.bin(1), "b2_15": vsc.bin([2, 15]), "b16_31": vsc.bin([16, 31]), "b32": vsc.bin(32)})
        self.cp_err = vsc.coverpoint(self.err, bins={"good": vsc.bin(0), "aborted": vsc.bin(1)})


@vsc.covergroup
class CtrlCg:
    def __init__(self):
        self.with_sample(dict(kind=vsc.uint8_t(), frm=vsc.uint8_t(), to=vsc.uint8_t(), trans=vsc.uint8_t()))
        # kind: 0 pd, 1 rate, 2 width, 3 msgbus; trans = frm*4+to (powerdown transition)
        self.cp_pd = vsc.coverpoint(self.trans, iff=(self.kind == 0), bins={
            "P1_P0": vsc.bin(2 * 4 + 0), "P0_P1": vsc.bin(0 * 4 + 2),
            "P1_P2": vsc.bin(2 * 4 + 3), "P2_P1": vsc.bin(3 * 4 + 2)})
        self.cp_rate = vsc.coverpoint(self.to, iff=(self.kind == 1), bins={
            "gen5": vsc.bin(4), "gen6": vsc.bin(5)})
        self.cp_width = vsc.coverpoint(self.to, iff=(self.kind == 2), bins={
            "w0": vsc.bin(0), "w1": vsc.bin(1)})
        self.cp_mb = vsc.coverpoint(self.frm, iff=(self.kind == 3), bins={
            "wr_committed": vsc.bin(2), "wr_ack": vsc.bin(5)})


@vsc.covergroup
class CdcCg:
    def __init__(self):
        self.with_sample(dict(tx_full=vsc.bit_t(1), rx_full=vsc.bit_t(1), gapped=vsc.bit_t(1)))
        self.cp_tx_full = vsc.coverpoint(self.tx_full, bins={"not_full": vsc.bin(0), "full": vsc.bin(1)})
        self.cp_rx_full = vsc.coverpoint(self.rx_full, bins={"not_full": vsc.bin(0), "full": vsc.bin(1)})
        self.cp_src = vsc.coverpoint(self.gapped, bins={"back_to_back": vsc.bin(0), "gapped": vsc.bin(1)})


class Coverage:
    def __init__(self):
        self.frame = FrameCg()
        self.ctrl = CtrlCg()
        self.cdc = CdcCg()

    def sample_frame(self, length, err):
        lb = length % 32 or 32
        self.frame.sample(min(length, 9000), lb, int(err))

    def sample_ctrl(self, kind, frm, to):
        self.ctrl.sample(kind, frm, to, (frm * 4 + to) & 0xFF)

    def sample_cdc(self, tx_full, rx_full, gapped):
        self.cdc.sample(int(tx_full), int(rx_full), int(gapped))

    def export(self, path):
        """Write fcov.json: per covergroup/coverpoint coverage % and bin hit counts."""
        report = vsc.get_coverage_report_model()
        out = {"covergroups": {}, "kind": "measured", "tool": "pyvsc"}
        tot = []
        for cg in report.covergroups:
            cps = {}
            for cp in cg.coverpoints:
                bins = {b.name: b.count for b in cp.bins}
                cps[cp.name] = {"coverage": round(cp.coverage, 2), "bins": bins}
                tot.append(cp.coverage)
            out["covergroups"][cg.name] = {"coverage": round(cg.coverage, 2), "coverpoints": cps}
        out["overall"] = round(sum(tot) / len(tot), 2) if tot else 0.0
        with open(path, "w") as fh:
            json.dump(out, fh, indent=2)
        return out
