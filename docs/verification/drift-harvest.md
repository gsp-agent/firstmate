# Drift harvest replay

Audience: maintainer verification.

This record holds the scripted harvest replay of the tests named in its table, which are not all the tests that remove-verdict changes carry.
The pass ran on 2026-10-29.
Red trees were built from kunchenguid/main at two commits because upstream moved during the pass: `7bbf71b4a702f0795941eaabd43f942bb9f42707` for the laptop batches and `05196e30ead54796dfbe986db61abe9d8df9e3d2` for the later mini batches.

For each PR and test, a scratch clone is checked out at that upstream commit.
For the red run, only the PR's test files are overlaid and the suite runs under the shared machine gate (`bash ~/.agent-state/machine-gate.sh run --needs firstmate`).
For the green run, the PR's full diff is then overlaid and the suite runs again.
A test distinguishes upstream from the change when the green run shows the red `not ok` subtest passing, meaning the green suite exits 0 or the green result line at the same position as the red `not ok` line is `ok`.
Red and green run the same test file, so their result lines align until one run stops.

The verdicts are:

- `keep`: a distinguishing subtest, a green exit of 0, and a clean `bin/fm-drift-nightly.sh check` replay of the PR's committed overlay against the same upstream commit.
- `keep-rebase`: a distinguishing subtest by that rule, with a nonzero green exit on a later subtest or a nightly replay that still fails on another line; the PR is a keep for its rebase series, not a plain keep.
- `unproven`: a red `not ok` line is gone from the green run, but the green run never showed that subtest passing, because the green suite stopped at or before that position or its kept log is not available; never keyed and never a remove.
- `remove`: no distinguishing subtest, because the red suite passes on upstream or the green run fails the same `not ok` line.
- `unmeasured`: a suite exit of 124 (timed out) or 75 (never admitted), never a remove.
- `unmeasured-candidate`: not run in the deciding pass because another test on the same PR was taken to have settled that PR's verdict.

A PR stays keyed only when at least one of its rows is `keep` or `keep-rebase`; with neither, one `unproven` row makes the PR unproven, and otherwise it is a remove.
The keep and keep-rebase proofs are keyed in `drift-proof.txt` and `drift-proof/<N>.proof` at the repository root.
Raw replay output stays out of this repository; this table names only the PR, the test file, and the verdict.

| PR | Test | Verdict |
|---|---|---|
| 8 | tests/fm-session-start.test.sh | unproven |
| 11 | tests/fm-watch-arm.test.sh | keep |
| 12 | tests/fm-backend-orca.test.sh | unproven |
| 12 | tests/fm-secondmate-harness.test.sh | remove |
| 12 | tests/fm-spawn-dispatch-profile.test.sh | unmeasured |
| 16 | tests/fm-backlog-atomicity.test.sh | remove |
| 16 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 16 | tests/fm-teardown.test.sh | remove |
| 17 | tests/fm-supervision-host.test.sh | keep |
| 21 | tests/fm-pr-check-security.test.sh | keep-rebase |
| 21 | tests/fm-teardown.test.sh | unproven |
| 22 | tests/fm-test-fixtures.test.sh | unproven |
| 27 | tests/fm-teardown.test.sh | unproven |
| 28 | tests/fm-inbox.test.sh | keep |
| 29 | tests/fm-brief.test.sh | unproven |
| 30 | tests/fm-teardown.test.sh | remove |
| 31 | tests/fm-teardown.test.sh | keep |
| 32 | tests/fm-backend-herdr.test.sh | keep |
| 33 | tests/fm-cursor-guard.test.sh | unproven |
| 35 | tests/fm-brief.test.sh | keep |
| 36 | tests/fm-teardown.test.sh | remove |
| 38 | tests/fm-project-capacity.test.sh | unproven |
| 39 | tests/fm-contributions.test.sh | keep |
| 39 | tests/fm-home-summary-refresh.test.sh | unmeasured |
| 42 | tests/fm-gotmp.test.sh | remove |
| 42 | tests/fm-pi-watch-extension.test.sh | keep-rebase |
| 43 | tests/fm-inbox.test.sh | unmeasured |
| 43 | tests/fm-supervision-host.test.sh | unproven |
| 44 | tests/fm-captain-hold-lifecycle.test.sh | unmeasured-candidate |
| 44 | tests/fm-claude-stop-autoarm.test.sh | keep |
| 45 | tests/fm-project-capacity.test.sh | unproven |
| 47 | tests/fm-dispatch-resolve.test.sh | keep-rebase |
| 49 | tests/fm-test-run.test.sh | unproven |
| 51 | tests/fm-herdr-session-cleanup.test.sh | keep |
| 54 | tests/fm-fleet-snapshot-view.test.sh | keep |
| 55 | tests/fm-control-relaunch.test.sh | unproven |
| 58 | tests/fm-watch-triage.test.sh | keep |
| 59 | tests/fm-update.test.sh | keep |
| 60 | tests/fm-backlog-atomicity.test.sh | unproven |
| 64 | tests/fm-busy-state.test.sh | keep |
| 65 | tests/fm-pi-branch-extension.test.sh | remove |
| 66 | tests/fm-captain-hold-lifecycle.test.sh | unmeasured-candidate |
| 66 | tests/fm-pr-check-security.test.sh | unproven |
| 67 | tests/fm-backlog-atomicity.test.sh | unproven |
| 68 | tests/fm-spawn-dispatch-profile.test.sh | unproven |
| 69 | tests/fm-inactive-reconcile.test.sh | keep |
| 70 | tests/fm-codex-limit-live-e2e.test.sh | remove |
| 70 | tests/fm-control-relaunch.test.sh | unproven |
| 71 | tests/fm-kimi-harness.test.sh | remove |
| 71 | tests/fm-spawn-dispatch-profile.test.sh | unmeasured-candidate |
| 71 | tests/fm-spawn-worker-git-identity.test.sh | unproven |
| 72 | tests/fm-teardown.test.sh | remove |
| 73 | tests/fm-brief.test.sh | remove |
| 73 | tests/fm-ci-workflow.test.sh | keep |
| 78 | tests/fm-inactive-reconcile.test.sh | remove |
| 79 | tests/fm-project-capacity.test.sh | unproven |
| 80 | tests/fm-brief.test.sh | keep |
| 81 | tests/fm-teardown.test.sh | unproven |
| 82 | tests/fm-ask-user-authority.test.sh | unproven |
| 83 | tests/fm-remote-job.test.sh | unproven |
| 84 | tests/fm-live-session.test.sh | unproven |
| 85 | tests/fm-project-capacity.test.sh | unproven |
| 86 | tests/fm-wake-drain-unread-status.test.sh | keep |
| 87 | tests/fm-test-isolation-proof.test.sh | keep |
| 88 | tests/fm-fork-budget.test.sh | keep |
| 89 | tests/fm-lint.test.sh | unproven |
| 90 | tests/fm-brief.test.sh | unproven |
| 91 | tests/fm-supervision-host.test.sh | unproven |
| 93 | tests/fm-daemon.test.sh | keep |
| 94 | tests/fm-brief.test.sh | unproven |
| 95 | tests/fm-pm-live.test.sh | keep |
| 96 | tests/fm-pm-live.test.sh | unproven |
| 96 | tests/fm-watch-checkpoint.test.sh | remove |
| 98 | tests/fm-spawn-defer-slot.test.sh | remove |
| 98 | tests/fm-spawn-orca-worktree.test.sh | unproven |
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
| 110 | tests/fm-watch-recovery-loop.test.sh | unproven |
| 111 | tests/fm-classify-decision-key.test.sh | keep |
| 112 | tests/fm-pr-merge.test.sh | remove |
| 126 | tests/fm-route-due-fork-budget.test.sh | remove |
| 127 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 127 | tests/fm-route-due-fork-budget.test.sh | remove |
| 129 | tests/fm-captain-hold-lifecycle.test.sh | remove |
| 129 | tests/fm-route-due-fork-budget.test.sh | remove |
| 130 | tests/fm-control-relaunch.test.sh | unproven |
| 131 | tests/fm-fork-free-helpers.test.sh | keep |
| 148 | tests/fm-update.test.sh | keep |
| 155 | tests/fm-inbox.test.sh | keep |
| 167 | tests/fm-supervision-host.test.sh | remove |
| 95fb0ba8 (direct push, no PR) | tests/fm-watch-window-fork-budget.test.sh | remove |

The unnumbered window-index commit is a remove on measurement: 10 processes per window per poll with and without the index, and wall time of 19-21 seconds with it against 18-19 seconds without across two runs under Bash 5.3.
The done criteria name a re-land of the window index; the index does not win on this measurement, so the re-land is held for a maintainer decision.

Per-PR verdicts across 79 PRs: keep 27, keep-rebase 3, unproven 31, remove 18, unmeasured 0.

Seven `remove` rows whose suite failed in both runs have no kept log of the deciding run, so their verdict rests on the comparison recorded at replay time: PRs 36, 98, 99, 106, 110, 112 and 167.

Tests still unmeasured after the long retry sit on PRs: 12, 39, 43.
PR 39 carries a deciding verdict from another of its tests; PRs 12 and 43 are unproven and are listed below.

## Not yet measured: not cut until measured

Every PR listed here is still `pending-pr` without a deciding verdict: its own test has no table row, or its rows hold an `unproven` and no `keep` or `keep-rebase`.
PRs 75, 76 and 77 carry no test.

- PR 18: an upstream sync merge; `tests/fm-secondmate-liveness.test.sh`, `tests/fm-secondmate-safety.test.sh` and `tests/fm-self-repo-role.test.sh` equal upstream `7df545bf`'s, and `tests/fm-session-start.test.sh` equals the synced branch's version, so its cut replays them first.
- PR 50: `tests/fm-nm-run-lib.test.sh`, from the PR's merge commit `24b06030`.
- PRs 8, 12, 22, 27, 29, 33, 38, 43, 45, 49, 55, 60, 66, 67, 68, 70, 71, 79, 81, 82, 83, 84, 85, 89, 90, 91, 94, 96, 98, 110 and 130: their green runs never showed the red subtest passing; the tests are their `unproven` table rows, plus any `unmeasured` or `unmeasured-candidate` row on the same PR.

Each listed PR's cut first replays its tests red on upstream and green with the change, and a test that distinguishes makes it a keep.
