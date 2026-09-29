# metrics — DV metrics database + dashboard

- `schema.sql` — append-only SQLite schema (`runs`, `metrics`). Every metric row has
  a `kind`: **measured** (read from an artifact of that run), **estimated**
  (computed from design parameters or a pre-synthesis elaboration) or
  **not_attributable** (no data source: value NULL, `detail` says why).
- `collect.py` — `make metrics` runs and wall-clock-times `METRICS_FLOWS`
  (default `regress,coverage,systemc,cocotb,formal,upf-tb`; add `uvm` if a
  UVM-capable Verilator is on PATH), then parses the real artifacts (test logs,
  env `results.json`, coverage summary, `fcov.json`, formal status files, a Yosys
  coarse elaboration for flop/memory bits). A missing artifact is stored as
  `NOT_RUN`, never filled in. Exit 1 if any row is FAIL.
- `dashboard.py` — `make dashboard` renders `metrics.db` -> `dashboard.html`
  (static, no external assets; latest run in full + run history).
- `metrics.db` and `dashboard.html` are committed; `_capture/` is scratch.

Known gaps (recorded as not_attributable): Eth->Eth latency (no monitor yet),
Fmax/area (no liberty / STA), swarm agent x model (no swarm run recorded).
Collecting without `--run` reads whatever artifacts are on disk, which may be
from an older build; `make metrics` always reruns the flows first.
