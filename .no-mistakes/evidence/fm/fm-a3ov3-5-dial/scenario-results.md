# Live lab results: project-capacity headroom admission (c19ce654)

Lab: marked disposable FM_HOME (bin/fm-lab-home.sh) with a local secondmate home, three
lab projects with local origins, real `bin/fm-spawn.sh` from the gate worktree, real tmux on
a private `fm-lab` socket, real treehouse with TREEHOUSE_ROOT inside the lab, real tasks-axi
markdown backlogs. Each worker is a raw launch command (`worker.sh run`: logs its start, then
sleeps), so every admitted start is a real process in a real pane. Readings: the real shared
`node ~/dev/agent-observer/machine-headroom.mjs`, plus lab programs that print a reading line
and exit 0 (room) or 1 (no room), each logging when it runs. Full output: live-lab-transcript.txt.

| # | Scenario | Observed |
|---|----------|----------|
| S1 | Off switch: no headroom file, then a blank one; project full (1 of 1) | exit 75, message identical to the pre-change deferral (no headroom/no room/window text); no record, no window, item still Queued |
| S2 | Share start with a denying reading configured (capacity raised to 2) | lab-b launched (exit 0); denying reading ran 0 times |
| S5 | Full (2 of 2), reading exits 1 | exit 75 "...The headroom reading reported no room."; reading ran once; reading line not logged; no extra-start record |
| S8a | Admitted extra start whose brief still has {TASK} | "headroom:" logged, then exit 1 "still contains {TASK}"; no task record and no extra-start record left (window still open) |
| S3a | Real shared reading, machine busy (load 20-50) | 14 spawns: each real reading exited 1 (idle 0.0-24.9%), each spawn exit 75 "no room"; record never written by a no-room reading |
| S3b | Real shared reading, from the secondmate home, once idle reached 30.9% | "headroom: cpu_idle_pct=30.9 load1=30.47 disk_free_gb=535.6", lab3-m launched; record written in the ROOT home only |
| S4 | Room reading at capacity, then a second extra start | lab-c launched, record epoch written; next spawn exit 75 "...already started one worker past that count in the current window."; reading not run again |
| S7 | Same project, real time: at 382 s still deferred; at 429 s admitted | 382 s: exit 75 spent, reading not run; 429 s: lab-x launched, reading ran once, new epoch recorded |
| S8b | Extra start whose launch is sent, then tasks-axi start fails twice (fault injected by a PATH shim) | worker lab2-d started and still running; task record removed; extra-start record KEPT with the new epoch; next extra start exit 75 "spent", reading not run |
| S9 | Two dispatches of one full project in one home at once | one admitted (reading ran once); the other refused exit 1 by the home's task-set lock; one extra-start record |
| S10 | Root home and its secondmate home dispatch one full project at once | root admitted; mate refused exit 1 "another Treehouse slot allocation ... refusing to race it" (shared project lock held during the reading); mate retry in the window: exit 75 spent, reading not run |
| S6 | Running work never stopped | all 10 launched workers (incl. the S8b one) still running `sleep` after every admission and deferral; each started exactly once |

Targeted suite: `bash tests/fm-project-capacity.test.sh` -> 26 ok, exit 0 (fm-project-capacity.test.log).
