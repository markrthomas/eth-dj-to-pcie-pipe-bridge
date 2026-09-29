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
    if len(sys.argv) > 1 and sys.argv[1] == "--lengths":
        # used by env generators: print "name len0 len1 ..." per scenario
        for name in ORDER:
            print(name, SCENARIOS[name][1], *lengths(name))
    else:
        json.dump(expected(), sys.stdout, indent=2)
        print()
