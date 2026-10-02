#!/usr/bin/env python3
"""Collect one run's metrics into metrics/metrics.db (schema.sql).

  collect.py [--run FLOW,...] [--note TEXT] [--db PATH]

--run  runs the listed root make targets first, each timed with a wall clock
       (kind=measured) and recorded PASS/FAIL.  Default: collect only from the
       artifacts already on disk.  `make metrics` runs
       regress,coverage,systemc,cocotb,formal,upf-tb (add uvm with METRICS_FLOWS).
Then parses real artifacts only:
  dv/iverilog/sim_build/*.log   directed test PASS lines (frames/flits)
  dv/*/logs/results.json, dv/cocotb/results.json, dv/iverilog/sim_build/results.json
  dv/vlt/logs/vlt.log           simulated time -> delivered-throughput (measured, sim time)
  dv/vlt/logs/coverage_summary.json, dv/cocotb/fcov.json
  formal/*_prove/status, formal/*_cover/status
  yosys (pinned OSS CAD Suite, slang) coarse elaboration -> flop/memory bits (estimated)
Anything without a source is stored as kind=not_attributable with value NULL.
An artifact that is missing is recorded as NOT_RUN — never filled in.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "metrics", "metrics.db")
SCHEMA = os.path.join(ROOT, "metrics", "schema.sql")
ENV_RESULTS = {
    "iverilog": "dv/iverilog/sim_build/results.json",
    "vlt": "dv/vlt/logs/results.json",
    "systemc": "dv/systemc/logs/results.json",
    "uvm": "dv/uvm/logs/results.json",
    "cocotb": "dv/cocotb/results.json",
}
TEST_PASS = {  # test -> (log, regex with named groups)
    "smoke": ("dv/iverilog/sim_build/smoke.log", r"SMOKE PASS"),
    "tx": ("dv/iverilog/sim_build/tx.log", r"TX PASS: (?P<frames>\d+) frames, (?P<flits>\d+) flits"),
    "loop": ("dv/iverilog/sim_build/loop.log", r"LOOP PASS: (?P<frames>\d+) frames, (?P<flits>\d+) flits"),
    "pm": ("dv/iverilog/sim_build/pm.log", r"PM PASS: (?P<frames>\d+) frames .*?, (?P<flits>\d+) flits"),
    "rxovf": ("dv/iverilog/sim_build/rxovf.log", r"RXOVF PASS: (?P<frames>\d+) frames sent"),
    "scen": ("dv/iverilog/sim_build/scen.log", r"SCEN PASS"),
    "upf-tb": ("lp/sim_build/upf_tb.log", r"UPF-TB PASS: (?P<frames>\d+) frames"),
}
RTL = ["async_fifo", "tx_ingress_gate", "tx_framer", "tx_egress", "rx_ingress", "rx_deframer",
       "eth_egress", "pipe_msgbus", "msgbus_mac_tgt", "fc_ctl", "bridge_ctrl_fsm", "bridge_rf",
       "eth_dj_pipe7_bridge"]


class Run:
    def __init__(self, con, run_id):
        self.con, self.run_id, self.n = con, run_id, 0

    def add(self, category, name, value=None, unit=None, kind="measured", status=None, source=None, detail=None):
        assert kind in ("measured", "estimated", "not_attributable")
        if kind == "not_attributable":
            value = None
        self.con.execute("INSERT INTO metrics VALUES (?,?,?,?,?,?,?,?,?)",
                         (self.run_id, category, name, value, unit, status, kind, source, detail))
        self.n += 1


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception:
        return ""


def tool_versions():
    v = {}
    for name, cmd in [("iverilog", "iverilog -V 2>&1 | head -1"), ("verilator", "verilator --version"),
                      ("yosys", "yosys -V"), ("sby", "sby --version 2>/dev/null || echo present"),
                      ("python", "python3 --version"),
                      ("cocotb", "python3 -c 'import cocotb;print(cocotb.__version__)'")]:
        out = sh(cmd)
        v[name] = out.splitlines()[0] if out else "not found"
    return v


def rel(p):
    return os.path.join(ROOT, p)


def run_flows(r, flows):
    for f in flows:
        t0 = time.monotonic()
        res = subprocess.run(["make", f], cwd=ROOT, capture_output=True, text=True)
        dt = time.monotonic() - t0
        st = "PASS" if res.returncode == 0 else "FAIL"
        r.add("flow", f"make {f}", round(dt, 2), "s", "measured", st, "wall clock around `make`",
              None if st == "PASS" else res.stdout[-400:] + res.stderr[-400:])
        print(f"collect: make {f}: {st} in {dt:.1f} s")


def tests(r):
    for t, (log, rx) in TEST_PASS.items():
        p = rel(log)
        if not os.path.exists(p):
            r.add("test", t, None, None, "not_attributable", "NOT_RUN", log, "log not found (test not run)")
            continue
        txt = open(p, errors="replace").read()
        m = re.search(rx, txt)
        if not m:
            r.add("test", t, None, None, "measured", "FAIL", log, "PASS line not found")
            continue
        gd = m.groupdict()
        r.add("test", t, float(gd["frames"]) if gd.get("frames") else None,
              "frames" if gd.get("frames") else None, "measured", "PASS", log,
              f"flits={gd['flits']}" if gd.get("flits") else None)


def scenarios(r):
    sys.path.insert(0, rel("dv/common"))
    import scenarios as sc  # noqa: E402
    exp = sc.expected()
    for env, path in ENV_RESULTS.items():
        p = rel(path)
        if not os.path.exists(p):
            r.add("scenario", f"{env}", None, None, "not_attributable", "NOT_RUN", path, "results.json not found")
            continue
        d = json.load(open(p))["scenarios"]
        ok = all(d.get(s, {}).get(k) is not None and str(d[s][k]) == str(exp[s][k])
                 for s in sc.ORDER for k in exp[s])
        nbytes = sum(d[s]["bytes"] for s in d)
        r.add("scenario", f"{env}", float(len(d)), "scenarios", "measured", "PASS" if ok else "FAIL", path,
              f"{nbytes} bytes delivered; {'matches' if ok else 'DIFFERS FROM'} golden model")


def perf(r):
    log, res = rel("dv/vlt/logs/vlt.log"), rel("dv/vlt/logs/results.json")
    if os.path.exists(log) and os.path.exists(res):
        m = re.search(r"sim time ([\d.]+) us", open(log).read())
        # bytes of the 5 cross-check scenarios only; the vlt run also contains 2
        # coverage-only scenarios, so the sim time below includes them -> a floor
        nbytes = sum(v["bytes"] for v in json.load(open(res))["scenarios"].values())
        if m:
            us = float(m.group(1))
            r.add("perf", "delivered_eth_throughput_vlt_run", round(nbytes * 8 / (us * 1e3), 3), "Gb/s",
                  "measured", None, "dv/vlt/logs/vlt.log + results.json",
                  f"{nbytes} B over {us} us of simulated time (eth_clk 200 MHz, pclk 500 MHz), including "
                  "resets, control ops, idle and the coverage-only scenarios: a whole-run average, not a peak")
    else:
        r.add("perf", "delivered_eth_throughput_vlt_run", kind="not_attributable", status="NOT_RUN",
              source="dv/vlt/logs", detail="vlt env not run")
    # design-parameter bound (not measured)
    raw = 64 * 500e6 / 1e9
    r.add("perf", "pipe_tx_raw_bw_bound", raw, "Gb/s", "estimated", None, "eth_dj_pipe7_pkg.sv",
          "PIPE_BUS_W=64 x 500 MHz (DV clock), x1 lane; ignores the single-buffered framer and flit overhead")
    r.add("perf", "flit_payload_efficiency", round(240 / 256, 4), "ratio", "estimated", None,
          "eth_dj_pipe7_pkg.sv", "FLIT_PAYLOAD_B / FLIT_BYTES")
    r.add("perf", "latency_eth_to_eth", kind="not_attributable", source=None,
          detail="no latency monitor in any env yet")
    r.add("perf", "fmax", kind="not_attributable", detail="no timing library / STA in this flow")


def coverage(r):
    p = rel("dv/vlt/logs/coverage_summary.json")
    if os.path.exists(p):
        d = json.load(open(p))
        r.add("coverage", "line_branch_rtl", d["line_branch_pct"], "%", "measured", None, "dv/vlt/logs/coverage_summary.json",
              f"{d['line_branch_hit']}/{d['line_branch_total']} Verilator line+branch points in rtl/ (floor 80%)")
        r.add("coverage", "toggle_rtl", d["toggle_pct"], "%", "measured", None, "dv/vlt/logs/coverage_summary.json",
              f"{d['toggle_hit']}/{d['toggle_total']} (not gated)")
        cv = d.get("sva_covers", {})
        if cv:
            hit = sum(1 for v in cv.values() if v)
            r.add("coverage", "sva_covers_hit", float(hit), f"of {len(cv)}", "measured", None,
                  "dv/vlt/logs/coverage_summary.json",
                  "unhit: " + (", ".join(k.split(".")[-1] for k, v in cv.items() if not v) or "none"))
    else:
        r.add("coverage", "line_branch_rtl", kind="not_attributable", status="NOT_RUN", source="dv/vlt/logs",
              detail="make coverage not run")
    p = rel("dv/cocotb/fcov.json")
    if os.path.exists(p):
        d = json.load(open(p))
        r.add("coverage", "functional_pyvsc", d["overall"], "%", "measured", None, "dv/cocotb/fcov.json",
              "mean of coverpoint coverage over " + ", ".join(d["covergroups"]))
    else:
        r.add("coverage", "functional_pyvsc", kind="not_attributable", status="NOT_RUN", source="dv/cocotb/fcov.json",
              detail="cocotb env not run")


def formal(r):
    for sby in sorted(glob.glob(rel("formal/*.sby"))):
        base = os.path.splitext(os.path.basename(sby))[0]
        for task in ("prove", "cover"):
            st = rel(f"formal/{base}_{task}/status")
            if os.path.exists(st):
                s = open(st).read().split()
                r.add("formal", f"{base}.{task}", None, None, "measured", s[0] if s else "?",
                      f"formal/{base}_{task}/status")
            else:
                r.add("formal", f"{base}.{task}", kind="not_attributable", status="NOT_RUN",
                      source=f"formal/{base}_{task}/status", detail="make formal not run")


def resource(r):
    has_slang = bool(shutil.which("yosys")) and subprocess.run(
        ["yosys", "-q", "-p", "plugin -i slang"], cwd=ROOT, capture_output=True).returncode == 0
    if not has_slang:
        r.add("resource", "generic_cells", kind="not_attributable", status="NOT_RUN",
              detail="yosys with the slang plugin (pinned OSS CAD Suite) not on PATH")
        return
    srcs = " ".join(f"rtl/{m}.sv" for m in RTL)
    net = os.path.join(ROOT, "metrics", "_capture", "netlist.json")
    os.makedirs(os.path.dirname(net), exist_ok=True)
    # coarse elaboration only (a full `synth` of the 256-bit datapath takes > 10 min)
    cmd = ["yosys", "-q", "-p",
           f"plugin -i slang; read_slang --single-unit -I rtl --top eth_dj_pipe7_bridge "
           f"rtl/eth_dj_pipe7_pkg.sv {srcs}; proc; flatten; opt -fast; memory -nomap; opt_clean; "
           f"write_json {net}"]
    t0 = time.monotonic()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=1800)
    dt = time.monotonic() - t0
    if res.returncode != 0 or not os.path.exists(net):
        r.add("resource", "flop_bits", kind="not_attributable", status="FAIL", source="yosys",
              detail="yosys elaboration failed: " + res.stderr[-300:])
        return
    m = json.load(open(net))["modules"]["eth_dj_pipe7_bridge"]
    ff = mem = 0
    for c in m["cells"].values():
        t, p = c["type"], c["parameters"]
        if "dff" in t.lower():
            ff += int(p["WIDTH"], 2)
        if t.startswith("$mem"):
            mem += int(p["WIDTH"], 2) * int(p["SIZE"], 2)
    src = "yosys (slang) proc/flatten/opt/memory -nomap, coarse cells"
    r.add("resource", "flop_bits", float(ff), "bits", "estimated", None, src,
          f"sum of $dff/$adff widths after coarse elaboration ({dt:.0f} s); pre-optimisation, no liberty")
    r.add("resource", "memory_bits", float(mem), "bits", "estimated", None, src,
          "CDC FIFO arrays (2 x 32 entries)")
    r.add("resource", "coarse_cells", float(len(m["cells"])), "cells", "estimated", None, src,
          "RTLIL coarse cells (word-level), not gates")
    r.add("resource", "area_um2", kind="not_attributable",
          detail="not in the default flow; mapped area is in the 'power' section (OSS flow: make -C lp/oss power-oss)")


OSS_BUILD = os.path.join("lp", "oss", "build")
PD_DP_INST = ["u_tx_gate", "u_tx_cdc", "u_tx_framer", "u_tx_egress", "u_rx_ingress", "u_rx_deframer",
              "u_rx_cdc", "u_eth_egress"]          # PD_DP of lp/bridge.upf; everything else is PD_AON


def power(r):
    """Area + power from the zero-cost OSS flow (lp/oss): Yosys -> Nangate45 liberty -> Verilator GLS ->
    OpenSTA report_power.  Always kind=estimated (45 nm typical corner, no placement/parasitics/clock tree)."""
    stat = os.path.join(ROOT, OSS_BUILD, "stat.txt")
    pj = os.path.join(ROOT, OSS_BUILD, "power.json")
    why = "run `make -C lp/oss power-oss` (needs network + ~10 GB RAM, ~30 min)"
    src_a = rel(stat) if os.path.exists(stat) else None
    if not src_a:
        r.add("power", "area_um2", kind="not_attributable", status="NOT_RUN", source=OSS_BUILD, detail="no stat.txt: " + why)
    else:
        txt = open(stat).read()
        tot = re.search(r"Chip area for top module '\\eth_dj_pipe7_bridge': ([0-9.]+)", txt)
        seqs = re.findall(r"of which used for sequential elements: ([0-9.]+) \(([0-9.]+)%\)", txt)
        seq = seqs[-1] if seqs else None          # the last one is the top module's hierarchical total
        note = "Yosys abc/dfflibmap to the Nangate45 liberty, hierarchy kept; no placement/routing"
        if tot:
            r.add("power", "area_um2", float(tot.group(1)), "um2", "estimated", None, src_a, note)
        if seq:
            r.add("power", "area_sequential_um2", float(seq[0]), "um2", "estimated", None, src_a,
                  f"{seq[1]}% of total (flops only; no retention / clock-gate cells modelled)")
        dp = aon = 0.0
        for m in re.finditer(r"^\s+1\s+([0-9.eE+]+)\s+\S+\$eth_dj_pipe7_bridge\.(u_\w+)\s*$", txt, re.M):
            a, inst = float(m.group(1)), m.group(2)
            r.add("power", f"area_um2.{inst}", a, "um2", "estimated", None, src_a, "per instance (submodule area)")
            if inst in PD_DP_INST:
                dp += a
            else:
                aon += a
        if dp or aon:
            r.add("power", "area_um2.PD_DP", dp, "um2", "estimated", None, src_a,
                  "sum of the PD_DP instances of lp/bridge.upf (sizing for full retention / a header switch)")
            r.add("power", "area_um2.PD_AON", aon, "um2", "estimated", None, src_a, "sum of the other instances (top glue excluded)")
    if not os.path.exists(pj):
        r.add("power", "total_mW", kind="not_attributable", status="NOT_RUN", source=OSS_BUILD, detail="no power.json: " + why)
        return
    d = json.load(open(pj))
    clk = d.get("clocks", {})
    note = (f"OpenSTA report_power, Nangate45 typical, pclk {clk.get('pclk_ns')} ns / eth_clk {clk.get('eth_clk_ns')} ns; "
            f"activity = GLS VCD {d.get('vcd')} (traffic-heavy window of the vlt scenario run)")
    w = d.get("design_W", {})
    for k, n in (("total", "total_mW"), ("internal", "internal_mW"), ("switching", "switching_mW"), ("leakage", "leakage_mW")):
        if k in w:
            r.add("power", n, w[k] * 1e3, "mW", "estimated", None, rel(pj), note)
    dp = aon = 0.0
    for inst, v in sorted(d.get("instances_W", {}).items()):
        if "total" not in v:
            continue
        r.add("power", f"mW.{inst}", v["total"] * 1e3, "mW", "estimated", None, rel(pj), "per instance")
        if inst in PD_DP_INST:
            dp += v["total"] * 1e3
        else:
            aon += v["total"] * 1e3
    if "total" in w:
        r.add("power", "mW.PD_DP", dp, "mW", "estimated", None, rel(pj),
              "sum of PD_DP instances; with power gating this is the part that can be switched off in P1/P2")
        r.add("power", "mW.PD_AON_and_glue", w["total"] * 1e3 - dp, "mW", "estimated", None, rel(pj),
              "rest of the design (always-on instances + top-level glue + clock network not attributed)")
        if "leakage" in w and "leakage" in w:
            lk = sum(v.get("leakage", 0.0) for i, v in d.get("instances_W", {}).items() if i in PD_DP_INST and "leakage" in v)
            r.add("power", "leakage_mW.PD_DP", lk * 1e3, "mW", "estimated", None, rel(pj),
                  "upper bound of what power-gating PD_DP saves in P1/P2 (header-switch leakage / retention flops not modelled)")


def swarm(r):
    p = rel("docker/last-run-metrics.json")
    if os.path.exists(p):
        d = json.load(open(p))
        for row in d.get("agents", []):
            r.add("swarm", f"{row.get('agent')}x{row.get('model')}", row.get("tokens"), "tokens", "measured",
                  row.get("status"), "docker/last-run-metrics.json")
    else:
        r.add("swarm", "agent_x_model", kind="not_attributable", status="NOT_RUN",
              detail="no swarm run recorded (docker/last-run-metrics.json absent)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="", help="comma-separated root make targets to run and time first")
    ap.add_argument("--note", default="")
    ap.add_argument("--db", default=DB)
    ap.add_argument("--power-into-latest", action="store_true",
                    help="only (re)write the 'power' rows of the latest run from lp/oss/build (the OSS power flow is "
                         "~30 min / ~10 GB, so it is not part of `make metrics`)")
    a = ap.parse_args()
    con = sqlite3.connect(a.db)
    con.executescript(open(SCHEMA).read())
    if a.power_into_latest:
        row = con.execute("SELECT MAX(run_id) FROM runs").fetchone()
        if not row or row[0] is None:
            print("collect: no run in the database to attach power rows to")
            return 1
        con.execute("DELETE FROM metrics WHERE run_id=? AND category='power'", (row[0],))
        r = Run(con, row[0])
        power(r)
        con.commit()
        print(f"collect: run {row[0]}: {r.n} power rows written -> {os.path.relpath(a.db, ROOT)}")
        return 0
    dirty = 1 if sh("git status --porcelain --untracked-files=no") else 0
    cur = con.execute("INSERT INTO runs (ts_utc, git_sha, git_branch, git_dirty, host, tools, note) VALUES (?,?,?,?,?,?,?)",
                      (datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       sh("git rev-parse --short HEAD"), sh("git rev-parse --abbrev-ref HEAD"), dirty,
                       os.uname().nodename, json.dumps(tool_versions()), a.note))
    r = Run(con, cur.lastrowid)
    if a.run:
        run_flows(r, [f for f in a.run.split(",") if f])
    tests(r)
    scenarios(r)
    perf(r)
    coverage(r)
    formal(r)
    resource(r)
    power(r)
    swarm(r)
    con.commit()
    bad = con.execute("SELECT COUNT(*) FROM metrics WHERE run_id=? AND status='FAIL'", (r.run_id,)).fetchone()[0]
    print(f"collect: run {r.run_id}: {r.n} metric rows -> {os.path.relpath(a.db, ROOT)} ({bad} FAIL)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
