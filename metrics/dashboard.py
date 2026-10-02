#!/usr/bin/env python3
"""Render metrics/metrics.db -> metrics/dashboard.html (static, no external assets).

  dashboard.py [--db PATH] [--out PATH]

Shows the latest run in full (every value with its kind badge: measured /
estimated / not attributable) and a history table of all runs.  Values are
printed exactly as stored; nothing is computed or filled in here.
"""
import argparse
import html
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTIONS = [
    ("flow", "Flows (wall clock)"),
    ("test", "Directed tests (Icarus)"),
    ("scenario", "Shared scenario set: env vs golden model"),
    ("coverage", "Coverage"),
    ("formal", "Formal (SymbiYosys)"),
    ("perf", "Performance"),
    ("resource", "Resource (pre-synthesis estimate)"),
    ("power", "Power &amp; area (Nangate45 liberty, OSS flow \u2014 estimate)"),
    ("swarm", "Agent swarm (agent x model)"),
]
CSS = """
:root { --bg:#ffffff; --fg:#1d2127; --muted:#5b6470; --line:#dfe3e8; --card:#f6f8fa;
        --ok:#1a7f37; --bad:#cf222e; --na:#6e7781; --meas:#0969da; --est:#9a6700; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8d96a0; --line:#30363d; --card:#161b22;
          --ok:#3fb950; --bad:#f85149; --na:#8d96a0; --meas:#58a6ff; --est:#d29922; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
       font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
main { max-width:1100px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:16px; margin:28px 0 8px; }
.meta { color:var(--muted); margin-bottom:8px; }
.wrap { overflow-x:auto; }
table { border-collapse:collapse; width:100%; background:var(--card); border:1px solid var(--line); }
th,td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
th { font-weight:600; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.03em; }
td.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
td.detail { color:var(--muted); font-size:12px; }
.badge { display:inline-block; padding:1px 7px; border-radius:10px; font-size:11px; border:1px solid currentColor; white-space:nowrap; }
.k-measured { color:var(--meas); } .k-estimated { color:var(--est); } .k-not_attributable { color:var(--na); }
.s-PASS { color:var(--ok); font-weight:600; } .s-FAIL { color:var(--bad); font-weight:600; }
.s-NOT_RUN, .s-SKIP { color:var(--na); }
.note { color:var(--muted); font-size:12px; margin-top:6px; }
code { font-size:12px; }
"""


def fmt(v):
    if v is None:
        return "&mdash;"
    if float(v).is_integer():
        return f"{int(v):,}"
    return f"{v:,.3f}".rstrip("0").rstrip(".")


def section(con, run_id, cat):
    rows = con.execute("SELECT name, value, unit, status, kind, source, detail FROM metrics "
                       "WHERE run_id=? AND category=? ORDER BY rowid", (run_id, cat)).fetchall()
    if not rows:
        return "<p class='note'>No rows for this run.</p>"
    out = ["<div class='wrap'><table><tr><th>Metric</th><th>Value</th><th>Status</th><th>Kind</th>"
           "<th>Source / detail</th></tr>"]
    for name, value, unit, status, kind, source, detail in rows:
        val = fmt(value) + (f" {html.escape(unit)}" if unit and value is not None else "")
        st = f"<span class='s-{html.escape(status)}'>{html.escape(status)}</span>" if status else ""
        src = html.escape(source or "")
        det = html.escape(detail or "")
        out.append(f"<tr><td><code>{html.escape(name)}</code></td><td class='num'>{val}</td><td>{st}</td>"
                   f"<td><span class='badge k-{kind}'>{kind.replace('_', ' ')}</span></td>"
                   f"<td class='detail'>{src}{'<br>' if src and det else ''}{det}</td></tr>")
    out.append("</table></div>")
    return "\n".join(out)


def history(con):
    runs = con.execute("SELECT run_id, ts_utc, git_sha, git_branch, git_dirty, note, host FROM runs "
                       "ORDER BY run_id DESC").fetchall()
    out = ["<div class='wrap'><table><tr><th>Run</th><th>UTC</th><th>Host</th><th>Commit</th><th>PASS</th><th>FAIL</th>"
           "<th>Not run</th><th>Line+branch %</th><th>Note</th></tr>"]
    for rid, ts, sha, br, dirty, note, host in runs:
        c = dict(con.execute("SELECT status, COUNT(*) FROM metrics WHERE run_id=? AND status IS NOT NULL "
                             "GROUP BY status", (rid,)).fetchall())
        cov = con.execute("SELECT value FROM metrics WHERE run_id=? AND name='line_branch_rtl'", (rid,)).fetchone()
        out.append(f"<tr><td>{rid}</td><td>{html.escape(ts)}</td><td>{html.escape(host or '')}</td><td><code>{html.escape(sha or '')}</code> "
                   f"{html.escape(br or '')}{' (dirty)' if dirty else ''}</td>"
                   f"<td class='num s-PASS'>{c.get('PASS', 0)}</td><td class='num s-FAIL'>{c.get('FAIL', 0)}</td>"
                   f"<td class='num'>{c.get('NOT_RUN', 0)}</td><td class='num'>{fmt(cov[0]) if cov else '&mdash;'}</td>"
                   f"<td class='detail'>{html.escape(note or '')}</td></tr>")
    out.append("</table></div>")
    return "\n".join(out)


def railway(con):
    """Runs imported from the Railway batch job (host railway/<service>): one row per run with the
    flow results and the total wall time of the flows."""
    runs = con.execute("SELECT run_id, ts_utc, git_sha, host FROM runs WHERE host LIKE 'railway/%' "
                       "ORDER BY run_id DESC LIMIT 30").fetchall()
    if not runs:
        return ("<p class='note'>No Railway runs imported yet: the nightly job publishes to the "
                "<code>metrics-data</code> branch (docs/railway.md); import with <code>make railway-import</code>.</p>")
    out = ["<div class='wrap'><table><tr><th>Run</th><th>UTC</th><th>Service</th><th>Commit</th><th>Flows PASS</th>"
           "<th>Flows FAIL</th><th>Flow wall time</th></tr>"]
    for rid, ts, sha, host in runs:
        c = dict(con.execute("SELECT status, COUNT(*) FROM metrics WHERE run_id=? AND category='flow' "
                             "AND status IS NOT NULL GROUP BY status", (rid,)).fetchall())
        wall = con.execute("SELECT SUM(value) FROM metrics WHERE run_id=? AND category='flow'", (rid,)).fetchone()[0]
        out.append(f"<tr><td>{rid}</td><td>{html.escape(ts)}</td><td>{html.escape(host.split('/', 1)[1])}</td>"
                   f"<td><code>{html.escape(sha or '')}</code></td>"
                   f"<td class='num s-PASS'>{c.get('PASS', 0)}</td><td class='num s-FAIL'>{c.get('FAIL', 0)}</td>"
                   f"<td class='num'>{fmt(wall) + ' s' if wall is not None else '&mdash;'}</td></tr>")
    out.append("</table></div>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.path.join(ROOT, "metrics", "metrics.db"))
    ap.add_argument("--out", default=os.path.join(ROOT, "metrics", "dashboard.html"))
    a = ap.parse_args()
    if not os.path.exists(a.db):
        print(f"dashboard: {a.db} not found; run `make metrics` first")
        return 1
    con = sqlite3.connect(a.db)
    # headline = the newest run that is not a Railway import (a Railway run has no power / local-only rows)
    last = con.execute("SELECT run_id, ts_utc, git_sha, git_branch, git_dirty, host, tools, note FROM runs "
                       "WHERE host IS NULL OR host NOT LIKE 'railway/%' ORDER BY run_id DESC LIMIT 1").fetchone() or \
           con.execute("SELECT run_id, ts_utc, git_sha, git_branch, git_dirty, host, tools, note FROM runs "
                       "ORDER BY run_id DESC LIMIT 1").fetchone()
    if not last:
        print("dashboard: no runs in the database")
        return 1
    rid, ts, sha, br, dirty, host, tools, note = last
    tools = json.loads(tools or "{}")
    body = [f"<h1>eth-dj &harr; PIPE 7.1 bridge &mdash; DV metrics</h1>",
            f"<div class='meta'>Latest run {rid} &middot; {html.escape(ts)} &middot; <code>{html.escape(sha or '?')}</code> "
            f"on {html.escape(br or '?')}{' (uncommitted changes)' if dirty else ''} &middot; host {html.escape(host or '?')}"
            f"{' &middot; ' + html.escape(note) if note else ''}</div>",
            "<div class='meta'>Tools: " + " &middot; ".join(f"{html.escape(k)} <code>{html.escape(v)}</code>"
                                                            for k, v in tools.items()) + "</div>",
            "<p class='note'><span class='badge k-measured'>measured</span> read from an artifact of this run &nbsp; "
            "<span class='badge k-estimated'>estimated</span> computed from design parameters or a pre-synthesis "
            "elaboration &nbsp; <span class='badge k-not_attributable'>not attributable</span> no data source; "
            "the gap is recorded instead of a number.</p>"]
    for cat, title in SECTIONS:
        body.append(f"<h2>{title}</h2>")
        body.append(section(con, rid, cat))
    body.append("<h2>Railway runs (nightly batch job)</h2>")
    body.append(railway(con))
    body.append("<h2>Run history</h2>")
    body.append(history(con))
    page = ("<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>Bridge DV Metrics</title><style>{CSS}</style></head><body><main>"
            + "\n".join(body) + "</main></body></html>\n")
    with open(a.out, "w") as fh:
        fh.write(page)
    print(f"dashboard: wrote {os.path.relpath(a.out, ROOT)} (run {rid})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
