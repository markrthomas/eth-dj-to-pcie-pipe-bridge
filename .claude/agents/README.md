# .claude/agents — swarm agent definitions

Discovered by Claude Code (non-bare) when `docker/swarm.sh` runs in this repo. Model choice = cheapest that does the job:
coordination and mechanical work are cheap, only root-cause debugging gets the big model.

| Agent | Model | Role |
|---|---|---|
| `swarm-manager` | sonnet | verification swarm: dispatches the dv/infra agents, verifies claims, reports |
| `dv-env-tester` | sonnet | runs one DV env, cross-check + one mutation |
| `infra-agent` | sonnet | formal, upf-tb, waves, metrics, CI/Docker drift |
| `dv-runner` | haiku | runs a list of commands, reports raw results |
| `rr-manager` | sonnet | random-regression loop, status board, merges worker branches |
| `rr-runner` | haiku | builds + runs random batches (`make rr`) |
| `rr-triage` | sonnet | clusters failures, DUT vs TB classification |
| `rr-debugger` | opus | root-causes one cluster, fixes TB / writes up DUT |
| `rr-test-author` | sonnet | pins repros in the corpus, grows stimulus |

Default tasks: `../docker/swarm-task.md` (verification), `../docker/rr-swarm-task.md` (random regression).
All agents start from `../CLAUDE.md` + `../docs/INDEX.md` and return "verdict + evidence + next step" (no log dumps).
Sub-agents cannot spawn sub-agents in non-interactive runs, so `docker/swarm.sh` starts the top-level session AS the manager (`--agent swarm-manager`, or `rr-manager` for `rr-swarm-task.md`).
`dv-env-tester`, `rr-debugger` and `rr-test-author` run in their own git worktrees (`isolation: worktree`); shared preloaded skills live in `../skills/` (`board-report`, `mutation-check`). Bash permissions: `../settings.json`.
