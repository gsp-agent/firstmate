# Drift harvest replay

Audience: maintainer verification.

This record holds the scripted harvest replay of every remove-verdict change that carries a test.
Each test ran red on current upstream files and green with its change applied, one suite at a time under the shared machine gate.
A test that distinguishes upstream from the change makes the change a keep.
A keep whose nightly replay still fails on another line is a keep for its rebase series, not a plain keep.
A timed-out or never-admitted run is unmeasured, not a remove verdict.
The keep and keep-rebase proofs are keyed in the drift proof files that sit beside this record's subject scripts.
Raw replay output stays out of this repository; this table names only the PR, the test file, and the verdict.

| PR | Test | Verdict |
|---|---|---|
| 8 | tests/fm-session-start.test.sh | keep-rebase |
| 11 | tests/fm-watch-arm.test.sh | keep |
| 12 | tests/fm-backend-orca.test.sh | keep-rebase |
| 12 | tests/fm-secondmate-harness.test.sh | remove |
| 12 | tests/fm-spawn-dispatch-profile.test.sh | unmeasured |
| 16 | tests/fm-backlog-atomicity.test.sh | remove |
| 16 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 16 | tests/fm-teardown.test.sh | remove |
| 17 | tests/fm-supervision-host.test.sh | keep |
| 21 | tests/fm-pr-check-security.test.sh | keep-rebase |
| 21 | tests/fm-teardown.test.sh | keep-rebase |
| 22 | tests/fm-test-fixtures.test.sh | keep-rebase |
| 27 | tests/fm-teardown.test.sh | keep-rebase |
| 28 | tests/fm-inbox.test.sh | keep |
| 29 | tests/fm-brief.test.sh | keep-rebase |
| 30 | tests/fm-teardown.test.sh | remove |
| 31 | tests/fm-teardown.test.sh | keep |
| 32 | tests/fm-backend-herdr.test.sh | keep |
| 33 | tests/fm-cursor-guard.test.sh | keep-rebase |
| 35 | tests/fm-brief.test.sh | keep |
| 36 | tests/fm-teardown.test.sh | remove |
| 38 | tests/fm-project-capacity.test.sh | keep-rebase |
| 39 | tests/fm-contributions.test.sh | keep |
| 39 | tests/fm-home-summary-refresh.test.sh | unmeasured |
| 42 | tests/fm-gotmp.test.sh | remove |
| 42 | tests/fm-pi-watch-extension.test.sh | keep-rebase |
| 43 | tests/fm-inbox.test.sh | unmeasured |
| 43 | tests/fm-supervision-host.test.sh | keep-rebase |
| 44 | tests/fm-captain-hold-lifecycle.test.sh | unmeasured-candidate |
| 44 | tests/fm-claude-stop-autoarm.test.sh | keep |
| 45 | tests/fm-project-capacity.test.sh | keep-rebase |
| 47 | tests/fm-dispatch-resolve.test.sh | keep-rebase |
| 49 | tests/fm-test-run.test.sh | keep-rebase |
| 51 | tests/fm-herdr-session-cleanup.test.sh | keep |
| 54 | tests/fm-fleet-snapshot-view.test.sh | keep |
| 55 | tests/fm-control-relaunch.test.sh | keep-rebase |
| 58 | tests/fm-watch-triage.test.sh | keep |
| 59 | tests/fm-update.test.sh | keep |
| 60 | tests/fm-backlog-atomicity.test.sh | keep-rebase |
| 64 | tests/fm-busy-state.test.sh | keep |
| 65 | tests/fm-pi-branch-extension.test.sh | remove |
| 66 | tests/fm-captain-hold-lifecycle.test.sh | unmeasured-candidate |
| 66 | tests/fm-pr-check-security.test.sh | keep-rebase |
| 67 | tests/fm-backlog-atomicity.test.sh | keep-rebase |
| 68 | tests/fm-spawn-dispatch-profile.test.sh | keep-rebase |
| 69 | tests/fm-inactive-reconcile.test.sh | keep |
| 70 | tests/fm-codex-limit-live-e2e.test.sh | remove |
| 70 | tests/fm-control-relaunch.test.sh | keep-rebase |
| 71 | tests/fm-kimi-harness.test.sh | remove |
| 71 | tests/fm-spawn-dispatch-profile.test.sh | unmeasured-candidate |
| 71 | tests/fm-spawn-worker-git-identity.test.sh | keep-rebase |
| 72 | tests/fm-teardown.test.sh | remove |
| 73 | tests/fm-brief.test.sh | remove |
| 73 | tests/fm-ci-workflow.test.sh | keep |
| 78 | tests/fm-inactive-reconcile.test.sh | remove |
| 79 | tests/fm-project-capacity.test.sh | keep-rebase |
| 80 | tests/fm-brief.test.sh | keep |
| 81 | tests/fm-teardown.test.sh | keep-rebase |
| 82 | tests/fm-ask-user-authority.test.sh | keep-rebase |
| 83 | tests/fm-remote-job.test.sh | keep-rebase |
| 84 | tests/fm-live-session.test.sh | keep-rebase |
| 85 | tests/fm-project-capacity.test.sh | keep-rebase |
| 86 | tests/fm-wake-drain-unread-status.test.sh | keep |
| 87 | tests/fm-test-isolation-proof.test.sh | keep |
| 88 | tests/fm-fork-budget.test.sh | keep |
| 89 | tests/fm-lint.test.sh | keep-rebase |
| 90 | tests/fm-brief.test.sh | keep-rebase |
| 91 | tests/fm-supervision-host.test.sh | keep-rebase |
| 93 | tests/fm-daemon.test.sh | keep |
| 94 | tests/fm-brief.test.sh | keep-rebase |
| 95 | tests/fm-pm-live.test.sh | keep |
| 96 | tests/fm-pm-live.test.sh | keep-rebase |
| 96 | tests/fm-watch-checkpoint.test.sh | remove |
| 98 | tests/fm-spawn-defer-slot.test.sh | remove |
| 98 | tests/fm-spawn-orca-worktree.test.sh | keep-rebase |
| 99 | tests/fm-spawn-worktree-settle.test.sh | remove |
| 100 | tests/fm-spawn-queue-start.test.sh | remove |
| 101 | tests/fm-backend-herdr-presentation-e2e.test.sh | remove |
| 102 | tests/fm-backend-herdr.test.sh | keep |
| 103 | tests/fm-captain-hold-backfill.test.sh | remove |
| 104 | tests/fm-captain-hold-backfill.test.sh | remove |
| 106 | tests/fm-stock-bash-check.test.sh | remove |
| 107 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 108 | tests/fm-teardown.test.sh | keep |
| 110 | tests/fm-supervision-host.test.sh | remove |
| 110 | tests/fm-watch-recovery-loop.test.sh | keep-rebase |
| 111 | tests/fm-classify-decision-key.test.sh | keep |
| 112 | tests/fm-pr-merge.test.sh | remove |
| 126 | tests/fm-route-due-fork-budget.test.sh | remove |
| 127 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 127 | tests/fm-route-due-fork-budget.test.sh | remove |
| 129 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 129 | tests/fm-route-due-fork-budget.test.sh | remove |
| 130 | tests/fm-control-relaunch.test.sh | keep-rebase |
| 131 | tests/fm-fork-free-helpers.test.sh | keep |
| 148 | tests/fm-update.test.sh | keep |
| 155 | tests/fm-inbox.test.sh | keep |
| 167 | tests/fm-supervision-host.test.sh | remove |
| 95fb0ba8 (direct push, no PR) | tests/fm-watch-window-fork-budget.test.sh | remove |

The unnumbered window-index commit is a remove on measurement: 10 processes per window per poll with and without the index, and wall time of 19-21 seconds with it against 18-19 seconds without across two runs under Bash 5.3.
No re-land follows it.

Per-PR verdicts across 79 PRs: keep 27, keep-rebase 34, remove 18, unmeasured 0.

Tests still unmeasured after the long retry sit on PRs: 12, 39, 43.
Each of those PRs carries a deciding verdict from another of its tests.
