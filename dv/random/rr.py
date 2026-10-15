#!/usr/bin/env python3
"""Random-regression runner, triage and replay corpus (dv/random/README.md).

    rr.py build                         build the Verilator binaries (default, fc, nodpr)
    rr.py run [--n N] [--jobs J] [--seed-base S] [--out DIR] [--timeout SEC]
                                        run N random (config, seed) jobs, write DIR/results.jsonl
    rr.py triage DIR                    parse DIR/results.jsonl -> DIR/triage.json (failures clustered
                                        by normalised signature) and print a summary
    rr.py promote DIR CLUSTER_ID [--note TXT]
                                        add a failing cluster's smallest repro to corpus.json (status open)
    rr.py fixed ID --by REF             mark a corpus entry fixed (it must now pass in `replay`)
    rr.py replay [--jobs J]             rerun every corpus entry; exit 1 if a 'fixed' entry fails
                                        (open entries are reported, not gating)

A job = one config (vlt | vlt-fc | vlt-nodpr) + seed + plusargs.  Every job runs in its own
directory with the same binary the `make vlt` / `vlt fc` / `vlt nodpr` targets build, then the
shared golden-model crosscheck (dv/common/crosscheck.py).  No RTL or checker is changed here.
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
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
VLT = os.path.join(ROOT, "dv", "vlt")
XCHK = os.path.join(ROOT, "dv", "common", "crosscheck.py")
CORPUS = os.path.join(HERE, "corpus.json")
TOP = "eth_dj_pipe7_bridge"

BINS = {
    "vlt": os.path.join(VLT, "obj_dir", "V" + TOP),
    "vlt-fc": os.path.join(VLT, "obj_dir_fc", "V" + TOP),
    "vlt-nodpr": os.path.join(VLT, "obj_dir_nodpr", "V" + TOP),
}
WEIGHTS = {"vlt": 5, "vlt-fc": 3, "vlt-nodpr": 2}
# plusargs the harness understands (seed) or is expected to (added by the harness-dev agent, see README)
KNOBS = {"mac_gap": (0, 5, 10, 30, 60, 90), "sink_pct": (100, 90, 50, 20, 5)}


def make_job(i, rng, seed_base):
    cfg = rng.choices(list(WEIGHTS), weights=list(WEIGHTS.values()))[0]
    return {"id": f"j{i:05d}", "config": cfg, "seed": seed_base + i,
            "args": {k: rng.choice(v) for k, v in KNOBS.items()}}


def signature(text, rc, timed_out):
    if timed_out:
        return "TIMEOUT"
    for pat in (r"CROSSCHECK FAIL.*", r"(?i)\berror\b.*", r"(?i)\bfail(?:ed)?\b.*", r"(?i)assert.*", r"(?i)%Error.*"):
        for line in text.splitlines():
            if re.search(pat, line) and "0 error" not in line and "PASS" not in line:
                s = re.sub(r"0x[0-9a-fA-F]+|\b[0-9a-f]{8}\b", "H", line.strip())
                return re.sub(r"\d+", "N", s)[:160]
    return f"EXIT_{rc}" if rc else ""


def run_job(job, outdir, timeout):
    d = os.path.join(outdir, job["id"])
    os.makedirs(os.path.join(d, "logs"), exist_ok=True)
    binp = BINS[job["config"]]
    if not os.path.exists(binp):
        return dict(job, status="BUILD_MISSING", signature="BUILD_MISSING", dir=d)
    cmd = [binp, f"+seed={job['seed']}"] + [f"+{k}={v}" for k, v in job["args"].items()]
    timed_out, rc, text = False, 0, ""
    try:
        p = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=timeout)
        rc, text = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        timed_out, rc = True, -1
        text = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    xrc = 0
    if not timed_out and rc == 0:
        x = subprocess.run([sys.executable, XCHK, os.path.join(d, "logs", "results.json")],
                           capture_output=True, text=True)
        xrc, text = x.returncode, text + x.stdout
    with open(os.path.join(d, "run.log"), "w") as f:
        f.write(" ".join(cmd) + "\n" + text)
    ok = rc == 0 and xrc == 0 and not timed_out
    return dict(job, status="PASS" if ok else "FAIL", rc=rc or xrc, dir=d,
                signature="" if ok else signature(text, rc or xrc, timed_out))


def cmd_build(_):
    for t in ("build", "fc", "nodpr"):
        subprocess.run(["make", "-C", VLT, t], check=True)


def cmd_run(a):
    out = a.out or os.path.join(HERE, "runs", datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(out, exist_ok=True)
    seed_base = a.seed_base if a.seed_base is not None else random.SystemRandom().randrange(1, 2**30)
    rng = random.Random(seed_base)
    jobs = [make_job(i, rng, seed_base) for i in range(a.n)]
    with cf.ThreadPoolExecutor(a.jobs) as ex, open(os.path.join(out, "results.jsonl"), "w") as f:
        for r in ex.map(lambda j: run_job(j, out, a.timeout), jobs):
            f.write(json.dumps(r) + "\n")
            f.flush()
    nfail = sum(1 for _ in open(os.path.join(out, "results.jsonl")) if '"status": "PASS"' not in _)
    print(f"rr run: {a.n} jobs, {nfail} failing, seed_base={seed_base}, out={out}")
    return 0


def load(out):
    return [json.loads(x) for x in open(os.path.join(out, "results.jsonl"))]


def cmd_triage(a):
    res = load(a.dir)
    clusters = {}
    for r in res:
        if r["status"] != "PASS":
            clusters.setdefault((r["config"], r["signature"]), []).append(r)
    tri = []
    for n, ((cfgn, sig), rs) in enumerate(sorted(clusters.items())):
        rs.sort(key=lambda r: (sum(r["args"].values()), r["seed"]))
        tri.append({"cluster": f"c{n}", "config": cfgn, "signature": sig, "count": len(rs),
                    "repro": {k: rs[0][k] for k in ("config", "seed", "args", "dir")},
                    "seeds": [r["seed"] for r in rs][:20]})
    json.dump({"jobs": len(res), "failing": sum(c["count"] for c in tri), "clusters": tri},
              open(os.path.join(a.dir, "triage.json"), "w"), indent=1)
    print(f"rr triage: {len(res)} jobs, {sum(c['count'] for c in tri)} failing, {len(tri)} cluster(s)")
    for c in tri:
        print(f"  {c['cluster']}: x{c['count']} [{c['config']}] {c['signature']}  repro seed={c['repro']['seed']} {c['repro']['args']}")
    return 0


def corpus():
    return json.load(open(CORPUS)) if os.path.exists(CORPUS) else []


def save(c):
    json.dump(c, open(CORPUS, "w"), indent=1)
    open(CORPUS, "a").write("\n")


def cmd_promote(a):
    tri = json.load(open(os.path.join(a.dir, "triage.json")))
    cl = next(c for c in tri["clusters"] if c["cluster"] == a.cluster)
    c = corpus()
    new_id = f"rr{len(c) + 1:04d}"
    r = cl["repro"]
    c.append({"id": new_id, "config": r["config"], "seed": r["seed"], "args": r["args"],
              "signature": cl["signature"], "status": "open", "note": a.note or "", "fixed_by": ""})
    save(c)
    print(f"promoted {a.cluster} -> {new_id}")


def cmd_fixed(a):
    c = corpus()
    e = next(x for x in c if x["id"] == a.id)
    e["status"], e["fixed_by"] = "fixed", a.by
    save(c)


def cmd_replay(a):
    c = corpus()
    out = os.path.join(HERE, "runs", "replay")
    os.makedirs(out, exist_ok=True)
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        rs = list(ex.map(lambda e: (e, run_job({"id": e["id"], "config": e["config"], "seed": e["seed"],
                                                "args": e["args"]}, out, 600)), c))
    bad = 0
    for e, r in rs:
        gate = e["status"] == "fixed" and r["status"] != "PASS"
        bad += gate
        print(f"{e['id']:8} {e['status']:6} {r['status']:5} {'GATE FAIL ' if gate else ''}{e['config']} seed={e['seed']} {r['signature']}")
    print(f"rr replay: {len(c)} corpus entries, {bad} gating failure(s)")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("build")
    r = sp.add_parser("run")
    r.add_argument("--n", type=int, default=30)
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--seed-base", type=int)
    r.add_argument("--out")
    r.add_argument("--timeout", type=int, default=900)
    t = sp.add_parser("triage")
    t.add_argument("dir")
    p = sp.add_parser("promote")
    p.add_argument("dir")
    p.add_argument("cluster")
    p.add_argument("--note")
    f = sp.add_parser("fixed")
    f.add_argument("id")
    f.add_argument("--by", required=True)
    rp = sp.add_parser("replay")
    rp.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    return {"build": cmd_build, "run": cmd_run, "triage": cmd_triage, "promote": cmd_promote,
            "fixed": cmd_fixed, "replay": cmd_replay}[a.cmd](a) or 0


if __name__ == "__main__":
    sys.exit(main())
