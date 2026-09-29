#!/usr/bin/env python3
"""Cross-check the five DV environments against the shared scenario golden model.

Usage: crosscheck.py [--require env1,env2,...] results.json [results.json ...]

Every results file must contain every scenario in scenarios.ORDER with values
equal to scenarios.expected(); environments listed in --require must be present.
Prints a table and exits non-zero on any mismatch or missing result.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenarios  # noqa: E402

FIELDS = ["frames", "bytes", "flits", "crc32", "pmcnt", "errors"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--require", default="", help="comma-separated env names that must be present")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()

    exp = scenarios.expected()
    envs = {}
    bad = 0
    for f in args.files:
        if not os.path.exists(f):
            continue
        with open(f) as fh:
            d = json.load(fh)
        envs[d["env"]] = d["scenarios"]

    for req in filter(None, args.require.split(",")):
        if req not in envs:
            print(f"MISSING: no results for required env '{req}'")
            bad += 1

    if not envs:
        print("crosscheck: no results files found")
        return 1

    names = sorted(envs)
    print(f"{'scenario':<12} {'field':<7} {'expected':>10} " + " ".join(f"{n:>10}" for n in names))
    for sc in scenarios.ORDER:
        for fld in FIELDS:
            row = []
            for n in names:
                v = envs[n].get(sc, {}).get(fld, "-")
                ok = str(v) == str(exp[sc][fld])
                if not ok:
                    bad += 1
                row.append(f"{str(v) + ('' if ok else '*'):>10}")
            print(f"{sc:<12} {fld:<7} {str(exp[sc][fld]):>10} " + " ".join(row))
    if bad:
        print(f"CROSSCHECK FAIL: {bad} mismatch(es) (* = differs from golden)")
        return 1
    print(f"CROSSCHECK PASS: {len(names)} env(s) agree with the golden model: {', '.join(names)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
