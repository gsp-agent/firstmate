import json
import os
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5C3XYXFM7NBK7ZVCGA9DWM2')
LAB = ROOT / '.nm-live-test' / 'data-home'
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in (
        'FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND',
        'BEADS_DIR', 'BEADS_DB', 'BR_DB', 'GIT_DIR', 'GIT_WORK_TREE',
    ):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='live@example.invalid',
           GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='live@example.invalid',
           TMPDIR=str(ROOT / '.nm-live-test' / 'tmp'),
           FM_TEARDOWN_DATA_STAGE_TIMEOUT='60', FM_TEARDOWN_DATA_EXPIRE_TIMEOUT='2',
           FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT='2')

def run(args, cwd=ROOT, expected=0):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, cwd=cwd, env=ENV, text=True, capture_output=True, timeout=120)
    print(p.stdout, end='', flush=True)
    if p.stderr:
        print(p.stderr, end='', flush=True)
    print('exit: ' + str(p.returncode), flush=True)
    if expected is not None:
        assert p.returncode == expected, (args, p.returncode, expected)
    return p

def state(task):
    folder = LAB / 'data' / task
    record = folder / 'record/data-cleanup.json'
    obj = json.loads(record.read_text()) if record.exists() else None
    value = {'task': task, 'meta_exists': (LAB / 'state' / (task + '.meta')).exists(),
             'files': sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file()),
             'cleanup_record': obj}
    print(json.dumps(value, indent=2), flush=True)
    return value

def seed(task, description='retirement validation'):
    run(['tasks-axi', 'add', task, description, '--kind', 'ship', '--file', LAB / 'data/backlog.md'])
    run(['tasks-axi', 'start', task, '--file', LAB / 'data/backlog.md'])
    (LAB / 'state' / (task + '.meta')).write_text(
        'worktree=' + str(LAB / 'gone-copy') + '\nproject=' + str(PROJECT) +
        '\nkind=ship\nmode=local-only\nharness=codex\n')
    folder = LAB / 'data' / task
    folder.mkdir()
    (folder / 'brief.md').write_text('Retire the finished task.\n')
    return folder

def expire(task, expected=0):
    return run(['bash', ROOT / 'bin/fm-task-data-lib.sh', 'expire', LAB / 'data', LAB / 'state', task], expected=expected)

def wait_for(predicate, message, limit=90):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(message)

def expired(task):
    p = LAB / 'data' / task / 'record/data-cleanup.json'
    return p.exists() and json.loads(p.read_text()).get('expired') is True

def held(task):
    return LAB / 'data' / task / '.cleanup-hold'

run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
(LAB / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "history/completed.md"\ndone_keep = 10\n')
(LAB / 'history').mkdir()
(LAB / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
PROJECT = LAB / 'projects/demo'
run(['git', 'init', '-q', '-b', 'main', PROJECT])
run(['br', 'init', '--prefix', 'proof', '--json'], cwd=PROJECT)
bead = json.loads(run(['br', 'create', 'Linked evidence', '-d', '[capture](proof.png)', '--json'], cwd=PROJECT).stdout)['id']
print('Baseline: no pending task-data holds.', flush=True)
run(['python3', ROOT / 'bin/fm-task-data.py', 'pending', LAB / 'data'])

first = seed('task-first')
(first / 'brief.md').write_text('Bead ' + bead + '\nBead 09-30\nBead 2026-09-29T21\nbeads-workflow\n')
(first / 'report.md').write_text('Finished report. [Attachment](linked.txt)\n')
(first / 'linked.txt').write_text('Keep this linked text.\n')
(first / 'proof.png').write_bytes(b'local bead image evidence\x00')
(first / 'discard.bin').write_bytes(b'one recovery cycle\x00')
run([ROOT / 'bin/fm-teardown.sh', 'task-first'])
s = state('task-first')
assert not s['meta_exists']
assert (held('task-first') / 'discard.bin').exists()
assert (first / 'proof.png').exists() and (first / 'report.md').exists()
assert s['cleanup_record']['sources'][0]['beads'] == [bead]
run(['tasks-axi', 'show', 'task-first', '--file', LAB / 'data/backlog.md', '--full'])
print('OBSERVED: retirement closed its backlog item, kept linked evidence, and held scratch for recovery.', flush=True)

second = seed('task-second')
(second / 'fresh.bin').write_bytes(b'fresh recovery\x00')
run([ROOT / 'bin/fm-teardown.sh', 'task-second'])
wait_for(lambda: expired('task-first'), 'first hold did not expire')
assert not held('task-first').exists()
assert (first / 'proof.png').exists() and (first / 'linked.txt').exists()
assert (held('task-second') / 'fresh.bin').exists()
state('task-first')
state('task-second')
print('OBSERVED: the next completed task expired old scratch and preserved its own fresh recovery.', flush=True)

archive = LAB / 'data/task-archived'
archive.mkdir()
(archive / 'row.png').write_bytes(b'row evidence\x00')
(archive / 'proof.png').write_bytes(b'bead evidence\x00')
(archive / 'scratch.bin').write_bytes(b'scratch\x00')
(LAB / 'history/completed.md').write_text('## Archived 2026-10-11\n- [x] task-archived - finished (repo: demo) (done 2026-10-11)\n  [capture](row.png)\n  Bead ' + bead + '\n')
run(['python3', ROOT / 'bin/fm-task-data.py', 'prepare', LAB / 'data', LAB / 'state', 'task-archived'])
expire('task-archived')
assert (archive / 'row.png').exists() and (archive / 'proof.png').exists()
assert not (archive / 'scratch.bin').exists() and expired('task-archived')
state('task-archived')
print('OBSERVED: archived backlog and real Beads references retained both images while scratch expired.', flush=True)

missing = LAB / 'data/proof-missing'
missing.mkdir()
(missing / 'proof.png').write_bytes(b'unread named-bead evidence\x00')
(missing / 'scratch.bin').write_bytes(b'scratch\x00')
with (LAB / 'history/completed.md').open('a') as f:
    f.write('- [x] proof-missing - finished (repo: demo) (done 2026-10-11)\n  Bead proof-missing\n')
run(['python3', ROOT / 'bin/fm-task-data.py', 'prepare', LAB / 'data', LAB / 'state', 'proof-missing'])
expire('proof-missing', expected=1)
status_before = (LAB / 'state/proof-missing.status').read_text()
expire('proof-missing', expected=1)
assert (LAB / 'state/proof-missing.status').read_text() == status_before
assert (missing / 'proof.png').exists() and (missing / 'scratch.bin').exists()
assert not held('proof-missing').exists()
value = state('proof-missing')['cleanup_record']
assert value['sources'][0]['unread'] == ['proof-missing']
print('OBSERVED: an unread bead with the task’s own id retained the whole folder and emitted its durable note once.', flush=True)

old = LAB / 'data/old-big'
old.mkdir()
(old / 'scratch.bin').write_bytes(b'\0' * (8 * 1024 * 1024))
run(['python3', ROOT / 'bin/fm-task-data.py', 'stage', LAB / 'data', LAB / 'state', 'old-big', PROJECT, ''])
run(['python3', ROOT / 'bin/fm-task-data.py', 'mark', LAB / 'data', 'old-big', 'too-large'])
third = seed('task-third')
(third / 'fresh.bin').write_bytes(b'new recovery\x00')
run([ROOT / 'bin/fm-teardown.sh', 'task-third'])
wait_for(lambda: expired('old-big'), 'background sweep did not drain too-large hold')
assert not held('old-big').exists()
assert (held('task-third') / 'fresh.bin').exists()
state('old-big')
state('task-third')
print('OBSERVED: after foreground skipped a too-large hold, the background sweep reclaimed its 8 MiB without another completion.', flush=True)

# Exercise guards against active tasks and a lock actually owned by this process.
(LAB / 'state/task-third.meta').write_text('kind=ship\nproject=' + str(PROJECT) + '\n')
expire('task-third', expected=1)
assert (held('task-third') / 'fresh.bin').exists()
(LAB / 'state/task-third.meta').rename(LAB / 'state/task-third.meta.saved')
lock = LAB / 'state/.meta-task-third.lock'
lock.mkdir()
(lock / 'pid').write_text(str(os.getpid()) + '\n')
expire('task-third', expected=1)
assert (held('task-third') / 'fresh.bin').exists()
print('OBSERVED: manual expiry refused both a live task and a task lock owned by another live process; recovery bytes stayed intact.', flush=True)
print('LIVE_DATA_RESULT: pass', flush=True)
