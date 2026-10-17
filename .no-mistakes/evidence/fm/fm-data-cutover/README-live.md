# Live validation: legacy task-data cutover and reused task ids

Code under test: fm/fm-data-cutover @ d75eafaf.

Each scenario minted its own disposable lab home with `bin/fm-lab-home.sh create`.
It ran with `FM_HOME=<lab>`, no `FM_*_OVERRIDE`, `TMUX` unset, and a tmux socket
directory private to the lab.

Real components: the firstmate code (`bin/fm-task-data.py` under its meta lock,
`bin/fm-teardown.sh` for the reused task's own retirement and for the "next
completed task" cycle), python3, tasks-axi, jq, and the machine's dcg (every
expiry `rm`/`rmdir` went through it).

Stand-ins inside each lab, all disposable:
- `gh-axi` answers the lab's own PR fixtures (`lab/prs/<n>`). Any other PR exits 2.
- `glab` answers one merge request (GitLab scenario only).
- `treehouse`, `no-mistakes` and `gh` are no-ops, so no worktree pool or gate run was touched.

Labs and the extracted pre-fix tree were removed after the runs.

Driver: `drive-scenarios.sh <scenario>` with `lab-lib.sh` and `locked-helper.sh`.
Set `ROOT=<tree>` to replay the scenarios on another firstmate tree.

| Transcript | Scenario | Result |
|---|---|---|
| live-reuse-expired.txt | Chip's reuse case. Expired legacy PR 1, reused task-x1 retires at PR 2 through real teardown, new-scratch.bin is staged, then expired by the next teardown. PR 2 and historical evidence are kept. About 4 MiB is reclaimed only at expiry. | pass, 20/20 |
| live-reuse-expired-prefix-826a593a.txt | Same scenario on the pre-fix tree (test-first commit) | fails as Chip reported: warning, nothing staged, 0 KiB reclaimed |
| live-reuse-unexpired.txt | Adversarial: PR 1's hold is still open when the id is reused at PR 2 | pass. Warns "completed row task-x1 changed project or PR", keeps everything whole, teardown exits 0 |
| live-reuse-metadata-less.txt | Reuse with no task record. The cutover pass prepares PR 2 from the current row; closed PR 1 history stays | pass |
| live-ordering.txt | Chip's ordering case. Archived 2026-10-10 row for PR 4365 plus a current undated checked row for PR 4364 | pass. Current project and PR are chosen; current-pr-only.bin survives stage and expiry |
| live-ambiguous.txt | Undated rows naming PR 7 and PR 8 | pass. Folder named, kept whole, never staged |
| live-unread-pr.txt | A PR that cannot be read (exit 2) | pass. Folder named and kept whole; neither the pass nor the teardown fails |
| live-note-only-gitlab.txt | GitLab merge request named only in a continuation note | pass. PR identity comes from the note; MR evidence is kept |
| live-gsp-pr-reader.txt | Real, read-only GitHub reads of groovejones/groove-sight-platform PRs 4364 and 4365 | pass. Exit 0; the old invocation exits 2 with "Missing PR number" |

The `suite-*.log` files hold the focused task-data groups run through `bin/fm-test-run.sh`.
