#!/usr/bin/env python3
"""Disposable product check; run from the gate worktree. No mock readiness CLI."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M51WFJ7ZYXYJW6YTC662ED4H')
EVIDENCE = Path(__file__).parent
assert Path.cwd() == ROOT
LAB = Path(tempfile.mkdtemp(prefix='.nm-readiness-live-', dir=ROOT))
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('FM_', 'HERDR_', 'ORCA_', 'CMUX_', 'CLAUDE_CODE_'))
       and k not in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
ENV['TMPDIR'] = str(LAB)
observations = []
holder = None
watcher = None
watch_log = None
transcript = (EVIDENCE / 'readiness-cli-transcript.txt').open('w')


def record(text):
    print(text, file=transcript, flush=True)


def home(name):
    path = LAB / name
    subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(path)],
                   cwd=ROOT, env=ENV, stdout=subprocess.PIPE, check=True, text=True)
    return path


def age(path, seconds):
    path.touch()
    stamp = int(time.time()) - seconds
    os.utime(path, (stamp, stamp))


def ready(label, path, *, binary=None, settings=None,
          state='down', reason=None, can=False):
    env = ENV | {'FM_HOME': str(path)} | (settings or {})
    binary = binary or ROOT / 'bin/fm-inbox.sh'
    result = subprocess.run(['bash', str(binary), 'ready'], cwd=ROOT,
                            env=env, capture_output=True, text=True, timeout=10)
    record('\nCASE: ' + label)
    record('FM_HOME=' + str(path) + ' settings=' + json.dumps(settings or {}))
    record('COMMAND: bash ' + str(binary) + ' ready')
    record('EXIT: ' + str(result.returncode))
    record(result.stdout.rstrip())
    if result.stderr:
        record('STDERR: ' + result.stderr.rstrip())
    assert result.returncode == 0, label
    output = json.loads(result.stdout)
    observations.append({'case': label, 'settings': settings or {}, 'output': output})
    assert output['wake_consumer']['state'] == state, label
    if reason is not None:
        assert output['wake_consumer']['reason'] == reason, label
    assert output['can_receive'] == can, label
    return output


try:
    record('Real public readiness CLI against disposable marked FM_HOME directories.')
    record('Source: target adaf37f6; baseline inbox executable from base 20dcbf91.')
    record('The primary session lock uses a live, Claude-named Perl fixture process; no harness login or real fleet state is used.')
    record('The watcher is the real bin/fm-watch.sh process, with its real singleton lock and process identity.')
    record('Disposable root: ' + str(LAB))

    old_bin = LAB / 'baseline/bin'
    old_bin.mkdir(parents=True)
    for item in (ROOT / 'bin').iterdir():
        if item.name != 'fm-inbox.sh':
            (old_bin / item.name).symlink_to(item)
    baseline = old_bin / 'fm-inbox.sh'
    baseline.write_bytes(subprocess.check_output(
        ['git', 'show', '20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-inbox.sh'], cwd=ROOT))
    record('Baseline dependency scripts are linked to this worktree; the readiness dependencies used here retain the same behavioral contract across the range.')

    holder = subprocess.Popen(['perl', '-e', '$0="claude"; sleep 120'], env=ENV,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.2)
    incident = home('incident')
    state_dir = incident / 'state'
    (state_dir / '.lock').write_text(str(holder.pid) + '\n')
    (state_dir / '.watcher-down').write_text('acked:handling:ready-recovery\n')
    (state_dir / '.claude-autoarm-epoch').write_text(
        f'epoch=1 owner_pid={holder.pid} outcome=rewake session_pid={holder.pid} recovery_generation=ready-recovery\n')
    age(state_dir / '.last-watcher-beat', 3603)
    before = ready('baseline: stale 3603-second beacon, no watcher, old rewake record', incident,
                   binary=baseline, settings={'FM_SUPERVISION_MODEL': 'autoarm'},
                   state='healthy', reason='supervised', can=True)
    assert before['wake_consumer']['beacon_age_seconds'] >= 3603
    after = ready('target: identical stale 3603-second beacon is refused', incident,
                  settings={'FM_SUPERVISION_MODEL': 'autoarm'}, reason='stale-beacon')
    assert after['wake_consumer']['beacon_age_seconds'] >= 3603
    for model in ('autoarm', 'extension', 'persistent'):
        age(state_dir / '.last-watcher-beat', 0)
        ready('fresh beacon without watcher: ' + model, incident,
              settings={'FM_SUPERVISION_MODEL': model}, reason='no-watcher')

    live_home = home('live-watcher')
    live_state = live_home / 'state'
    (live_state / '.lock').write_text(str(holder.pid) + '\n')
    (live_state / 'home-summary.json').write_text('{}\n')
    watch_log = (EVIDENCE / 'readiness-real-watcher.txt').open('w')
    watcher = subprocess.Popen(['bash', 'bin/fm-watch.sh'], cwd=ROOT,
                               env=ENV | {'FM_HOME': str(live_home), 'FM_POLL': '1',
                                          'FM_CHECK_INTERVAL': '999999', 'FM_HEARTBEAT': '999999',
                                          'FM_HOME_SUMMARY_INTERVAL': '999999'},
                               stdin=subprocess.DEVNULL, stdout=watch_log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + 10
    while not ((live_state / '.watch.lock/pid-identity').exists()
               and (live_state / '.last-watcher-beat').exists()):
        assert watcher.poll() is None, 'real watcher exited before publishing its identity and beacon'
        assert time.monotonic() < deadline, 'real watcher startup deadline'
        time.sleep(0.05)
    record('\nREAL WATCHER PID: ' + str(watcher.pid))
    record('RECORDED WATCHER PID: ' + (live_state / '.watch.lock/pid').read_text().strip())
    record('RECORDED WATCHER HOME: ' + (live_state / '.watch.lock/fm-home').read_text().strip())
    assert int((live_state / '.watch.lock/pid').read_text()) == watcher.pid
    for model in (None, 'autoarm', 'extension', 'persistent'):
        ready('fresh beacon with real watcher: ' + str(model), live_home,
              settings={} if model is None else {'FM_SUPERVISION_MODEL': model},
              state='healthy', reason='supervised', can=True)

    os.kill(watcher.pid, signal.SIGSTOP)
    record('\nWatcher deliberately stopped with SIGSTOP to prevent beacon refresh during age checks; its PID and identity remain live.')
    age(live_state / '.last-watcher-beat', 120)
    ready('120-second beacon outside guard grace 60', live_home,
          settings={'FM_GUARD_GRACE': '60'}, reason='stale-beacon')
    ready('same 120-second beacon inside guard grace 300', live_home,
          settings={'FM_GUARD_GRACE': '300'}, state='healthy', reason='supervised', can=True)
    ready('explicit watcher grace 60 overrides guard grace 300', live_home,
          settings={'FM_WATCHER_STALE_GRACE': '60', 'FM_GUARD_GRACE': '300'}, reason='stale-beacon')
    ready('explicit watcher grace 300 overrides guard grace 60', live_home,
          settings={'FM_WATCHER_STALE_GRACE': '300', 'FM_GUARD_GRACE': '60'},
          state='healthy', reason='supervised', can=True)
    age(live_state / '.last-watcher-beat', 500)
    ready('default 300-second grace rejects age 500', live_home, reason='stale-beacon')
    ready('poll-derived grace 660 accepts age 500 with poll 600', live_home,
          settings={'FM_POLL': '600'}, state='healthy', reason='supervised', can=True)
    age(live_state / '.last-watcher-beat', 660)
    ready('poll-derived grace rejects age at its 660-second boundary', live_home,
          settings={'FM_POLL': '600'}, reason='stale-beacon')

    age(live_state / '.last-watcher-beat', 0)
    foreign = home('foreign-home')
    (foreign / 'state/.lock').write_text(str(holder.pid) + '\n')
    shutil.copytree(live_state / '.watch.lock', foreign / 'state/.watch.lock')
    age(foreign / 'state/.last-watcher-beat', 0)
    ready('foreign live watcher lock and fresh beacon are refused', foreign, reason='no-watcher')
    identity_file = live_state / '.watch.lock/pid-identity'
    real_identity = identity_file.read_text()
    identity_file.write_text('different-start-time-and-command\n')
    ready('live watcher PID with mismatched identity is refused', live_home, reason='no-watcher')
    identity_file.write_text(real_identity)
    ready('restored real watcher identity is accepted', live_home,
          state='healthy', reason='supervised', can=True)

    os.kill(watcher.pid, signal.SIGCONT)
    watcher.terminate()
    watcher.wait(timeout=10)
    record('\nReal watcher exited; exit status: ' + str(watcher.returncode))
    age(live_state / '.last-watcher-beat', 0)
    ready('fresh leftover beacon after watcher exit is refused', live_home, reason='no-watcher')
    empty = home('no-beacon')
    missing = ready('missing beacon reports null age', empty, reason='no-beacon')
    assert missing['wake_consumer']['beacon_age_seconds'] is None
    record('\nAll target readiness outputs matched the independent expected state and can_receive values.')
finally:
    if watcher is not None and watcher.poll() is None:
        os.kill(watcher.pid, signal.SIGCONT)
        watcher.terminate()
        try:
            watcher.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(watcher.pid, signal.SIGKILL)
            watcher.wait(timeout=5)
    if holder is not None:
        holder.terminate()
        holder.wait(timeout=5)
    if watch_log is not None:
        watch_log.close()
    record('Cleanup: owned watcher and primary-lock fixture processes stopped and reaped.')
    record('Disposable root remains only until inspected and removed by the invoking test phase: ' + str(LAB))
    transcript.close()
    (EVIDENCE / 'readiness-observations.json').write_text(json.dumps(observations, indent=2) + '\n')
    print('Disposable root:', LAB)
    print('CLI observations:', len(observations))
    print('Transcript:', EVIDENCE / 'readiness-cli-transcript.txt')
