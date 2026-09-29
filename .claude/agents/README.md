# .claude/agents — swarm agent definitions

Discovered by Claude Code (non-bare) when `docker/swarm.sh` runs in this repo.

| Agent | Model | Role |
|---|---|---|
| `swarm-manager` | inherit | dispatches the others, verifies their claims, reports |
| `dv-env-tester` | sonnet | runs one DV env, cross-check + one mutation |
| `infra-agent` | sonnet | formal, upf-tb, waves, metrics, CI/Docker drift |
| `dv-runner` | haiku | runs a list of commands, reports raw results |

Default task: `../docker/swarm-task.md`. The swarm has not been run from this
repo yet (no run recorded in `metrics/metrics.db`).
