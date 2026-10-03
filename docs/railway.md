# Railway: getting its data back and into the dashboard

The Railway service is a **batch job** (`railway.toml`: nightly cron, restart never). A container
lives for one run and is thrown away, so before this change everything it measured (`metrics.db`,
`dashboard.html`) vanished when it exited. This page describes how that data now leaves the
container, how it is merged into the dashboard, and what was deliberately not done.

## Data flow

```
Railway cron -> container: docker/entrypoint.sh (ci)
                 make metrics + crosscheck + dashboard
                 docker/publish_metrics.sh  --push-->  GitHub branch `metrics-data`
                                                         runs/<UTC>-<sha>/{metrics.db,dashboard.html,run.json}
                                                         latest/{...}
you / a session:  make railway-import  <--fetch--  metrics-data
                   -> metrics/collect.py --import-dir  (merges the runs, host = railway/<service>)
                   -> make dashboard   ("Railway runs" table; headline stays the newest local run)
```

Why GitHub and not the Railway API: the cloud sessions this repo is worked from cannot reach
Railway (`backboard.railway.com` is blocked by the environment's network policy - checked
2026-10-02: no connection), whereas GitHub is reachable; and GitHub gives history, diffs and access
control for free. A Railway Volume would survive restarts but could only be read through Railway.

## What to set on the Railway service (Variables tab, never in the repo or image)

| Variable | For | Notes |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | the swarm (`docker/entrypoint.sh swarm`) | already agreed; `ANTHROPIC_API_KEY` also works |
| `GITHUB_TOKEN` | publishing the results | a **fine-grained** personal access token limited to this one repository, permission *Contents: read and write*, nothing else. The job only ever pushes the branch `metrics-data`; a protection rule / ruleset on `main` keeps the token from touching it |
| `METRICS_FLOWS` (optional) | which flows the nightly run times | default `regress,coverage,systemc,cocotb,uvm,formal,upf-tb` |
| `PUBLISH_REPO`, `PUBLISH_BRANCH` (optional) | override the target | defaults: this repo, `metrics-data` |

Without `GITHUB_TOKEN` the job still runs; `publish_metrics.sh` prints a notice and the results stay
in the container. The token is handed to git as an HTTP header (never in a URL, a git config file or
the log); `run.json` contains only non-secret facts (time, commit, `RAILWAY_SERVICE_NAME`,
`RAILWAY_ENVIRONMENT_NAME`, `RAILWAY_DEPLOYMENT_ID`, exit code, note).

## Using the data

- `make railway-import` fetches `metrics-data`, merges every run not yet in `metrics/metrics.db`
  (repeatable: a run is skipped if its time + commit are already there) and re-renders the dashboard.
- Imported runs keep every row's `kind` / `status` (measured / estimated / not attributable) exactly as
  the container recorded it; nothing is recomputed here.
- The dashboard headline is the newest **non-Railway** run, because a Railway run has no power /
  other local-only rows; Railway runs appear in their own table and in the run history (Host column).
- Look at one run without importing: `git show origin/metrics-data:latest/dashboard.html`.

## Notes from the first real run (2026-10-03)
- The first Railway run worked end to end (build, `regress` PASS in ~23 s, push to `metrics-data`, import).
- `crosscheck` needs all five envs, so with a reduced `METRICS_FLOWS` it can never pass; the entrypoint
  now skips it unless `METRICS_FLOWS` is unset or `RUN_CROSSCHECK=1`.
- **Set the service's restart policy to Never** (service Settings -> Deploy). With a non-zero exit and
  the default policy Railway restarted the container every ~40 s, and each restart published another run
  to `metrics-data` (7 in 4 minutes). `railway.toml` asks for `NEVER`, but the service evidently did not
  apply it; the dashboard setting is the one that counts.
- The image has no `.git`, so the run's commit comes from `RAILWAY_GIT_COMMIT_SHA` (previously empty in
  `metrics.db`). The importer also skips runs it already has under any host (each container DB starts
  with the repo's committed baseline run, which was being re-imported as a Railway run).

## Not done / not tested

- **Nothing here has run on Railway.** The publish script and the importer were tested against a local
  bare git repository (first push creates the orphan branch, second clones and appends, re-import adds
  nothing, headline unchanged); the real GitHub push with a token is untested.
- Deployment status, build and runtime logs, CPU / memory / cost: only the Railway API (a project or
  account token, GraphQL at `backboard.railway.com`) has them. Reading them from a cloud session
  would need `backboard.railway.com` added to the environment's network allow-list and a *read-only*
  token stored as an environment variable (never pasted into a chat). Not set up.
- A concurrent second writer is handled by a rebase-and-retry, but with one nightly cron job there is
  only ever one writer; this was not stress-tested.
