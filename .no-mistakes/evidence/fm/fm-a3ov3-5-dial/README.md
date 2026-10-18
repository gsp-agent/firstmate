# Live validation: project-capacity headroom admission (a3ov3.5, Firstmate half)

All scenarios ran the real `bin/fm-spawn.sh` from the gate worktree, with
`FM_HOME` set to a disposable marked lab home (`bin/fm-lab-home.sh create`). The
lab also had its own private tmux server, a treehouse pool inside the lab
(`TREEHOUSE_ROOT`), real git projects `alpha`, `beta` and `gamma`, each cloned
from a local bare origin, real briefs (`fm-brief.sh`) and a real markdown
backlog (`fm-tasks-axi.sh`). Each worker is a raw launch command (`sleep 3600`)
running in a real tmux window. It holds a place the way any worker does,
through its task record.

`config/project-capacity` declared `alpha 1` and `beta 1`, plus `gamma 0` for
S9. The headroom program is a lab script whose verdict follows a mode file:
room, none, silent, slow or hang. S14 used a reading of this machine instead:
CPU idle from `top`, 1-minute load from `sysctl`, and free disk from `df`.

The 420-second window was crossed by moving the record's epoch 421 s into the
past. The record is a state file that is safe to delete. The window check is
`now < epoch + 420`, so this is exactly the same as waiting.

| # | Scenario | Result | Transcript |
|---|----------|--------|------------|
| S1 | No headroom file: a spawn at the share defers with exit 75 and the old message, creates nothing, and leaves the item queued | pass | transcript-1 |
| S2 | A headroom file with only whitespace counts as off, and the deferral is unchanged | pass | transcript-1 |
| S3 | A reading that exits 1 defers with "reported no room" and writes no record | pass | transcript-1 |
| S3b | A reading that exits 0 with no output is no room | pass | transcript-1 |
| S4 | A reading that reports room admits one extra start: worker launched, `headroom: <line>` logged, record named by alpha's lock identity | pass | transcript-2 |
| S5 | A second extra start in the same window defers as spent, and the reading is not run again | pass | transcript-2 |
| S6 | A share start runs no reading even when the reading would say no room; beta gets its own extra start while alpha's window is spent | pass | transcript-2 |
| S7 | After the window passes, a no-room reading defers without using the window; when room returns, one more extra start is admitted | pass | transcript-3 |
| S9 | A declared count of 0 is not raised: deferred, no reading run | pass | transcript-3 |
| S10 | An extra start that fails before launch (leftover {TASK}) removes its record, so the fixed retry is admitted | pass | transcript-3 |
| S11 | An extra start whose launch was sent and whose `tasks-axi start` then fails twice keeps its record; the next one in that window defers as spent | pass | transcript-4 |
| S12 | A reading that hangs is no room after about 30 s (33 s elapsed), and the window is not used | pass | transcript-4 |
| S13 | Two simultaneous spawns in one home: only one launches | pass | transcript-4 |
| S14 | A reading of this machine (idle 38%, load 65, 534 GB free) admits beta's extra start | pass | transcript-6 |
| S15 | A secondmate home ignores its own headroom copy and uses the root home's; the record lands in the root home's state; the root home's next spawn defers as spent | pass | transcript-5 |
| S16 | A root-home spawn and a secondmate spawn race: one extra start launches; the other exits 1 on the project lock | pass (exit 1 is a known, declined issue) | transcript-5 |
| S8 | Running work is never stopped: every worker window still runs `sleep`, `pane_dead=0`, after all deferrals | pass | transcripts 2-6 window lists |

Scripts: `lab-setup.sh`, `lab-lib.sh`, `scenarios.sh`, `mate-setup.sh` and
`mate-scenarios.sh`. Teardown killed the lab tmux server, removed the lab's
`/tmp/fm-<id>` directories and the lab root, and confirmed that `~/.treehouse`
was unchanged.

A first smoke run, before `TREEHOUSE_ROOT` was set on the lab tmux server,
created one pool entry in `~/.treehouse` (`alpha-ebb781`). It was a lab-only
worktree, and it was removed with `treehouse destroy` followed by removal of
its empty pool directory.
