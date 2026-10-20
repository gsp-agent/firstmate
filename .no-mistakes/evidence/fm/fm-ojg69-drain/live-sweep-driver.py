import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

ROOT = Path.cwd()
LAB = ROOT / '.nm-live-test/sweep-home-budget'
OUT = Path('/Users/dalecarman/.no-mistakes/evidence/01M5C3XYXFM7NBK7ZVCGA9DWM2')
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'FM_GATE_REFUSE_BYPASS', 'GIT_DIR', 'GIT_WORK_TREE'):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           TMPDIR=str(ROOT / '.nm-live-test/tmp'), DCG_HOOK_TIMEOUT_MS='20000')
print('Disposable-process setup: DCG_HOOK_TIMEOUT_MS=20000; enabled guard rules and allowlists are unchanged.', flush=True)

def run(args):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, env=ENV, text=True, capture_output=True, timeout=120)
    print(p.stdout + p.stderr, end='', flush=True)
    print('exit: ' + str(p.returncode), flush=True)
    assert p.returncode == 0
    return p.stdout + p.stderr

def receipt(task):
    return LAB / 'data' / task / 'record/data-cleanup.json'

def write_hold(task, count=1):
    folder = LAB / 'data' / task
    (folder / '.cleanup-hold').mkdir(parents=True)
    (folder / 'record').mkdir()
    for i in range(count):
        (folder / '.cleanup-hold' / ('scratch-' + str(i) + '.bin')).write_bytes(b'x' * 128)
    receipt(task).write_text(json.dumps({'version': 1, 'task': task, 'complete': True, 'expired': False,
        'sources': [{'project': str(LAB / 'projects/demo'), 'pr': '', 'beads': [],
                     'backlog': {'data': str(LAB / 'data'), 'task': None}}]}))

run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
run(['git', 'init', '-q', LAB / 'projects/demo'])
write_hold('aa-old', 512)
print('Baseline: aa-old has 512 held files (65536 bytes), no task metadata.', flush=True)
args = ['bash', str(ROOT / 'bin/fm-task-data-lib.sh'), 'sweep', str(LAB / 'data'), str(LAB / 'state'), 'previous-task']
print('$ ' + shlex.join(args), flush=True)
with (OUT / 'live-sweep-budget-first-process.log').open('w') as log:
    first = subprocess.Popen(args, env=ENV, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (LAB / 'state/.task-data-sweep.lock').is_dir() and (LAB / 'state/.meta-aa-old.lock').is_dir():
                break
            assert first.poll() is None, 'the sweep completed before its overlapping request could be driven'
            time.sleep(.02)
        else:
            raise AssertionError('the first sweep did not acquire its locks')
        write_hold('bb-arrived-after-snapshot')
        write_hold('fresh-requester')
        response = run(['bash', ROOT / 'bin/fm-task-data-lib.sh', 'sweep', LAB / 'data', LAB / 'state', 'fresh-requester'])
        assert 'already running' in response
        assert first.wait(timeout=300) == 0
    finally:
        if first.poll() is None:
            os.killpg(first.pid, signal.SIGTERM)
            first.wait(timeout=10)

for task, expected in [('aa-old', True), ('bb-arrived-after-snapshot', True), ('fresh-requester', False)]:
    obj = json.loads(receipt(task).read_text())
    count = sum(1 for p in (LAB / 'data' / task / '.cleanup-hold').glob('*'))
    print(json.dumps({'task': task, 'expired': obj.get('expired'), 'held_files': count}), flush=True)
    assert obj.get('expired') is expected
assert (LAB / 'state/.task-data-sweep.rerun').read_text().strip() == 'fresh-requester'
assert not (LAB / 'state/.task-data-sweep.lock').exists()
print('OBSERVED: a second request joined the real running sweep; its added older hold expired, its fresh recovery survived, and every sweep lock was released.', flush=True)
print('LIVE_SWEEP_RESULT: pass', flush=True)
