---
name: mutation-check
description: Prove a DV environment can fail by applying one small RTL mutation in an isolated worktree, confirming it FAILs for the right reason, and restoring the file exactly. Use before trusting any green result from a DV env.
---
A green run only means something if the env goes red when the DUT is wrong. Do this in your own git
worktree; never mutate `rtl/` in the main checkout, and never run it while another agent shares your tree.

1. Baseline: run the env (`make <env>`) and record the PASS line. If it does not pass unmutated, stop and report that.
2. Mutate ONE thing, small and deterministic. Default: corrupt one byte on 1-byte last beats in
   `rtl/eth_egress.sv`. Note the exact diff (`git diff rtl/`).
3. Rerun the same env. Expected: FAIL. Check the failing check is the one the mutation should trip (scenario,
   field or SVA name in the log), not a harness or build error. A compile error is not a pass for this test.
4. Restore the file exactly (`git checkout -- rtl/<file>`), then confirm `git diff rtl/` is empty and rerun once
   to see PASS again.
5. Report: env, baseline PASS line, mutation diff, failing check with the log path, restore confirmation.

If the mutated run still passes, that is a finding: the env has a hole. Report it; do not tweak the mutation
until something fails, and never weaken or skip a checker to make results look right.
