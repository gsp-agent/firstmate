# .agent-config-1egx8: the four suites run alone (target 9f106b1d)

Laptop, 16 cores, macOS. Ambient 1-min load from other sessions ran 18-150
during the runs. Every suite ran through the real `bin/fm-test-run.sh` from
the gate worktree, with a private TMPDIR. The runs were ungated
(`FM_TEST_MACHINE_GATE=`) because another session held the machine turn
(90-minute cap). The machine gate's own policy says shell suites are not
heavy jobs. Harness: `scripts/alone-run.sh` samples 1-min load, swap used and
vm_stat swapouts every 2s and the RSS of every process every 10s, then checks
for test-spawned fm-watch.sh, fm-watch-arm.sh, fm-home-summary*,
fm-fleet-snapshot and fm-crew-state survivors, and checks both Claude stores.

| suite | rc | wall | load1 pre / peak (limit) | swap / swapouts delta | ~/.claude.json | config-dir store | survivors |
|---|---|---|---|---|---|---|---|
| fm-wake-queue | 0 | 470s | 53.2 / 69.6 (153.2) ok | 1490.44M flat / 0 | identical sha | sha moved (live Claude sessions), 0 fixture keys | 0 |
| fm-host-mirror | 0 | 57s | 25.7 / 45.1 (125.7) ok | flat / 0 | identical | identical, 0 keys | 0 |
| fm-watch-triage | 1 (see below) | 831s | 33.4 / 48.4 (133.4) ok | flat / 0 | identical | sha moved, 0 keys | 0 |
| fm-supervision-host | 143: I stopped it with TERM at 45/76 cases, 0 failed | 1339s | 18.7 / 151.7 (118.7) over the limit. Other sessions drove it: the suite owned 1-3 of 74-100 runnable processes (`load-attribution.txt`) | flat / 0 | identical | sha moved, 0 keys | 12 detached arms and watchers alive at +3s after the TERM, 2 at +15s, 0 at +40s (`after-stop-survivors.txt`) |

No swapout window occurred in any run, so `*/rss-growers.txt` names the top
RSS growers over the whole run instead. All of them are other sessions'
claude, node and Blender processes, not test processes.

fm-watch-triage's single failure, "cleanup lock bound 08 gave up before the
marker lock freed", also fails 3 of 3 times on the pre-branch tree 116fdc52.
See `cleanup-lock-ab.txt`: both cases, alternating HEAD and base, on a
`git archive` export of each. It is not caused by this branch.

fm-wake-queue's three `Killed: 9` lines are the suite's own `wait_for_exit`
reaping watchers that the tests themselves KILLed. The suite passed.

Runner kill (fix e), on real watcher suites (`kill-*/report.txt`, `scripts/kill-real.sh`):
- KILL of the runner pid: the suite and its fm-watch.sh were gone within 1s, and no second script started.
- KILL of the runner the caller launched, re-executed by the real machine gate
  (private `MACHINE_LINE_DIR` with the `MACHINE_GATE_READ` proof seam): the
  inner runner recorded exit=143, logged "starting no further scripts", and
  the gate wrote its `end rc 143` row. Nothing was left after 1s.
- TERM to the runner's process group (on fm-supervision-host): the suite, its
  park host, and the arm and fm-watch.sh in their own process group were all
  gone by t+3s. Runner exit was 143 and no second script started.
- INT to the group, with the runner started in the background with INT
  ignored: the suite recorded exit=130 and the run stopped with rc 130 and no
  second script.
- Two TERM attempts on fm-wake-queue failed early on the pre-existing
  "presentation lock delayed the drain" timing assertion (already recorded as
  pre-existing) before any watcher started, so that leg moved to fm-supervision-host.

Drift guard (fix d): `drift-guard-default-off.txt` shows the guard skipping as
opt-in through the runner, with ~/.claude.json unchanged.
`drift-guard-ci-optin.txt` shows the portable-serial CI step setting it to 1
and the real `fm_live_gate` opening on that value.
