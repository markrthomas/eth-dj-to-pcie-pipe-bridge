# metrics — performance & coverage dashboard

Append-only SQLite (`schema.sql` -> `metrics.db`) written by `collect.py`, rendered
to `dashboard.html` by `dashboard.py`. Every value carries a `kind`
(measured/estimated/not_attributable) — never fabricate a measured number. Ported from
axi-on-ucie-to-mem/metrics at M7 (docs/PLAN.md T7.2).
