#!/usr/bin/env python3
"""vcd_rebase.py IN.vcd OUT.vcd — shift all timestamps so the first one is #0.

OpenSTA's read_vcd takes the activity window as [0, last timestamp]; a VCD that only dumps a window
starting at t0 would otherwise be diluted by t0/(window) (7x for a 2 us window at 12 us)."""
import sys

src, dst = sys.argv[1], sys.argv[2]
t0 = None
with open(src) as f, open(dst, "w") as g:
    for line in f:
        if line.startswith("#"):
            t = int(line[1:])
            if t0 is None:
                t0 = t
            g.write("#%d\n" % (t - t0))
        else:
            g.write(line)
print("rebased %s: window starts at %s ps" % (dst, t0))
