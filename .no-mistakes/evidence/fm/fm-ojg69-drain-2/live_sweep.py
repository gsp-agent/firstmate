import json
import os
from pathlib import Path
import signal
import subprocess
import time

root = Path.cwd()
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5ZBADZ07E6NXTYMA3FNF2')
log = (evidence / 'live-sweep.log').open('w', buffering=1)
home = root / '.test-phase-tmp/live-sweep'
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key)
subprocess.run(['bin/fm-lab-home.sh', 'create', str(home)], env=env, check=True, stdout=log, stderr=log)
env['FM_HOME'] = str(home)
(home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')

def hold(ident, complete, count):
    task = home / 'data' / ident
    (task / 'record').mkdir(parents=True)
    location = task / '.cleanup-hold' if complete else task
    location.mkdir(exist_ok=True)
    for n in range(count):
        (location / f'scratch-{n:05d}.bin').write_bytes(b'disposable\n')
    record = {'version': 1, 'task': ident, 'complete': complete, 'expired': False,
              'expiry': 'too-large', 'sources': [{'project': '', 'pr': '', 'beads': []}]}
    (task / 'record/data-cleanup.json').write_text(json.dumps(record))

hold('aa-drain', True, 5000)
hold('bb-unstaged', False, 1)
hold('latest-l1', True, 1)
(home / 'state/.task-data-sweep.rerun').write_text('latest-l1\n')
command = ['bash', 'bin/fm-task-data-lib.sh', 'sweep', str(home / 'data'), str(home / 'state')]
first = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
child = None
try:
    end = time.monotonic() + 30
    while time.monotonic() < end and first.poll() is None:
        children = subprocess.run(['pgrep', '-P', str(first.pid)], text=True, capture_output=True).stdout.split()
        if children:
            rows = subprocess.run(['ps', '-p', ','.join(children), '-o', 'pid=,command='], text=True, capture_output=True).stdout
            for row in rows.splitlines():
                pid, command_line = row.strip().split(None, 1)
                if '/fm-task-data.py expire ' in command_line and 'aa-drain' in command_line:
                    child = int(pid)
                    os.kill(child, signal.SIGSTOP)
                    break
        if child:
            break
        time.sleep(.01)
    assert child, 'real expiry process was never observed'
    log.write('Paused the real expiry process with its per-task lock and sweep lock held.\n')
    second = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
    log.write('$ ' + ' '.join(command) + '\n' + second.stdout + second.stderr)
    assert second.returncode == 0
    assert 'already running' in second.stderr
    assert (home / 'state/.task-data-sweep.rerun').read_text() == 'latest-l1\n'
    os.kill(child, signal.SIGCONT)
    child = None
    assert first.wait(timeout=120) == 0
    for ident in ('aa-drain', 'bb-unstaged'):
        record = json.loads((home / f'data/{ident}/record/data-cleanup.json').read_text())
        assert record['expired'] is True
        assert not (home / f'data/{ident}/.cleanup-hold').exists()
        assert not (home / f'data/{ident}/scratch-00000.bin').exists()
        log.write(f'{ident}: expired=true, expiry mark cleared, all scratch removed.\n')
    assert (home / 'data/latest-l1/.cleanup-hold/scratch-00000.bin').exists()
    assert not (home / 'state/.task-data-sweep.lock').exists()
    log.write('latest-l1: newest recovery unchanged. Both locks released.\nPASS: one real sweep drains staged and unstaged too-large holds; a concurrent explicit request starts no second sweep.\n')
finally:
    if child:
        os.kill(child, signal.SIGCONT)
    if first.poll() is None:
        os.killpg(first.pid, signal.SIGTERM)
        first.wait(timeout=10)
