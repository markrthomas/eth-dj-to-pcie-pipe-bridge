#!/usr/bin/env python3
"""check_pd.py results.xml pd_results.json — fail if any cocotb test failed; print the retention table."""
import json
import sys
import xml.etree.ElementTree as ET

x = ET.parse(sys.argv[1]).getroot()
bad = [tc.get("name") for tc in x.iter("testcase") if tc.find("failure") is not None or tc.find("error") is not None]
if bad:
    print("PD FAIL: failed tests:", bad)
    sys.exit(1)
r = json.load(open(sys.argv[2]))
print("PD retention matrix (PD_DP power cycle via the PMU, UPF-like emulation%s):" % (", datapath-local reset ON" if r.get("_dp_reset") else ", reset DISABLED (retention required)"))
for k in sorted(k for k in r if not k.startswith("_")):
    print("  %-34s %-4s %s" % (k, "PASS" if r[k]["ok"] else "FAIL", r[k]["reason"]))
print("  single-group sensitive:", r.get("_single_sensitive"))
print("  minimal retained set (greedy):", r.get("_minimal_retain"))
bt, br = r.get("_bits_total"), r.get("_bits_retained_minimal")
if bt:
    print("  PD_DP register bits: total %d, minimal retained set %d (%.1f %%); per group:" % (bt, br, 100.0 * br / bt))
    for g, b in sorted(r["_bits"].items(), key=lambda kv: -kv[1]):
        print("    %-24s %6d" % (g, b))
if r.get("_minimal_regs") and not r.get("_dp_reset"):
    open("retention_min.txt", "w").write(
        "# registers that must be retained across a PD_DP power cycle (lp/cocotb: greedy minimal set; "
        "<instance>.<reg>[width]); regenerate with `make -C lp/cocotb pd`\n" + "\n".join(r["_minimal_regs"]) + "\n")
    print("  wrote retention_min.txt (%d registers)" % len(r["_minimal_regs"]))
print("PD PASS")
