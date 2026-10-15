#!/usr/bin/env python3
"""Random regression for the Icarus testbenches (dv/iverilog) - the iverilog sibling of rr.py.

    rr_iv.py build                      build the seedable vvp images (x1 and PIPE_NLANES_OVERRIDE=4)
    rr_iv.py run [--n N] [--jobs J] [--seed-base S] [--out DIR] [--timeout SEC] [--x4 PCT]
                                        N random (tb, lanes, seed) jobs -> DIR/results.jsonl

A job runs one of tb_scen / tb_edge / tb_loop / tb_msgbus_mac / tb_link with +seed=N (rr_seed.svh:
MAC gaps, sink back-pressure, PHY-ctrl latency, frame lengths) in its own directory.  results.jsonl
uses the schema of rr.py (id, config, seed, args, status, signature, dir; plus rc and cmd) so
`rr.py triage DIR` clusters it unchanged.  config = iv-<tb> or iv-<tb>-x4.  tb_scen results are also
run through dv/common/crosscheck.py.  No RTL or checker is changed here.
"""
import argparse
import concurrent.futures as cf
import datetime
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rr import signature as _rr_signature  # noqa: E402  (same normalisation as rr.py, so clusters line up)


def signature(text, rc, timed_out):
    """rr.py's signature, but on the first *specific* failure line: the TB's own 'XXX FAIL: n error(s)'
    summary and 'RR seed=' banner would otherwise hide it (and merge unrelated failures)."""
    body = "\n".join(l for l in text.splitlines() if not re.match(r"^[A-Z-]+ FAIL: \d+ error", l) and not l.startswith("RR seed="))
    return _rr_signature(body, rc, timed_out) or _rr_signature(text, rc, timed_out)

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
IV = os.path.join(ROOT, "dv", "iverilog")
XCHK = os.path.join(ROOT, "dv", "common", "crosscheck.py")
# build dirs match the .gitignore globs dv/*/sim_build_fc*/
BUILDS = {1: "sim_build_fcrr", 4: "sim_build_fcrr_x4"}
# tb -> (make target, vvp image relative to dv/iverilog/<BUILD>, PASS marker, selection weight)
TBS = {
    "scen": ("scen", "scen.vvp", "SCEN PASS", 3),
    "edge": ("edge", "edge.vvp", "EDGE PASS", 2),
    "loop": ("loop", "loop.vvp", "LOOP PASS", 2),
    "msgbus_mac": ("msgbus_mac", "msgbus_mac.vvp", "MSGBUS-MAC PASS", 1),
    "link": ("link", "link.vvp", "LINK PASS", 2),   # lives in <BUILD>_fc (flow control ON)
}


def vvp_path(tb, lanes):
    b = BUILDS[lanes] + ("_fc" if tb == "link" else "")
    return os.path.join(IV, b, TBS[tb][1])


def cmd_build(_):
    for lanes, b in BUILDS.items():
        extra = f"-DPIPE_NLANES_OVERRIDE={lanes}" if lanes != 1 else ""
        tgts = [t[0] for k, t in TBS.items() if not (k == "msgbus_mac" and lanes != 1)]
        subprocess.run(["make", "-C", IV, f"BUILD={b}", f"IVEXTRA={extra}"] + tgts, check=True)


def make_job(i, rng, seed_base, x4_pct):
    tb = rng.choices(list(TBS), weights=[t[3] for t in TBS.values()])[0]
    lanes = 4 if tb != "msgbus_mac" and rng.random() * 100 < x4_pct else 1
    return {"id": f"i{i:05d}", "config": f"iv-{tb}" + ("-x4" if lanes == 4 else ""), "tb": tb,
            "lanes": lanes, "seed": rng.randrange(1, 2**30), "args": {}}


def run_job(job, outdir, timeout):
    d = os.path.join(outdir, job["id"])
    os.makedirs(d, exist_ok=True)
    tb, lanes = job["tb"], job["lanes"]
    binp = vvp_path(tb, lanes)
    rec = {k: job[k] for k in ("id", "config", "seed", "args")}
    if not os.path.exists(binp):
        return dict(rec, status="BUILD_MISSING", signature="BUILD_MISSING", dir=d)
    cmd = ["vvp", binp, f"+seed={job['seed']}"]
    if tb == "scen":
        cmd.append("+results=" + os.path.join(d, "results.json"))
    timed_out, rc, text = False, 0, ""
    try:
        p = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=timeout)
        rc, text = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        timed_out, rc = True, -1
        text = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    xrc = 0
    if not timed_out and rc == 0 and tb == "scen" and os.path.exists(os.path.join(d, "results.json")):
        x = subprocess.run([sys.executable, XCHK, os.path.join(d, "results.json")], capture_output=True, text=True)
        xrc, text = x.returncode, text + x.stdout
    marker = TBS[tb][2]
    ok = rc == 0 and xrc == 0 and not timed_out and marker in text and "FAIL" not in text
    with open(os.path.join(d, "run.log"), "w") as f:
        f.write(" ".join(cmd) + "\n" + text)
    sig = "" if ok else (signature(text, rc or xrc, timed_out) or f"NO_{marker.replace(' ', '_')}")
    # repro: re-run from the repo root (build first with `rr_iv.py build`)
    repro = f"vvp {os.path.relpath(binp, ROOT)} +seed={job['seed']}" + (" +results=/tmp/r.json" if tb == "scen" else "")
    return dict(rec, status="PASS" if ok else "FAIL", rc=rc or xrc, dir=d, signature=sig, cmd=repro)


def cmd_run(a):
    out = a.out or os.path.join(HERE, "runs", datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-iv")
    os.makedirs(out, exist_ok=True)
    seed_base = a.seed_base if a.seed_base is not None else random.SystemRandom().randrange(1, 2**30)
    rng = random.Random(seed_base)
    jobs = [make_job(i, rng, seed_base, a.x4) for i in range(a.n)]
    path = os.path.join(out, "results.jsonl")
    nfail = 0
    with cf.ThreadPoolExecutor(a.jobs) as ex, open(path, "w") as f:
        for r in ex.map(lambda j: run_job(j, out, a.timeout), jobs):
            f.write(json.dumps(r) + "\n")
            f.flush()
            nfail += r["status"] != "PASS"
    print(f"rr_iv run: {a.n} jobs, {nfail} failing, seed_base={seed_base}, out={out}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("build")
    r = sp.add_parser("run")
    r.add_argument("--n", type=int, default=30)
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--seed-base", type=int)
    r.add_argument("--out")
    r.add_argument("--timeout", type=int, default=600)
    r.add_argument("--x4", type=int, default=35, help="percent of jobs built with PIPE_NLANES_OVERRIDE=4")
    a = ap.parse_args()
    return {"build": cmd_build, "run": cmd_run}[a.cmd](a) or 0


if __name__ == "__main__":
    sys.exit(main())
