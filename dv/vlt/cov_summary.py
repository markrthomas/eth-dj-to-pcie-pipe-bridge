#!/usr/bin/env python3
"""Summarise a Verilator coverage.dat and emit an lcov coverage.info.

Usage: cov_summary.py <coverage.dat> --info <out.info> [--floor PCT] [--json out.json]

* "line" coverage = Verilator v_line + v_branch points hit / total, per rtl file
  and overall (this is what the PLAN §6 >= 80% floor is checked against).
* toggle coverage = v_toggle points hit / total (reported, not gated).
* coverage.info is produced by verilator_coverage --write-info from a copy of the
  .dat that holds only the line/branch points, so lcov line data is not
  polluted by per-bit toggle points.
Exit status 1 if overall line coverage is below --floor.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys

REC = re.compile(r"^C '(.*)' (\d+)\s*$")


def parse(path):
    pts = []
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("latin-1")
            m = REC.match(line)
            if not m:
                continue
            fields = {}
            for kv in m.group(1).split("\x01"):
                if "\x02" in kv:
                    k, v = kv.split("\x02", 1)
                    fields[k] = v
            page = fields.get("page", "")
            kind = page.split("/", 1)[0].replace("v_", "")
            pts.append((kind, fields.get("f", "?"), int(m.group(2)), line))
    return pts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dat")
    ap.add_argument("--info", required=True)
    ap.add_argument("--floor", type=float, default=0.0)
    ap.add_argument("--json", default="")
    ap.add_argument("--verilator-coverage", default=os.environ.get("VERILATOR_COV", "verilator_coverage"))
    a = ap.parse_args()

    pts = parse(a.dat)
    if not pts:
        print(f"cov_summary: no coverage points in {a.dat}")
        return 1

    per = collections.defaultdict(lambda: [0, 0])      # file -> [hit, total] (line+branch)
    tog = [0, 0]
    keep = []
    with open(a.dat, "rb") as fh:
        header = [l.decode("latin-1") for l in fh if not l.startswith(b"C ")]
    for kind, f, cnt, raw in pts:
        if kind in ("line", "branch"):
            per[os.path.basename(f)][0] += cnt > 0
            per[os.path.basename(f)][1] += 1
            keep.append(raw)
        elif kind == "toggle":
            tog[0] += cnt > 0
            tog[1] += 1

    lb_dat = a.dat + ".linebranch"
    with open(lb_dat, "w", encoding="latin-1") as fh:
        fh.writelines(header)
        fh.writelines(keep)
    subprocess.run([a.verilator_coverage, "--write-info", a.info, lb_dat], check=True)

    hit = sum(v[0] for v in per.values())
    tot = sum(v[1] for v in per.values())
    pct = 100.0 * hit / tot
    tpct = 100.0 * tog[0] / tog[1] if tog[1] else 0.0
    print(f"{'file':<24} {'line+branch':>12}")
    for f in sorted(per):
        h, t = per[f]
        print(f"{f:<24} {h:>5}/{t:<5} {100.0 * h / t:5.1f}%")
    print(f"{'TOTAL':<24} {hit:>5}/{tot:<5} {pct:5.1f}%   (toggle {tog[0]}/{tog[1]} = {tpct:.1f}%, not gated)")
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"line_branch_pct": round(pct, 2), "line_branch_hit": hit, "line_branch_total": tot,
                       "toggle_pct": round(tpct, 2), "toggle_hit": tog[0], "toggle_total": tog[1],
                       "per_file": {f: {"hit": v[0], "total": v[1]} for f, v in per.items()}}, fh, indent=2)
    if pct < a.floor:
        print(f"COVERAGE FAIL: {pct:.1f}% < floor {a.floor:.0f}%")
        return 1
    print(f"COVERAGE PASS: line+branch {pct:.1f}% >= floor {a.floor:.0f}%  -> {a.info}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
