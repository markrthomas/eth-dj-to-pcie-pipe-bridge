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
rand_plan()/expected_rand()) is checked by crosscheck.py only when an env reports it.

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


def expected_rand(seed: int, frames: int = RAND_FRAMES_DEFAULT, maxlen: int = RAND_MAXLEN_DEFAULT) -> dict:
    lens, ctrl, _split = rand_plan(seed, frames, maxlen)
    crc = 0
    for i, n in enumerate(lens):
        crc = zlib.crc32(bytes(pat(i, k) for k in range(n)), crc)
    return {
        "frames": len(lens),
        "bytes": sum(lens),
        "flits": sum((n + FLIT_PAYLOAD_B - 1) // FLIT_PAYLOAD_B for n in lens),
        "crc32": f"{crc & 0xFFFFFFFF:08x}",
        "pmcnt": LINKUP_OPS + RAND_CTRL_OPS[RAND_CTRL.index(ctrl)],
        "errors": 0,
    }


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
        a = [int(x, 0) for x in sys.argv[2:5]]
        print("rand", *rand_plan(*a))
        json.dump(expected_rand(*a), sys.stdout, indent=2)
        print()
    elif len(sys.argv) > 1 and sys.argv[1] == "--lengths":
        # used by env generators: print "name len0 len1 ..." per scenario
        for name in ORDER:
            print(name, SCENARIOS[name][1], *lengths(name))
    else:
        json.dump(expected(), sys.stdout, indent=2)
        print()
