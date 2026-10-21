import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5ZBADZ07E6NXTYMA3FNF2')
TRANSCRIPT = (EVIDENCE / 'live-retirement.log').open('w', buffering=1)
RESULTS = []
HOMES = []
BASE = os.environ.copy()
for key in list(BASE):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'BEADS_DIR', 'BEADS_DB', 'BR_DB', 'TMUX'):
        BASE.pop(key)
BASE['FM_TEARDOWN_DATA_STAGE_TIMEOUT'] = '600'
BASE['FM_BOOTSTRAP_NETWORK'] = 'skip'

def log(text):
    print(text, flush=True)
    TRANSCRIPT.write(text + '\n')

def run(args, env, expected=0, cwd=None):
    p = subprocess.run([str(x) for x in args], env=env, cwd=cwd or ROOT, text=True, capture_output=True, timeout=180)
    log('$ ' + ' '.join(str(x) for x in args))
    log(p.stdout + p.stderr)
    if expected is not None:
        assert p.returncode == expected, (args, p.returncode)
    return p

def wait_for(check, description, timeout=180):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return
        time.sleep(.03)
    raise AssertionError('Timed out: ' + description)

def home(label):
    path = ROOT / '.test-phase-tmp' / ('live-v2-' + label)
    run(['bin/fm-lab-home.sh', 'create', path], BASE)
    (path / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (path / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (path / 'projects/demo').mkdir()
    run(['tmux', '-S', 'sock', 'new-session', '-d', '-s', 'fm-lab-recovery'], BASE, cwd=path)
    HOMES.append(path)
    env = BASE | {'FM_HOME': str(path), 'TMUX': str(path.relative_to(ROOT) / 'sock') + ',0,0'}
    return path, env

def task(path, env, ident, count=1):
    run(['tasks-axi', 'add', ident, 'Disposable recovery check', '--kind', 'ship', '--file', path / 'data/backlog.md'], env, cwd=path)
    run(['tasks-axi', 'start', ident, '--file', path / 'data/backlog.md'], env, cwd=path)
    (path / f'state/{ident}.meta').write_text(f'window=primary:fm-{ident}\nendpoint_task_id={ident}\nworktree={path}/missing-{ident}\nproject={path}/projects/demo\nkind=ship\nmode=local-only\nspawn_gen=live-{ident}\n')
    meta = path / f'state/{ident}.meta'
    meta.write_text(meta.read_text().replace('window=primary:', 'window=fm-lab-recovery:'))
    run(['tmux', '-S', 'sock', 'new-window', '-d', '-t', 'fm-lab-recovery:', '-n', 'fm-' + ident], BASE, cwd=path)
    root = path / 'data' / ident
    root.mkdir()
    (root / 'report.md').write_text('Retained review text. Evidence: [proof](proof.png)\n')
    (root / 'proof.png').write_bytes(b'linked evidence\n')
    for n in range(count):
        (root / f'scratch-{n:05d}.bin').write_bytes(b'disposable recovery\n')

def receipt(path, ident):
    try:
        return json.loads((path / f'data/{ident}/record/data-cleanup.json').read_text())
    except (OSError, ValueError):
        return {}

def start_teardown(path, env, ident):
    out = (path / (ident + '.out')).open('w')
    err = (path / (ident + '.err')).open('w')
    p = subprocess.Popen([str(ROOT / 'bin/fm-teardown.sh'), ident], env=env, stdout=out, stderr=err, start_new_session=True)
    return p

def pause_retirement(path, ident, proc):
    found = []
    def check():
        if proc.poll() is not None:
            raise AssertionError(f'{ident} exited before retirement: ' + (path / (ident + '.err')).read_text())
        rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
        for row in rows.splitlines():
            pid, _, command = row.strip().partition(' ')
            if '/fm-task-data.py retire ' in command and str(path / 'data') in command and command.rstrip().endswith(' ' + ident):
                os.kill(int(pid), signal.SIGSTOP)
                found.append(int(pid))
                return True
        return False
    wait_for(check, ident + ' real retire process')
    assert (path / f'state/{ident}.meta').exists()
    log(f'Paused real retirement process for {ident}; existing metadata still protects it.')
    return found[0]

def finish(path, ident, proc, child=None, expected=0):
    if child:
        os.kill(child, signal.SIGCONT)
    rc = proc.wait(timeout=180)
    log('$ bin/fm-teardown.sh ' + ident)
    log((path / (ident + '.out')).read_text() + (path / (ident + '.err')).read_text())
    assert rc == expected, (ident, rc)

def sweep(path, env):
    return run(['bash', 'bin/fm-task-data-lib.sh', 'sweep', path / 'data', path / 'state'], env)

def settled(path, expired):
    wait_for(lambda: receipt(path, expired).get('expired') is True and not (path / 'state/.task-data-sweep.lock').exists(), 'sweep expires ' + expired)

def assert_newest(path, ident):
    assert (path / f'data/{ident}/.cleanup-hold/scratch-00000.bin').read_bytes() == b'disposable recovery\n'
    assert (path / f'data/{ident}/report.md').exists()
    assert (path / f'data/{ident}/proof.png').exists()
    assert (path / 'state/.task-data-sweep.rerun').read_text().strip() == ident
    assert not (path / f'state/{ident}.meta').exists()
    assert not (path / f'state/{ident}.backlog-close').exists()
    log(f'Persisted result: latest completion={ident}; newest scratch recovery intact; linked evidence and review retained; task and pending-close records removed.')

def passed(name):
    RESULTS.append({'name': name, 'result': 'pass'})
    log('PASS: ' + name)
    (EVIDENCE / 'live-retirement-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')

def overlap(order):
    path, env = home(order)
    task(path, env, 'prior-p1')
    p = start_teardown(path, env, 'prior-p1')
    finish(path, 'prior-p1', p)
    assert_newest(path, 'prior-p1')
    run(['python3', 'bin/fm-task-data.py', 'mark', path / 'data', 'prior-p1', 'too-large'], env)
    task(path, env, 'alpha-a1', 200)
    task(path, env, 'beta-b1', 200)
    a = start_teardown(path, env, 'alpha-a1')
    ac = pause_retirement(path, 'alpha-a1', a)
    b = start_teardown(path, env, 'beta-b1')
    bc = pause_retirement(path, 'beta-b1', b)
    assert (path / 'state/.task-data-sweep.rerun').read_text().strip() == 'prior-p1'
    if order == 'forward':
        first, fp, fc, last, lp, lc = 'alpha-a1', a, ac, 'beta-b1', b, bc
    else:
        first, fp, fc, last, lp, lc = 'beta-b1', b, bc, 'alpha-a1', a, ac
    finish(path, first, fp, fc)
    settled(path, 'prior-p1')
    assert (path / f'state/{last}.meta').exists()
    assert not receipt(path, last).get('expired')
    log(f'After {first} finishes: older recovery expired; unfinished {last} remains protected.')
    finish(path, last, lp, lc)
    settled(path, first)
    assert_newest(path, last)
    passed('overlapping completions in ' + order + ' order')

def failed_publication():
    path, env = home('publication-failure')
    task(path, env, 'prior-p1')
    p = start_teardown(path, env, 'prior-p1')
    finish(path, 'prior-p1', p)
    task(path, env, 'fresh-f1', 200)
    p = start_teardown(path, env, 'fresh-f1')
    child = pause_retirement(path, 'fresh-f1', p)
    (path / 'state').chmod(0o555)
    try:
        finish(path, 'fresh-f1', p, child, expected=1)
    finally:
        (path / 'state').chmod(0o755)
    assert (path / 'state/fresh-f1.meta').exists()
    assert (path / 'state/fresh-f1.backlog-close').exists()
    assert (path / 'state/.task-data-sweep.rerun').read_text().strip() == 'prior-p1'
    sweep(path, env)
    for command in (['bash', 'bin/fm-task-data-lib.sh'], ['python3', 'bin/fm-task-data.py']):
        run(command + ['expire', path / 'data', path / 'state', 'fresh-f1'], env, expected=1)
    assert (path / 'data/fresh-f1/.cleanup-hold/scratch-00000.bin').exists()
    p = start_teardown(path, env, 'fresh-f1')
    finish(path, 'fresh-f1', p)
    settled(path, 'prior-p1')
    assert_newest(path, 'fresh-f1')
    passed('failed publication retains protection; retry publishes before releasing it')

def replay():
    path, env = home('interrupted-replay')
    task(path, env, 'prior-p1')
    p = start_teardown(path, env, 'prior-p1')
    finish(path, 'prior-p1', p)
    task(path, env, 'replay-r1', 200)
    p = start_teardown(path, env, 'replay-r1')
    child = pause_retirement(path, 'replay-r1', p)
    os.kill(child, signal.SIGKILL)
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    assert (path / 'state/replay-r1.meta').exists()
    assert (path / 'state/replay-r1.backlog-close').exists()
    sweep(path, env)
    assert not receipt(path, 'replay-r1').get('expired')
    log('Interrupted actual retirement; pending-close record and metadata survive, sweep leaves the recovery untouched.')
    run(['bin/fm-bootstrap.sh'], env)
    sweep(path, env)
    assert_newest(path, 'replay-r1')
    settled(path, 'prior-p1')
    passed('session-start replays an interrupted retirement and preserves newest recovery')

try:
    overlap('reverse')
    overlap('forward')
    failed_publication()
    replay()
except BaseException as exc:
    log('FAIL: ' + repr(exc))
    raise
finally:
    for path in HOMES:
        run(['tmux', '-S', 'sock', 'kill-server'], BASE, expected=None, cwd=path)
