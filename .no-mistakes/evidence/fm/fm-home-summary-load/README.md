# Test evidence: home summary publication under load (head f15dc13d)

Lab: a disposable FM_HOME (bin/fm-lab-home.sh shape) with a 64-task in-flight
fleet built by `scripts/build-lab.sh`: 40 local tmux ships with real windows
on a private `fm-lab` tmux socket, 4 scouts, 4 secondmates, 2 orca tasks,
8 remote-host tasks, 2 legacy tasks without spawn_gen, 2 tasks with hostile
metadata/status text, 2 tasks whose recorded window does not exist, long
keyed decision histories, about 20 contribution records (one malformed, one
unreadable) and a standing away contract. The real producer, crew-state, tmux
and git run; external services (no-mistakes daemon, forges, herdr, orca, ssh)
are stubs on a private PATH. "before" is the original 433c7b85 tree.

| File | What it shows |
| --- | --- |
| `refresh-timing.log` | Direct `fm-home-summary-refresh.sh` (default 60 s bound, no override, no --best-effort), original vs head alternating. Original never published; head published 64 endpoints in 42.50 / 24.36 / 56.52 s at load 49-72. With an artificial 1 s no-mistakes delay per worktree, both versions miss the bound. |
| `dead-lock-recovery-f15dc13d.log` | Refresh killed at a forced 3 s deadline leaves the publication lock pointing at a dead pid. The next direct refresh took the lock over (new owner), but its producer ran past 60 s at load 67-77 while this agent's own test suites were also running. |
| `dead-lock-recovery-f15dc13d-run2.log` | Same scenario at load 47-51: the dead lock was taken over, 64 endpoints published in 34.13 s, lock released, ledger mode 600, schema unchanged. |
| `dead-lock-section-head-vs-base.log` | Instrumented copy of the suite's stale-lock step on its one-task home, head and original alternating at load 86-101. The bare producer takes 2.4-6.6 s on both, longer than the watcher's 2 s test bound; the original wedged in round 1 the same way the suite check fails. |
| `home-summary-suite-base-vs-head.log` | The identical `tests/fm-home-summary-refresh.test.sh` from the original tree and from head, back to back under the same host load. |
| `contrib-watcher-cases-head-vs-base.log` | The two 5 s watcher cases in `tests/fm-contributions.test.sh`, head and original alternating at load 102-135: both versions fail them at that load. |
| `targeted-suites-f15dc13d.log`, `targeted-suites-rerun-f15dc13d.log` | `bin/fm-test-run.sh` over the targeted suites on head. |
| `equivalence-run1.log`, `equivalence-canonical.txt` | Original vs head producer output in all three modes with a pinned clock: identical when both observe the same state; round-2 differences come from the original's crew-state calls hitting their 10 s bound under load. |
| `hostile-and-backend-rows.txt` | Hostile metadata and orca/tmux backend/target rows identical between original and head. |
| `jq16-nul-framing.log`, `jq16-producer.log` | Under jq 1.6 the final NUL-framed record survives; producer output identical to jq 1.8. |
| `generation-race.log` | A task relaunched and one torn down mid-snapshot are discarded as "task generation changed during snapshot"; the other 62 are observed normally. |
| `contrib-batch-read-tests.log`, `contrib-batch-read-on-33300973.log` | The unreadable-sibling regression passes on f15dc13d and fails on 33300973. |
