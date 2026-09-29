-- metrics.db — append-only run history (docs/PLAN.md §10).  Every metric row
-- carries a kind: 'measured' (read from a real artifact of this run),
-- 'estimated' (computed from design parameters or a generic-gate synthesis, not
-- measured on silicon/a library), or 'not_attributable' (no data source exists;
-- value is NULL and `detail` says why).  Never store a guessed number as measured.
CREATE TABLE IF NOT EXISTS runs (
  run_id     INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_utc     TEXT NOT NULL,
  git_sha    TEXT,
  git_branch TEXT,
  git_dirty  INTEGER,
  host       TEXT,
  tools      TEXT,            -- JSON: tool -> version string
  note       TEXT
);
CREATE TABLE IF NOT EXISTS metrics (
  run_id   INTEGER NOT NULL REFERENCES runs(run_id),
  category TEXT NOT NULL,     -- flow | test | scenario | perf | coverage | formal | resource | swarm
  name     TEXT NOT NULL,
  value    REAL,              -- NULL when kind = not_attributable (or a pure status)
  unit     TEXT,
  status   TEXT,              -- PASS / FAIL / SKIP / NOT_RUN where it applies
  kind     TEXT NOT NULL CHECK (kind IN ('measured', 'estimated', 'not_attributable')),
  source   TEXT,              -- artifact path or command the value came from
  detail   TEXT
);
CREATE INDEX IF NOT EXISTS idx_metrics_run ON metrics(run_id);
