#!/usr/bin/env python3
"""Replay focused validation; all disposable product inputs stay in the worktree."""
import glob
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M595RNA6700Q16CBBH8ZN9M6')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M595RNA6700Q16CBBH8ZN9M6')
SANDBOX = Path(tempfile.mkdtemp(prefix='.nm-focused-', dir=REPO))
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) or key in ('TMUX', 'TMUX_PANE', 'BASH_ENV', 'CLAUDE_CONFIG_DIR'):
        ENV.pop(key)
for name in ('home', 'tmp', 'claude', 'cache', 'config', 'state', 'data'):
    (SANDBOX / name).mkdir()
ENV.update(HOME=str(SANDBOX/'home'), TMPDIR=str(SANDBOX/'tmp'),
           CLAUDE_CONFIG_DIR=str(SANDBOX/'claude'), FM_HOME=str(SANDBOX/'lab'),
           FM_TEST_MACHINE_GATE='', XDG_CACHE_HOME=str(SANDBOX/'cache'),
           XDG_CONFIG_HOME=str(SANDBOX/'config'), XDG_STATE_HOME=str(SANDBOX/'state'),
           XDG_DATA_HOME=str(SANDBOX/'data'))
RESULTS = []

def run(label, command, *, extra=None, expected=0, timeout=900, observe=False):
    env = ENV | (extra or {})
    log_path = EVIDENCE / (label+'.log')
    started = time.monotonic()
    print('START', label, flush=True)
    observations = []
    with log_path.open('w') as log:
        log.write('$ '+shlex.join(command)+'\n')
        if extra:
            log.write('Scenario environment: '+json.dumps(extra, sort_keys=True)+'\n')
        log.flush()
        proc = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        last_seen = None
        while proc.poll() is None:
            if time.monotonic()-started > timeout:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                break
            if observe:
                for beat in SANDBOX.glob('tmp/**/provably-working-signal/state/.last-watcher-beat'):
                    if not beat.exists():
                        continue
                    sample = {'beat_mtime': int(beat.stat().st_mtime),
                              'last_check_exists': (beat.parent/'.last-check').exists(),
                              'suppressor_exists': (beat.parent/'.seen-task_status').exists(),
                              'wake_output_bytes': (beat.parent.parent/'watch.out').stat().st_size}
                    if sample != last_seen:
                        observations.append(sample)
                        last_seen = sample
            time.sleep(0.25)
        rc = proc.wait()
        elapsed = round(time.monotonic()-started, 2)
        log.write('\nCLI exit='+str(rc)+' elapsed_seconds='+str(elapsed)+' timeout='+str(timed_out)+'\n')
        if observations:
            log.write('Observed real watcher files while the selected case was running:\n')
            for row in observations:
                log.write(json.dumps(row, sort_keys=True)+'\n')
    good = not timed_out and rc == expected
    RESULTS.append({'name': label, 'exit': rc, 'expected_exit': expected,
                    'seconds': elapsed, 'pass': good, 'log': str(log_path)})
    print('END', label, 'exit='+str(rc), 'expected='+str(expected), 'seconds='+str(elapsed), flush=True)
    if not good:
        print(log_path.read_text()[-5000:], flush=True)
    return good

PROBE = '''nm_check_poll_boundaries() {
  local dir state fakebin out pid before after
  dir=$(make_case live-poll-boundaries); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a fresh home never completed a poll"; }
  [ ! -e "$state/.last-check" ] || { reap "$pid"; fail "fixture unexpectedly ran a check sweep"; }
  printf 'Fresh home: completed poll, absent .last-check, watcher alive, output_bytes=%s\\n' "$(wc -c < "$out")"
  : > "$state/.last-check"
  set_mtime "$(( $(date +%s) + 120 ))" "$state/.last-check"
  before=$(file_mtime "$state/.last-watcher-beat")
  if wait_poll_cycle "$state" "$pid" 35; then
    reap "$pid"; fail "a beat older than the existing check stamp was accepted"
  fi
  after=$(file_mtime "$state/.last-watcher-beat")
  [ "$after" -gt "$before" ] || { reap "$pid"; fail "the negative check never saw the real watcher advance"; }
  kill -0 "$pid" || fail "the negative check only passed because the watcher died"
  printf 'Existing check guard: beat advanced %s -> %s, check=%s, older beats rejected\\n' "$before" "$after" "$(file_mtime "$state/.last-check")"
  set_mtime "$(( $(date +%s) - 60 ))" "$state/.last-check"
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a beat newer than the existing stamp was rejected"; }
  printf 'Existing old check: a newer real poll was accepted\\n'
  reap "$pid"
  pass "fresh homes progress; existing check stamps still reject premature beats"
}
'''

try:
    run('lab-create', ['bash', 'bin/fm-lab-home.sh', 'create', str(SANDBOX/'lab')])
    old = SANDBOX/'before'
    (old/'tests').mkdir(parents=True)
    (old/'bin').symlink_to(REPO/'bin', target_is_directory=True)
    for name in ('wake-helpers.sh', 'lib.sh', 'git-config-helpers.sh'):
        shutil.copyfile(REPO/'tests'/name, old/'tests'/name)
    original = subprocess.check_output(['git', 'show', 'f8ac1f64:tests/fm-watch-triage.test.sh'], cwd=REPO)
    (old/'tests'/'fm-watch-triage.test.sh').write_bytes(original)
    run('before-working-signal', ['bash', str(old/'tests'/'fm-watch-triage.test.sh')],
        extra={'FM_TEST_ONLY':'test_provably_working_signal_absorbed'}, expected=1, observe=True, timeout=90)
    for name in ('test_provably_working_signal_absorbed', 'test_turn_ended_provably_working_absorbed',
                 'test_turn_ended_not_working_surfaced', 'test_actionable_signal_surfaced',
                 'test_beacon_stays_fresh_while_absorbing'):
        run('after-'+name.removeprefix('test_'), ['bash', 'bin/fm-test-run.sh', '--jobs', '1',
            'tests/fm-watch-triage.test.sh'], extra={'FM_TEST_ONLY':name}, timeout=100)
    probe = SANDBOX/'poll-probe.sh'
    probe.write_text(PROBE)
    run('poll-check-boundary', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', 'tests/fm-watch-triage.test.sh'],
        extra={'FM_TEST_ONLY':'nm_check_poll_boundaries', 'BASH_ENV':str(probe)}, timeout=100)
    run('runner-contract', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', 'tests/fm-test-run.test.sh'], timeout=900)
    run('timeout-contract', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', 'tests/fm-timeout-lib.test.sh'], timeout=600)
    run('drift-guard-default', ['bash', 'bin/fm-test-run.sh', '--jobs', '1',
        'tests/fm-harness-liveness-drift-live-e2e.test.sh'], timeout=60)
    fixture = SANDBOX/'own-status.test.sh'
    fixture.write_text('#!/usr/bin/env bash\necho "CLI fixture: intentional exit 3"\nexit 3\n')
    run('padded-bound-cli', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', '--per-script-timeout-secs', '0600',
        '--json', str(EVIDENCE/'padded-bound.json'), str(fixture)], expected=1, timeout=60)
    timed = SANDBOX/'deadline.test.sh'
    timed.write_text('#!/usr/bin/env bash\ntrap \'echo "CLI fixture: TERM cleanup completed"; exit 143\' TERM\necho "CLI fixture: waiting for deadline"\nsleep 600 &\nwait\n')
    run('deadline-cli', ['bash', 'bin/fm-test-run.sh', '--jobs', '1', '--per-script-timeout-secs', '1',
        '--json', str(EVIDENCE/'deadline.json'), str(timed)], expected=1, timeout=60)
finally:
    # Only our unique, just-created sandbox is eligible for cleanup.
    listing = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,state=,args='], text=True)
    survivors = [line for line in listing.splitlines() if str(SANDBOX) in line]
    (EVIDENCE/'focused-survivors.log').write_text('Processes whose argv still names this disposable sandbox:\n'+
        ('\n'.join(survivors) if survivors else 'none')+'\n')
    if survivors:
        print('SURVIVORS', survivors, flush=True)
    (EVIDENCE/'focused-results.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    (EVIDENCE/'sandbox-path.txt').write_text(str(SANDBOX)+'\n')
    print('SANDBOX', SANDBOX, flush=True)
    print('RESULTS', json.dumps(RESULTS), flush=True)
    # Deletion is performed separately through dcg after inspecting the sandbox.
