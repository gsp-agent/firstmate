## Intent

Bead .agent-config-1egx8 (read it with br from ~/.agent-config; the done and baseline stand: load 49 to 824, 40 GB swapped, a real ~/.claude.json write): the four suites fm-wake-queue, fm-watch-triage, fm-host-mirror and fm-supervision-host run alone on the laptop with no load storm or swap and nothing written outside their temp root. The spec is the muse-solver comment on the bead (fixes a-f, done checks 1-6), among them FM_HOME_SUMMARY_INTERVAL=999999 in the watcher suites with HOME_SUMMARY_PID reaped, FM_POLL 0.2 to 1 and the lock poll 0.02 to 0.1. One PR in gsp-agent/firstmate against upstream-lean. It blocks a3ov3-5-fm's paused alone comparison.

The muse-solver comment's fixes: (a) stop the per-watcher home-summary refresh fan-out in the watcher suites (every fresh fixture lacks home-summary.json, so each watcher starts a detached refresh running fm-fleet-snapshot.sh 8-wide plus the real fm-crew-state.sh, and refreshes outlive killed watchers); (b) poll floors: the FM_POLL=0.2 test sites to 1, lock-wait sleeps 0.02 to 0.1, in bounded loops; (c) liveness sandbox: the wake-queue liveness legs reach the real fm-spawn.sh --secondmate and fm-claude-trust.sh, which write ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, so those legs get a temp HOME and an empty CLAUDE_CONFIG_DIR; (d) fm-harness-liveness-drift-live-e2e, which launches real agent CLIs under the real HOME, becomes opt-in; (e) runner reaping: killing bin/fm-test-run.sh must end the running suite and its watchers instead of leaving them running; (f) defer a ps cache unless (a)-(e) miss done.

Done checks: 1. each of the four suites run alone via bin/fm-test-run.sh keeps peak 1-minute load at or below its pre-run load plus 100; 2. no added swap (swap end <= start, swapouts delta about 0); 3. ~/.claude.json and ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json untouched by the suite, and the suite asserts it; 4. no test-spawned fm-watch.sh, fm-home-summary or fm-fleet-snapshot survivors after each run; 5. the proof run carries a memory watch naming top RSS growers in any swap window; 6. each suite exits on its own assertions, never Killed: 9 or a watcher-exit timeout. Proof: before and after measurements of an alone run of the four, attached to the PR.

Later decisions: the bead's done checks 1-6 bind, the muse-solver mechanisms do not. Fix (a): FM_HOME_SUMMARY_INTERVAL and killing HOME_SUMMARY_PID are measured not to work (the latter drops publication); use the smallest test-side way to stop the per-watcher refresh fan-out in the four suites and leave production publication unchanged. Fix (e) through fm_exec_timed instead of setsid is accepted. Fix (d) drift guard only, CI lane opted in, accepted.

## What Changed

- `bin/fm-test-run.sh` now runs every script in its own process group under `fm_exec_timed`, with or without `--per-script-timeout-secs` (0 now just means no deadline). The pid of the runner the caller started is passed through the machine gate's re-exec (`FM_TEST_MACHINE_LINE_OWNER_PID`). If that runner dies, even by KILL, or its group gets TERM, INT, HUP or KILL, the running script's group is ended and no further script starts. An interrupted script ends the run with exit 130. The runner also accepts zero-padded `--per-script-timeout-secs` values. In `bin/fm-timeout-lib.sh`, `fm_exec_timed`'s perl watchdog now:
  - starts a sentinel in a group of its own, which ends the command's group if the watchdog itself is killed;
  - blocks TERM, INT and HUP across the fork, so a signal that arrives early is not lost;
  - reports 130 once it has received an INT.
- Lock-wait loops in `bin/fm-watch-arm.sh` and `bin/fm-wake-lib.sh` now poll every 0.1s instead of every 0.02s, keeping the same bound. The take-over wait goes from 50×0.02s to 10×0.1s. In the watcher tests, the `FM_POLL=0.2` sites now use `FM_POLL=1`.
- Test isolation:
  - A new `bound_home_summary_refresh` helper in `tests/wake-helpers.sh` stops each watcher from starting a home-summary refresh. It is used by fm-wake-queue, fm-watch-triage and fm-supervision-host. It sets the interval above the age reported for a missing summary, gives a refresh a 1s timeout and moves `TMPDIR` into the suite's temp root. Production publication is unchanged.
  - The wake-queue liveness legs now run with a per-case `HOME` and an empty `CLAUDE_CONFIG_DIR`. A new case checks that a Claude relaunch writes trust only in the case's own HOME, and that neither real `.claude.json` gains this suite's fixture paths.
  - The real-harness liveness drift guard is now opt-in. The portable serial CI lane opts in with `FM_HARNESS_LIVENESS_DRIFT=1`, and the coding guidelines and `docs/verification/runtime-backends.md` are updated to match.

## Risk Assessment

⚠️ Medium: The fix round is a single correct line: it normalizes zero-padded values once after validation, and its regression case fails without that line and passes with it. No new defect turned up in the rest of the branch, but the branch still changes process-group and signal handling in the shared fm_exec_timed library (a sentinel fork per call, and a 130 exit status after an interrupt), and production callers (the supervision engine turn, the tasks-axi bound, fm-lint's probe) inherit that, so the blast radius is wider than test infrastructure.

## Testing

I drove the real bin/fm-test-run.sh in a throwaway fixture repo through eight kill and interrupt cases (serial and jobs, pid and group KILL, TERM, a machine-gate re-exec, Ctrl-C, inherited-ignored INT) and both timeout cases. All passed: no fixture process survived, nothing started after the signal, TERM gave the suite its cleanup grace, interrupts ended the run with exit 130, the zero-padded 0600 bound recorded exit=3, and a 2s bound recorded exit=124 before the next script ran. The drift guard skips as `live: opt-in` with no harness launched, and CI opts in. fm-host-mirror's alone run met done checks 1-4 and 6, and the memory watch for check 5 found no swap window to explain: peak load 15.5 against a 115 limit, no swap or swapouts added, both Claude stores' hashes unchanged, no survivors, an empty TMPDIR. fm-wake-queue ran 58 ok and 0 not ok while staying flat (peak load 20.6 from 14.3, no swap added, 0 mentions of the run's scratch in either Claude store). This phase had to return its result before that run finished, so I TERMed its runner; no worktree processes survived, which is another live check of the runner-kill fix. fm-supervision-host and fm-watch-triage, about 13 and 18 minutes by CI hints, never started. None of this is visual, so there are no screenshots; the evidence is text transcripts and sampler logs. Scratch is removed.

- Live validation: ⚠️ inconclusive - 10 of 13 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| KILL the serial runner pid mid-suite: the suite and its background child die and the next script never starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: KILL the runner pid&#39;: rc=137, still alive after 1s: [], the suite&#39;s TERM cleanup ran, FM_TEST_BEGIN count=1 |
| KILL the runner&#39;s whole process group (watchdog killed too): the sentinel still takes the suite group down | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: KILL the runner&#39;s whole process group&#39; and &#39;jobs=2: KILL the runner&#39;s whole process group&#39;: nothing alive, cleanup ran, no later BEGIN |
| TERM the serial runner: the suite gets its TERM grace and finishes its cleanup before the group ends | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: TERM the runner&#39;: rc=143, the fixture&#39;s 0.3s-delayed cleanup marker was written, nothing alive, no new scratch |
| KILL a --jobs 2 runner: both running workers&#39; suites die and no queued script starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;jobs=2: KILL the runner pid&#39;: 4 pids started, none alive after 1s, BEGIN count=2 of 3 selected |
| Runner re-executed by a machine gate: KILL the runner the caller launched and the inner runner stops its suite and starts nothing further | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial via machine-gate re-exec&#39;: inner runner logged &#39;the runner the caller launched (pid 61457) is gone; starting no further scripts&#39;; suite exit=143; nothing ali… |
| Ctrl-C the run, including a runner that inherited INT ignored: the run stops with exit 130 and the next script never starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, both INT cases: rc=130, END exit=130, &#39;a script was interrupted; starting no further scripts&#39;, BEGIN count=1, nothing alive (the stop takes the 10s grace because the… |
| --per-script-timeout-secs given zero-padded (0600) records the script&#39;s own exit status, not 125 | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;zero-padded --per-script-timeout-secs 0600&#39;: FM_TEST_END exit=3 |
| A hanging script under --per-script-timeout-secs 2 becomes exit 124 with no survivors, and the run continues to the next script | ✅ pass | live | runner-kill-interrupt-timeout.txt, last section: hang fixture exit=124 after 2.4s, its pids not alive, next script ran (exit=3) |
| The real-harness drift guard run without opt-in skips as a capability skip and launches no agent CLI under the real HOME; CI&#39;s portable-serial lane opts in | ✅ pass | live | drift-guard-opt-in.txt: &#39;skip: live: opt-in; set FM_HARNESS_LIVENESS_DRIFT=1 to run&#39;, gate_skip=true, expected_gate_skip=live-capability, claude process count 42 before and after; parsed ci.yml shows… |
| fm-host-mirror run alone: load at most pre+100, no swap added, Claude stores untouched, no watcher/summary/snapshot survivors, ends on its own assertions, nothing left in TMPDIR | ✅ pass | live | alone-fm-host-mirror.report.txt: rc=0 (exit=0), peak 15.48 against limit 115.35, swap 1482.44 to 1482.44 MB, swapouts delta 0, both store hashes unchanged, 0 mentions, survivors none, leftovers 0 |
| fm-wake-queue run alone: load, swap and Claude-store checks, the liveness trust-write sandbox, and survivors | ⏸️ untested | no | The run was live and on track, but this phase was told to return its result before fm-wake-queue finished. I TERMed its runner, so I have no final rc, and the in-suite assertion test_liveness_relaunch… |
| fm-supervision-host run alone meets done checks 1-6 | ⏸️ untested | no | Its CI hint is about 13 minutes. It was queued in the background chain, which had to be stopped when this phase was told to return before it started. Nothing on the machine prevents it; it needs a tes… |
| fm-watch-triage run alone meets done checks 1-6 (FM_POLL raised to 1, no home-summary refresh fan-out) | ⏸️ untested | no | Its CI hint is about 18 minutes. It was queued last and never started, because this phase was told to return first. It needs the same longer budget, or the author&#39;s before/after proof run. |

<details>
<summary>Evidence: Runner kill / interrupt / timeout transcript (real runner, fixture suites)</summary>

Source: [Runner kill / interrupt / timeout transcript (real runner, fixture suites)](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/runner-kill-interrupt-timeout.txt)

```text
=== serial: KILL the runner pid
runner pid 58679 (own group); script+child pids started: 58808 58816 
sent: KILL to runner pid 58679
/tmp/fm-nmtest.wZSukX/bin/runner-scenarios.sh: line 77: 58679 Killed: 9                  ( cd "$FX/repo" && exec env TMPDIR="$FX/tmp" STARTS_FILE="$FX/starts" CLEANED_FILE="$FX/cleaned" FM_TEST_MACHINE_GATE="$gate" perl -e "$launcher" "$RUNNER" "$@" ) > "$FX/out" 2>&1
runner rc=137; still alive after 1s: []
scripts that ran their TERM/INT cleanup: [58808 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:47Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
scratch left in runner TMPDIR: [fm-test-run.prp0bS ]

=== serial: KILL the runner's whole process group (sentinel path)
runner pid 59304 (own group); script+child pids started: 59419 59425 
sent: group-KILL to runner group -59304
/tmp/fm-nmtest.wZSukX/bin/runner-scenarios.sh: line 77: 59304 Killed: 9                  ( cd "$FX/repo" && exec env TMPDIR="$FX/tmp" STARTS_FILE="$FX/starts" CLEANED_FILE="$FX/cleaned" FM_TEST_MACHINE_GATE="$gate" perl -e "$launcher" "$RUNNER" "$@" ) > "$FX/out" 2>&1
runner rc=137; still alive after 0s: []
scripts that ran their TERM/INT cleanup: [59419 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:48Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
scratch left in runner TMPDIR: [fm-test-run.bABFSK fm-test-run.prp0bS ]

=== serial: TERM the runner (suite gets its TERM grace)
runner pid 59630 (own group); script+child pids started: 59727 59736 
sent: TERM to runner pid 59630
runner rc=143; still alive after 1s: []
scripts that ran their TERM/INT cleanup: [59727 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:49Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
scratch left in runner TMPDIR: [fm-test-run.bABFSK fm-test-run.prp0bS ]

=== jobs=2: KILL the runner pid
runner pid 60217 (own group); script+child pids started: 60412 60435 60433 60452 
sent: KILL to runner pid 60217
/tmp/fm-nmtest.wZSukX/bin/runner-scenarios.sh: line 77: 60217 Killed: 9                  ( cd "$FX/repo" && exec env TMPDIR="$FX/tmp" STARTS_FILE="$FX/starts" CLEANED_FILE="$FX/cleaned" FM_TEST_MACHINE_GATE="$gate" perl -e "$launcher" "$RUNNER" "$@" ) > "$FX/out" 2>&1
runner rc=137; still alive after 1s: []
scripts that ran their TERM/INT cleanup: [60412 60433 ]
FM_TEST_BEGIN count=2 (expected 2: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:51Z tests/fm-brief.test.sh family=pure-contract-unit expected_gate_skip=none
  | FM_TEST_BEGIN 2026-10-18T06:16:51Z tests/fm-crew-state.test.sh family=pure-contract-unit expected_gate_skip=none
scratch left in runner TMPDIR: [fm-test-run.SS7Xeh fm-test-run.bABFSK fm-test-run.prp0bS ]

=== jobs=2: KILL the runner's whole process group
runner pid 60981 (own group); script+child pids started: 61158 61164 61167 61171 
sent: group-KILL to runner group -60981
/tmp/fm-nmtest.wZSukX/bin/runner-scenarios.sh: line 77: 60981 Killed: 9                  ( cd "$FX/repo" && exec env TMPDIR="$FX/tmp" STARTS_FILE="$FX/starts" CLEANED_FILE="$FX/cleaned" FM_TEST_MACHINE_GATE="$gate" perl -e "$launcher" "$RUNNER" "$@" ) > "$FX/out" 2>&1
runner rc=137; still alive after 1s: []
scripts that ran their TERM/INT cleanup: [61158 61167 ]
FM_TEST_BEGIN count=2 (expected 2: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:52Z tests/fm-brief.test.sh family=pure-contract-unit expected_gate_skip=none
  | FM_TEST_BEGIN 2026-10-18T06:16:52Z tests/fm-crew-state.test.sh family=pure-contract-unit expected_gate_skip=none
scratch left in runner TMPDIR: [fm-test-run.SS7Xeh fm-test-run.bABFSK fm-test-run.n9Gjqj fm-test-run.prp0bS ]

=== serial via machine-gate re-exec: KILL the runner the caller launched
runner pid 61457 (own group); script+child pids started: 61678 61685 ; gate-re-executed inner runner: 61558 
sent: KILL to runner pid 61457
/tmp/fm-nmtest.wZSukX/bin/runner-scenarios.sh: line 77: 61457 Killed: 9                  ( cd "$FX/repo" && exec env TMPDIR="$FX/tmp" STARTS_FILE="$FX/starts" CLEANED_FILE="$FX/cleaned" FM_TEST_MACHINE_GATE="$gate" perl -e "$launcher" "$RUNNER" "$@" ) > "$FX/out" 2>&1
runner rc=137; still alive after 1s: []
scripts that ran their TERM/INT cleanup: [61678 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:53Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
  | FM_TEST_END 2026-10-18T06:16:54Z tests/fm-orphan-fixture.test.sh exit=143 duration_ms=1252 gate_skip=false
  | fm-test-run: the runner the caller launched (pid 61457) is gone; starting no further scripts
scratch left in runner TMPDIR: [fm-test-machine-line.r2T3Sq fm-test-run.SS7Xeh fm-test-run.bABFSK fm-test-run.n9Gjqj fm-test-run.prp0bS ]

=== serial: Ctrl-C (INT to runner group)
runner pid 62469 (own group); script+child pids started: 62561 62570 
sent: group-INT to runner group -62469
runner rc=130; still alive after 10s: []
scripts that ran their TERM/INT cleanup: [62561 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:16:55Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
  | FM_TEST_END 2026-10-18T06:17:05Z tests/fm-orphan-fixture.test.sh exit=130 duration_ms=10567 gate_skip=false
  | fm-test-run: a script was interrupted; starting no further scripts
scratch left in runner TMPDIR: [fm-test-machine-line.r2T3Sq fm-test-run.SS7Xeh fm-test-run.bABFSK fm-test-run.n9Gjqj fm-test-run.prp0bS ]

=== serial, runner inherited INT ignored: INT to group
runner pid 67034 (own group); script+child pids started: 67084 67091 
sent: group-INT to runner group -67034
runner rc=130; still alive after 10s: []
scripts that ran their TERM/INT cleanup: [67084 ]
FM_TEST_BEGIN count=1 (expected 1: nothing starts after the kill)
  | FM_TEST_BEGIN 2026-10-18T06:17:06Z tests/fm-orphan-fixture.test.sh family=unclassified expected_gate_skip=none
  | FM_TEST_END 2026-10-18T06:17:16Z tests/fm-orphan-fixture.test.sh exit=130 duration_ms=10197 gate_skip=false
  | fm-test-run: a script was interrupted; starting no further scripts
scratch left in runner TMPDIR: [fm-test-machine-line.r2T3Sq fm-test-run.SS7Xeh fm-test-run.bABFSK fm-test-run.n9Gjqj fm-test-run.prp0bS ]

=== zero-padded --per-script-timeout-secs 0600
runner rc=1
  | FM_TEST_END 2026-10-18T06:17:16Z tests/fm-exit3-fixture.test.sh exit=3 duration_ms=242 gate_skip=false
  | FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=341

=== --per-script-timeout-secs 2 on a hanging script, then the next script
runner rc=1 after 3s; hung script pids still alive: []
  | FM_TEST_BEGIN 2026-10-18T06:17:16Z tests/fm-hang-fixture.test.sh family=unclassified expected_gate_skip=none
  | FM_TEST_END 2026-10-18T06:17:19Z tests/fm-hang-fixture.test.sh exit=124 duration_ms=2392 gate_skip=false
  | FM_TEST_BEGIN 2026-10-18T06:17:19Z tests/fm-exit3-fixture.test.sh family=unclassified expected_gate_skip=none
  | FM_TEST_END 2026-10-18T06:17:19Z tests/fm-exit3-fixture.test.sh exit=3 duration_ms=143 gate_skip=false
  | FM_TEST_SUMMARY total=2 failed=2 skipped_gate=0 duration_ms=2664
```
</details>
<details>
<summary>Evidence: Drift guard opt-in skip transcript and timing record</summary>

Source: [Drift guard opt-in skip transcript and timing record](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/drift-guard-opt-in.txt)

```text
$ env -u FM_HARNESS_LIVENESS_DRIFT -u FM_LIVE FM_TEST_MACHINE_GATE= bin/fm-test-run.sh --json drift.json tests/fm-harness-liveness-drift-live-e2e.test.sh
FM_TEST_BEGIN 2026-10-18T06:18:00Z tests/fm-harness-liveness-drift-live-e2e.test.sh family=live-harness-optin expected_gate_skip=live-capability
skip: live: opt-in; set FM_HARNESS_LIVENESS_DRIFT=1 to run
fm-test-run: gate skip: tests/fm-harness-liveness-drift-live-e2e.test.sh: live: opt-in; set FM_HARNESS_LIVENESS_DRIFT=1 to run
FM_TEST_END 2026-10-18T06:18:01Z tests/fm-harness-liveness-drift-live-e2e.test.sh exit=0 duration_ms=836 gate_skip=true
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1 duration_ms=2148
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=1 duration_ms=836 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-harness-liveness-drift-live-e2e.test.sh duration_ms=836
fm-test-run: wrote timing artifact: /tmp/fm-nmtest.wZSukX/drift.WpQN/drift.json
runner rc=0
--- timing artifact record:
{'script': None, 'exit': 0, 'gate_skip': True, 'gate_skip_reason': 'live: opt-in; set FM_HARNESS_LIVENESS_DRIFT=1 to run', 'expected_gate_skip': 'live-capability', 'duration_ms': 836}
--- tmux lab sessions/servers started by guard: 
```
</details>
<details>
<summary>Evidence: fm-host-mirror alone-run report (done checks 1-6)</summary>

Source: [fm-host-mirror alone-run report (done checks 1-6)](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-host-mirror.report.txt)

```text
suite=fm-host-mirror rc=0 wall_s=28
runner_tail:
  FM_TEST_END 2026-10-18T06:16:18Z tests/fm-host-mirror.test.sh exit=0 duration_ms=27940 gate_skip=false
  FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=28173
check1_load: pre=15.35 peak=15.48 limit=115.35 post=14.49
check2_swap: start_mb=1482.44 end_mb=1482.44 max_mb=1482.44 swapouts_delta=0
check3_stores: home_sha_changed=no ccd_sha_changed=no
check3_mentions_of_run_tmp: home=0 ccd=0
check4_survivors: none
tmpdir_leftovers: 0
check5_top_rss_growers (pid comm first_kb max_kb growth_kb):
  28542	~/.local/bin/muse-bin-1.4.10-R6427.1	1339408	1346336	6928
  82455	claude	725504	729440	3936
  5410	/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent	1077104	1077984	880
  7099	/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex	777600	777648	48
  7089	/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)	784048	784048	0
```
</details>
<details>
<summary>Evidence: fm-host-mirror load/swap samples</summary>

Source: [fm-host-mirror load/swap samples](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-host-mirror.samples.tsv)

```text
epoch	load1	swap_used_mb	swapouts
1792304150	15.35	1482.44	96924
1792304152	15.35	1482.44	96924
1792304154	15.48	1482.44	96924
1792304157	15.48	1482.44	96924
1792304159	15.48	1482.44	96924
1792304161	15.04	1482.44	96924
1792304163	15.04	1482.44	96924
1792304165	14.56	1482.44	96924
1792304168	14.56	1482.44	96924
1792304170	14.27	1482.44	96924
1792304172	14.27	1482.44	96924
1792304175	15.05	1482.44	96924
1792304177	15.05	1482.44	96924
1792304179	14.49	1482.44	96924
1792304181	14.49	1482.44	96924
1792304183	14.49	1482.44	96924
```
</details>
<details>
<summary>Evidence: fm-host-mirror top-RSS memory watch</summary>

Source: [fm-host-mirror top-RSS memory watch](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-host-mirror.memory.tsv)

```text
epoch	rss_kb	pid	command
1792304150	2032480	44362	/opt/homebrew/bin/node
1792304150	1339408	28542	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304150	1190736	38306	/Applications/BlitzTree.app/Contents/MacOS/BlitzTree
1792304150	1077104	5410	/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
1792304150	784048	7089	/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
1792304150	777600	7099	/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
1792304150	773648	33708	git
1792304150	762416	18555	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304161	1447440	44362	/opt/homebrew/bin/node
1792304161	1340688	28542	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304161	1190736	38306	/Applications/BlitzTree.app/Contents/MacOS/BlitzTree
1792304161	1077424	5410	/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
1792304161	784048	7089	/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
1792304161	777648	7099	/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
1792304161	762416	18555	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304161	725504	82455	claude
1792304172	1505152	44362	/opt/homebrew/bin/node
1792304172	1341680	28542	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304172	1190736	38306	/Applications/BlitzTree.app/Contents/MacOS/BlitzTree
1792304172	1077600	5410	/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
1792304172	784048	7089	/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
1792304172	777648	7099	/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
1792304172	762416	18555	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304172	729360	82455	claude
1792304183	1505152	44362	/opt/homebrew/bin/node
1792304183	1346336	28542	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304183	1190736	38306	/Applications/BlitzTree.app/Contents/MacOS/BlitzTree
1792304183	1077984	5410	/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
1792304183	784048	7089	/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
1792304183	777648	7099	/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
1792304183	762416	18555	~/.local/bin/muse-bin-1.4.10-R6427.1
1792304183	729440	82455	claude
```
</details>
<details>
<summary>Evidence: fm-host-mirror runner log</summary>

Source: [fm-host-mirror runner log](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-host-mirror.log)

```text
FM_TEST_BEGIN 2026-10-18T06:15:50Z tests/fm-host-mirror.test.sh family=afk expected_gate_skip=none
ok - mirror: the Claude and Cursor registrations each write the captain's prompt and main's reply
ok - mirror: writers stay silent and write nothing on a home that opted out or has no state
ok - only Claude and Cursor, the primaries with proven writers, have a verified dialog mirror
ok - mirror: a home opted out by config/supervision-host-off is untouched by every tracked mirror registration
ok - mirror: without config/supervision-host the Claude registrations write the mirror and Cursor's stay inert
ok - mirror: operational input, a harness-started turn, a foreign host's payload, other events, and a session without the lock are never mirrored
ok - mirror: a captain prompt and a main reply keep their internal whitespace and newlines verbatim
ok - mirror: a repeated entry is recorded once, and a long entry keeps its head and tail within the cap
ok - mirror: a later different reply under the same id is recorded, while an identical repeat is recorded once
ok - mirror: an entry id already recorded by an earlier main session does not drop a later session's dialog
ok - mirror: a failed append leaves the mirror valid, prints nothing, and later dialog still lands
ok - mirror: the captain's dialog lands only in an owner-only mirror, even when the file already existed readable by others
ok - mirror: captain prompts and main replies reach the mirror without ever entering a process argument list
ok - mirror: the feed resumes from its committed cursor, re-anchors on a new conversation or session, and is bounded
ok - mirror: the feed's bound includes the note naming how many earlier entries it left out
ok - mirror: a later lock holder with a recycled pid is a new main session
ok - mirror: the feed refuses a mirror with a zero, fractional, or non-rising sequence, or an unterminated final record
ok - mirror: a recreated mirror continues past the committed and staged cursors, so a resumed conversation still gets new dialog
FM_TEST_END 2026-10-18T06:16:18Z tests/fm-host-mirror.test.sh exit=0 duration_ms=27940 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=28173
FM_TEST_SUMMARY_FAMILY family=afk count=1 duration_ms=27940 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-host-mirror.test.sh duration_ms=27940
```
</details>
<details>
<summary>Evidence: fm-wake-queue partial alone-run log (58 ok, stopped by runner TERM)</summary>

Source: [fm-wake-queue partial alone-run log (58 ok, stopped by runner TERM)](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-wake-queue.log)

```text
FM_TEST_BEGIN 2026-10-18T06:16:24Z tests/fm-wake-queue.test.sh family=watcher-wake-lock expected_gate_skip=none
ok - an abandoned same-process lock hold is reclaimed; a parent's live hold is not
ok - without BASHPID a subshell cannot release or reclaim its parent lock and owns its own hold
ok - bounded acquire hands ownership to the waiting caller after contention
ok - presentation lock waits are bounded and retriable without weakening acknowledgement atomicity
ok - malformed presentation locks report acquire failure instead of contention
tests/wake-helpers.sh: line 335: 56552 Killed: 9                  PATH="$dir/fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' FM_SECONDMATE_WAKE_STALL_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-$leg.out" 2> "$dir/watch-$leg.err"
tests/wake-helpers.sh: line 335: 56933 Killed: 9                  PATH="$dir/fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' FM_SECONDMATE_WAKE_STALL_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-$leg.out" 2> "$dir/watch-$leg.err"
tests/wake-helpers.sh: line 335: 59158 Killed: 9                  PATH="$dir/fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' FM_SECONDMATE_WAKE_STALL_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-$leg.out" 2> "$dir/watch-$leg.err"
ok - foreign secondmate queue alerts once per no-progress episode without age-only or cascade noise
ok - declared external-wait pause rows do not feed secondmate wake-loop escalation
ok - a reprovisioned queue generation starts a fresh no-progress interval
ok - an active turn defers the secondmate stall escalation without cancelling it
ok - a long-lived mate mid-turn is not a stall, but a queue frozen past the busy bound still alarms
ok - a proven-idle leftover row is rung so the child home can drain without a parent alarm
ok - TERM stops a watcher blocked in the drain-ring idle capture and runs its cleanup
ok - busy panes defer without a ring and unknown panes keep the parent alarm
ok - a leftover row that survives a proven-idle ring still surfaces as a genuine stall
ok - secondmate stall markers reject symlinks without touching their targets
ok - stall publication acknowledgement closes the pre-marker crash window
ok - empty prefix mate cleanup preserves another mate's stall receipt
ok - self-announced appends suppress only their own bytes and fail toward waking
ok - separate self-announced answers after a fold stay owned; worker decisions and later lines still wake
ok - an unreadable status still reads as unreported, with or without owned growth
ok - a worker resolved in fold lag still wakes after this home's close
ok - owned growth suppresses the wake without hiding the turn-ended annotation
ok - historical annotations replay nothing already announced and keep everything new
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 87810.1792304265.YUuZur
ok - concurrent append plus drain preserves durable records through acknowledgement
ok - signal written while no watcher runs is caught on next run
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 18503.1792304300.o3RPFU
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
ok - stale wake is queued before suppressor state is advanced
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 19938.1792304303.LSUkj3
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
ok - a not-provably-working stale wake is queued before its suppressor is advanced
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 21406.1792304306.PKymNB
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
ok - registered custom check output is queued before cadence suppression
ok - concurrent drains replay until one post-handling acknowledgement consumes records
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 4 --recovery-generation 24315.1792304309.8lewx6
ok - drain collapses obvious duplicate heartbeat and signal records
ok - drain asserts watcher liveness: warns on a lapse, stays silent for a live watcher with a fresh beacon
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 8 --recovery-generation 25770.1792304312.E6peWu
ok - structural signal enrichment is separate, deduped, home-local, and tier-zero for other wakes
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 13 --recovery-generation 27121.1792304314.ZoBgHH
ok - every readable unread status line is annotated in full while invalid status files preserve their raw wakes
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 29142.1792304318.HXf1Tn
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 29142.1792304318.HXf1Tn
ok - slow annotation releases the append lock and a deleted status file fails open
ok - a branch-actor scoped ack never swallows an unacked main-owned row, and main's later drain sees exactly what remains
ok - main drain and acknowledgement exclude an active branch grant
ok - a branch-actor acknowledgement commits secondmate stall receipts for exactly its granted rows
ok - a branch-held row raises no queued-wake warning for main, and the same row is presented and acknowledged once the grant clears
ok - a queue that cannot be counted keeps the queued-wake alarm up
ok - structurally unusable rows are retired by main alone, leaving every remaining row presentable and acknowledgeable
ok - branch grant cannot take a row already claimed by main
ok - main's acknowledgement leaves a row that arrived after its drain for whichever actor takes it next
ok - actor ownership filtering precedes same-key deduplication
ok - main reclaims rows granted to an exited branch owner
ok - a branch-actor drain with no eligible-row snapshot refuses loudly instead of draining nothing
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation existing
ok - wake append publishes atomic recovery evidence before durable rows
ok - recovery mint and delivery log avoid sibling $()
ok - wake drain: generation-less legacy wakes are adopted and acknowledged
ok - a handover undoes only the downtime its own stop published over an acknowledged episode
ok - wake drain: a stale acknowledgement cannot retire or consume a newer recovery episode
ok - wake drain: an acknowledgement that consumes nothing says so and names the exact command for the current wake
ok - wake drain: a branch acknowledgement that consumes nothing names the exact command for its granted wake
ok - wake drain: recovery acknowledgement failures are explicit and retryable
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 48246.1792304363.oyKLcL
ok - interruptions preserve durable rows until post-handling acknowledgement
ok - fm_wake_queue_prune_task: prunes wakes for target task without touching other tasks
ok - drain rotates scratch files an interrupted drain left under the queue lock
ok - watch liveness: a dead secondmate is relaunched once, ledgered, and quiet afterwards
ok - watch liveness: a missing secondmate endpoint is relaunched without a pre-kill
Terminated: 15             sleep 0.1
rm: /private/tmp/fm-nmtest.wZSukX/run/fm-wake-queue/fm-wake-tests.FfkhsO: Directory not empty
```
</details>
<details>
<summary>Evidence: fm-wake-queue partial load/swap samples</summary>

Source: [fm-wake-queue partial load/swap samples](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-wake-queue.samples.tsv)

```text
epoch	load1	swap_used_mb	swapouts
1792304184	14.29	1482.44	96924
1792304186	14.29	1482.44	96924
1792304189	14.29	1482.44	96924
1792304191	18.51	1482.44	96924
1792304193	18.51	1482.44	96924
1792304195	17.51	1482.44	96924
1792304198	17.51	1482.44	96924
1792304200	17.14	1482.44	96924
1792304202	17.14	1482.44	96924
1792304204	16.49	1482.44	96924
1792304207	16.49	1482.44	96924
1792304209	15.89	1482.44	96924
1792304211	15.89	1482.44	96924
1792304214	15.89	1482.44	96924
1792304216	16.38	1482.44	96924
1792304218	16.38	1482.44	96924
1792304221	15.87	1482.44	96924
1792304223	15.87	1482.44	96924
1792304225	15.08	1482.44	96924
1792304227	15.08	1482.44	96924
1792304229	14.51	1482.44	96924
1792304232	14.51	1482.44	96924
1792304234	14.51	1482.44	96924
1792304236	13.91	1482.44	96924
1792304238	13.91	1482.44	96924
1792304240	13.68	1482.44	96924
1792304242	13.68	1482.44	96924
1792304245	13.54	1482.44	96924
1792304247	13.54	1482.44	96924
1792304249	12.86	1482.44	96924
1792304251	12.86	1482.44	96924
1792304253	12.86	1482.44	96924
1792304256	12.23	1482.44	96924
1792304258	12.23	1482.44	96924
1792304260	11.89	1482.44	96924
1792304262	11.89	1482.44	96924
1792304264	11.74	1482.44	96924
1792304266	11.74	1482.44	96924
1792304269	11.74	1482.44	96924
1792304271	13.68	1482.44	96924
1792304273	13.68	1482.44	96924
1792304278	17.15	1482.44	96924
1792304281	19.38	1482.44	96924
1792304283	19.38	1482.44	96924
1792304285	20.63	1482.44	96924
1792304287	20.63	1482.44	96924
1792304290	20.18	1482.44	96924
1792304292	20.18	1482.44	96924
1792304294	20.00	1482.44	96924
1792304296	20.00	1482.44	96924
1792304299	20.00	1482.44	96924
1792304301	19.20	1482.44	96924
1792304303	19.20	1482.44	96924
1792304305	18.71	1482.44	96924
1792304307	18.71	1482.44	96924
1792304309	17.69	1482.44	96924
1792304312	17.69	1482.44	96924
1792304314	16.75	1482.44	96924
1792304316	16.75	1482.44	96924
1792304318	16.75	1482.44	96924
1792304320	15.89	1482.44	96924
1792304323	15.89	1482.44	96924
1792304325	14.94	1482.44	96924
1792304327	14.94	1482.44	96924
1792304329	15.34	1482.44	96924
1792304331	15.34	1482.44	96924
1792304334	15.34	1482.44	96924
1792304336	15.16	1482.44	96924
1792304338	15.16	1482.44	96924
1792304340	14.58	1482.44	96924
1792304342	14.58	1482.44	96924
1792304344	14.54	1482.44	96924
1792304347	14.54	1482.44	96924
1792304349	14.54	1482.44	96924
1792304351	14.57	1482.44	96924
1792304353	14.57	1482.44	96924
1792304355	14.45	1482.44	96924
1792304358	14.45	1482.44	96924
1792304360	14.17	1482.44	96924
1792304362	14.17	1482.44	96924
1792304364	13.92	1482.44	96924
1792304366	13.92	1482.44	96924
1792304368	13.92	1482.44	96924
1792304371	13.52	1482.44	96924
1792304373	13.52	1482.44	96924
1792304375	13.16	1482.44	96924
1792304377	13.16	1482.44	96924
1792304379	12.99	1482.44	96924
1792304382	12.99	1482.44	96924
1792304384	12.99	1482.44	96924
1792304386	12.91	1482.44	96924
1792304388	12.91	1482.44	96924
1792304390	12.67	1482.44	96924
1792304393	12.67	1482.44	96924
1792304395	12.38	1482.44	96924
1792304397	12.38	1482.44	96924
1792304399	12.99	1482.44	96924
1792304401	12.99	1482.44	96924
```
</details>

- Evidence: [fm-wake-queue partial top-RSS memory watch](https://github.com/gsp-agent/firstmate/blob/006b25bf8d56300ed730fea4697e1391b47dfa6a/.no-mistakes/evidence/fm/fm-1egx8-suites/alone-fm-wake-queue.memory.tsv)

<details>
<summary>Evidence: fm-host-mirror alone-run summary</summary>

```text
suite=fm-host-mirror rc=0 wall_s=28
check1_load: pre=15.35 peak=15.48 limit=115.35
check2_swap: start_mb=1482.44 end_mb=1482.44 swapouts_delta=0
check3_stores: home_sha_changed=no ccd_sha_changed=no; mentions of run tmp: 0/0
check4_survivors: none
tmpdir_leftovers: 0
```
</details>
- Outcome: ⚠️ 2 warnings across 1 run (7m54s)

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"fe6b1563aa708da9954b42a666880b74018c955e","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Rebase** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>🔧 **Review** - 1 issue found → auto-fixed ✅</summary>

- ℹ️ `bin/fm-test-run.sh:2505` - A zero-padded --per-script-timeout-secs value now fails every script instead of bounding it. The option check at bin/fm-test-run.sh:2168 accepts any string of digits, so `--per-script-timeout-secs 0600` passes, and `[ &#34;$bound&#34; -gt 0 ]` reads it as 600. But run_script_bounded now hands the raw string to fm_exec_timed, which rejects anything matching `0*` (bin/fm-timeout-lib.sh:220) and exits 125 with a usage message. Every script is then recorded as exit=125. Before this branch the bounded path went through fm_run_timed, whose `timeout 0600` and perl `alarm` both read the value as 600 seconds. Fix: normalize the value once, right after validation at :2168, with `PER_SCRIPT_TIMEOUT_SECS=$((10#$PER_SCRIPT_TIMEOUT_SECS))`. Both launch sites (the streamed one at :2514 and the captured one at :2522) then get a canonical value.

🔧 Fix applied.
✅ Re-checked - no issues remain.
</details>

<details>
<summary>⚠️ **Test** - 2 warnings</summary>

- ⚠️ This phase could not show the bead&#39;s main done checks for three of the four suites. fm-host-mirror passed every alone-run check. fm-wake-queue was clean at 58 ok when it had to be stopped, before its Claude-store assertion ran. fm-supervision-host (about 13 min) and fm-watch-triage (about 18 min) never started, because this phase was told to return first. Before merging, decide whether to rely on the author&#39;s before/after proof run attached to the PR or to re-run this step with a longer test budget so the three suites can each run alone.
- ⚠️ live validation verdict: inconclusive (10 of 13 scenarios were driven live against the product); untested: fm-wake-queue run alone: load, swap and Claude-store checks, the liveness trust-write sandbox, and survivors, fm-supervision-host run alone meets done checks 1-6, fm-watch-triage run alone meets done checks 1-6 (FM_POLL raised to 1, no home-summary refresh fan-out)
- Live validation: ⚠️ inconclusive - 10 of 13 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| KILL the serial runner pid mid-suite: the suite and its background child die and the next script never starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: KILL the runner pid&#39;: rc=137, still alive after 1s: [], the suite&#39;s TERM cleanup ran, FM_TEST_BEGIN count=1 |
| KILL the runner&#39;s whole process group (watchdog killed too): the sentinel still takes the suite group down | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: KILL the runner&#39;s whole process group&#39; and &#39;jobs=2: KILL the runner&#39;s whole process group&#39;: nothing alive, cleanup ran, no later BEGIN |
| TERM the serial runner: the suite gets its TERM grace and finishes its cleanup before the group ends | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial: TERM the runner&#39;: rc=143, the fixture&#39;s 0.3s-delayed cleanup marker was written, nothing alive, no new scratch |
| KILL a --jobs 2 runner: both running workers&#39; suites die and no queued script starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;jobs=2: KILL the runner pid&#39;: 4 pids started, none alive after 1s, BEGIN count=2 of 3 selected |
| Runner re-executed by a machine gate: KILL the runner the caller launched and the inner runner stops its suite and starts nothing further | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;serial via machine-gate re-exec&#39;: inner runner logged &#39;the runner the caller launched (pid 61457) is gone; starting no further scripts&#39;; suite exit=143; nothing ali… |
| Ctrl-C the run, including a runner that inherited INT ignored: the run stops with exit 130 and the next script never starts | ✅ pass | live | runner-kill-interrupt-timeout.txt, both INT cases: rc=130, END exit=130, &#39;a script was interrupted; starting no further scripts&#39;, BEGIN count=1, nothing alive (the stop takes the 10s grace because the… |
| --per-script-timeout-secs given zero-padded (0600) records the script&#39;s own exit status, not 125 | ✅ pass | live | runner-kill-interrupt-timeout.txt, &#39;zero-padded --per-script-timeout-secs 0600&#39;: FM_TEST_END exit=3 |
| A hanging script under --per-script-timeout-secs 2 becomes exit 124 with no survivors, and the run continues to the next script | ✅ pass | live | runner-kill-interrupt-timeout.txt, last section: hang fixture exit=124 after 2.4s, its pids not alive, next script ran (exit=3) |
| The real-harness drift guard run without opt-in skips as a capability skip and launches no agent CLI under the real HOME; CI&#39;s portable-serial lane opts in | ✅ pass | live | drift-guard-opt-in.txt: &#39;skip: live: opt-in; set FM_HARNESS_LIVENESS_DRIFT=1 to run&#39;, gate_skip=true, expected_gate_skip=live-capability, claude process count 42 before and after; parsed ci.yml shows… |
| fm-host-mirror run alone: load at most pre+100, no swap added, Claude stores untouched, no watcher/summary/snapshot survivors, ends on its own assertions, nothing left in TMPDIR | ✅ pass | live | alone-fm-host-mirror.report.txt: rc=0 (exit=0), peak 15.48 against limit 115.35, swap 1482.44 to 1482.44 MB, swapouts delta 0, both store hashes unchanged, 0 mentions, survivors none, leftovers 0 |
| fm-wake-queue run alone: load, swap and Claude-store checks, the liveness trust-write sandbox, and survivors | ⏸️ untested | no | The run was live and on track, but this phase was told to return its result before fm-wake-queue finished. I TERMed its runner, so I have no final rc, and the in-suite assertion test_liveness_relaunch… |
| fm-supervision-host run alone meets done checks 1-6 | ⏸️ untested | no | Its CI hint is about 13 minutes. It was queued in the background chain, which had to be stopped when this phase was told to return before it started. Nothing on the machine prevents it; it needs a tes… |
| fm-watch-triage run alone meets done checks 1-6 (FM_POLL raised to 1, no home-summary refresh fan-out) | ⏸️ untested | no | Its CI hint is about 18 minutes. It was queued last and never started, because this phase was told to return first. It needs the same longer budget, or the author&#39;s before/after proof run. |

- <code>`bin/fm-test-run.sh` copied with fm-test-machine-line-lib.sh, fm-timeout-lib.sh and git-config-helpers.sh into a throwaway repo, then run against fixture suites (a TERM trap with cleanup, a background `sleep 600`): KILL to the runner pid, KILL to the runner&#39;s whole group, TERM to the runner, serial and --jobs 2</code>
- `Same throwaway repo through a minimal machine-gate stand-in that re-executes the runner as its child: KILL the runner the caller launched`
- `Same: INT to the runner group (Ctrl-C), and INT to a runner that inherited INT ignored`
- <code>`bin/fm-test-run.sh --per-script-timeout-secs 0600 tests/fm-exit3-fixture.test.sh` (zero-padded bound)</code>
- `bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 2 tests/fm-hang-fixture.test.sh tests/fm-exit3-fixture.test.sh`
- `env -u FM_HARNESS_LIVENESS_DRIFT -u FM_LIVE FM_TEST_MACHINE_GATE= bin/fm-test-run.sh --json drift.json tests/fm-harness-liveness-drift-live-e2e.test.sh`
- `Parsed .github/workflows/ci.yml with PyYAML: the portable-serial step's env carries FM_HARNESS_LIVENESS_DRIFT=1`
- <code>`FM_TEST_MACHINE_GATE= TMPDIR=&lt;scratch&gt; bin/fm-test-run.sh tests/fm-host-mirror.test.sh` alone, with a 2s load/swap/swapout sampler, top-RSS watch every 10s, shasum and path-mention checks of ~/.claude.json and $CLAUDE_CONFIG_DIR/.claude.json, a survivor check for fm-watch/fm-home-summary/fm-fleet-snapshot/fm-crew-state, and a TMPDIR leftover check</code>
- <code>`bin/fm-test-run.sh tests/fm-wake-queue.test.sh` alone with the same measurements: 58 ok and 0 not ok, then stopped by TERM to the runner pid when this phase had to return</code>
</details>

<details>
<summary>✅ **Document** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Lint** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.
</details>


Made-with: claude (claude-opus-5-5)