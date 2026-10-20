import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5C3XYXFM7NBK7ZVCGA9DWM2')
LAB = ROOT / '.nm-test-tmp/live-data-home'
PROJECT = LAB / 'projects/demo'
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in (
        'FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND',
        'BEADS_DIR', 'BEADS_DB', 'BR_DB', 'BEADS_JSONL', 'GIT_DIR', 'GIT_WORK_TREE',
    ):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='live@example.invalid',
           GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='live@example.invalid',
           TMPDIR=str(ROOT / '.nm-test-tmp'), PYTHONDONTWRITEBYTECODE='1',
           FM_TEARDOWN_DATA_STAGE_TIMEOUT='600', FM_TEARDOWN_DATA_EXPIRE_TIMEOUT='2',
           FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT='2', FM_TASK_DATA_SWEEP='on',
           FM_BACKLOG_ROW_TIMEOUT_SECS='60',
           DCG_HOOK_TIMEOUT_MS='20000')


def run(args, cwd=ROOT, expected=0, extra=None):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, cwd=cwd, env=ENV | (extra or {}), text=True,
                       capture_output=True, timeout=600)
    print(p.stdout + p.stderr, end='', flush=True)
    print('exit: ' + str(p.returncode), flush=True)
    assert p.returncode == expected, (args, p.returncode, expected)
    return p


def locked(action, task, *args, expected=0, extra=None):
    return run(['bash', EVIDENCE / 'rerun-locked-taskdata.sh', action, task, *args],
               expected=expected, extra=extra)


def state(task):
    folder = LAB / 'data' / task
    record = folder / 'record/data-cleanup.json'
    obj = json.loads(record.read_text()) if record.exists() else None
    value = {'task': task, 'meta_exists': (LAB / 'state' / (task + '.meta')).exists(),
             'files': sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file()),
             'cleanup_record': obj}
    print(json.dumps(value, indent=2), flush=True)
    return value


def seed(task):
    run(['tasks-axi', 'add', task, 'retirement validation', '--kind', 'ship',
         '--file', LAB / 'data/backlog.md'])
    run(['tasks-axi', 'start', task, '--file', LAB / 'data/backlog.md'])
    (LAB / 'state' / (task + '.meta')).write_text(
        'worktree=' + str(LAB / 'gone-copy') + '\nproject=' + str(PROJECT) +
        '\nkind=ship\nmode=local-only\nharness=codex\n')
    folder = LAB / 'data' / task
    folder.mkdir()
    (folder / 'brief.md').write_text('Retire the finished task.\n')
    return folder


def expire(task, expected=0):
    return run(['bash', ROOT / 'bin/fm-task-data-lib.sh', 'expire',
                LAB / 'data', LAB / 'state', task], expected=expected)


def expired(task):
    p = LAB / 'data' / task / 'record/data-cleanup.json'
    return p.exists() and json.loads(p.read_text()).get('expired') is True


def held(task):
    return LAB / 'data' / task / '.cleanup-hold'


def wait_for(predicate, message, limit=120):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(message)


if os.environ.get('LIVE_RESUME_AFTER_TIMEOUT') == '1':
    first = LAB / 'data/task-first'
    second = LAB / 'data/task-second'
    previous = state('task-first')
    bead = previous['cleanup_record']['sources'][0]['beads'][0]
    print('Resuming the same disposable live setup after a host-load timeout; first retirement already completed.', flush=True)
else:
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    (LAB / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "history/completed.md"\ndone_keep = 10\n')
    (LAB / 'history').mkdir()
    (LAB / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['git', 'init', '-q', '-b', 'main', PROJECT])
    run(['br', 'init', '--prefix', 'proof', '--json'], cwd=PROJECT)
    bead = json.loads(run(['br', 'create', 'Linked evidence', '-d', '[capture](proof.png)', '--json'], cwd=PROJECT).stdout)['id']
    print('Baseline: no pending task-data holds.', flush=True)
    assert run(['python3', ROOT / 'bin/fm-task-data.py', 'pending', LAB / 'data']).stdout == ''
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
    print('OBSERVED: teardown closed its task, kept evidence and held scratch; date-like strings did not become beads.', flush=True)
    second = seed('task-second')
    (second / 'fresh.bin').write_bytes(b'fresh recovery\x00')
(first / 'report.md').write_text('Finished report. [Attachment](linked.txt)\n[Late evidence](discard.bin)\n')
run([ROOT / 'bin/fm-teardown.sh', 'task-second'])
wait_for(lambda: expired('task-first'), 'first hold did not expire')
assert not held('task-first').exists()
assert (first / 'proof.png').exists() and (first / 'linked.txt').exists()
assert (first / 'discard.bin').read_bytes() == b'one recovery cycle\x00'
assert (held('task-second') / 'fresh.bin').exists()
state('task-first')
state('task-second')
print('OBSERVED: the next completion restored late-linked evidence and preserved its own fresh recovery.', flush=True)

archive = LAB / 'data/task-archived'
archive.mkdir()
(archive / 'row.png').write_bytes(b'row evidence\x00')
(archive / 'proof.png').write_bytes(b'bead evidence\x00')
(archive / 'scratch.bin').write_bytes(b'scratch\x00')
(LAB / 'history/completed.md').write_text('## Archived 2026-10-11\n- [x] task-archived - finished (repo: demo) (done 2026-10-11)\n  [capture](row.png)\n  Bead ' + bead + '\n')
locked('prepare', 'task-archived')
expire('task-archived')
assert (archive / 'row.png').exists() and (archive / 'proof.png').exists()
assert not (archive / 'scratch.bin').exists() and expired('task-archived')
state('task-archived')
print('OBSERVED: archived backlog and real Beads references retained both images while scratch expired.', flush=True)

unread_project = LAB / 'projects/unread'
run(['git', 'init', '-q', '-b', 'main', unread_project])
run(['br', 'init', '--prefix', 'proof', '--json'], cwd=unread_project)
collision = LAB / 'data' / bead
(collision / '.cleanup-hold').mkdir(parents=True)
(collision / 'record').mkdir()
(collision / '.cleanup-hold/proof.png').write_bytes(b'colliding bead evidence\x00')
(collision / '.cleanup-hold/scratch.bin').write_bytes(b'scratch\x00')
(collision / 'record/data-cleanup.json').write_text(json.dumps({
    'version': 1, 'task': bead, 'complete': True, 'expired': False,
    'sources': [{'project': str(unread_project), 'pr': '', 'beads': [],
                 'backlog': {'data': str(LAB / 'data'), 'task': bead}}]}))
with (LAB / 'history/completed.md').open('a') as f:
    f.write('- [x] ' + bead + ' - finished (repo: unread) (done 2026-10-11)\n  Bead ' + bead + '\n')
expire(bead, expected=1)
before = (LAB / 'state' / (bead + '.status')).read_text()
expire(bead, expected=1)
assert (LAB / 'state' / (bead + '.status')).read_text() == before
record = state(bead)['cleanup_record']
assert record['sources'][0]['unread'] == [bead] and not record['expired']
assert (collision / '.cleanup-hold/proof.png').read_bytes() == b'colliding bead evidence\x00'
assert (collision / '.cleanup-hold/scratch.bin').exists()
print('OBSERVED: an archived row could not clear an unread bead with the same id; recovery stayed intact and the warning was written once.', flush=True)
run(['br', 'sync', '--flush-only'], cwd=PROJECT)
shutil.copyfile(PROJECT / '.beads/issues.jsonl', unread_project / '.beads/issues.jsonl')
run(['br', 'sync', '--import-only'], cwd=unread_project)
expire(bead)
assert expired(bead) and not held(bead).exists()
assert (collision / 'proof.png').read_bytes() == b'colliding bead evidence\x00'
assert not (collision / 'scratch.bin').exists()
state(bead)
print('OBSERVED: after the real bead became readable, retry restored its image and deleted only scratch.', flush=True)

old = LAB / 'data/old-big'
old.mkdir()
(old / 'scratch.bin').write_bytes(b'\0' * (8 * 1024 * 1024))
locked('stage', 'old-big', PROJECT, '')
locked('mark', 'old-big', 'too-large')
third = seed('task-third')
(third / 'fresh.bin').write_bytes(b'new recovery\x00')
run([ROOT / 'bin/fm-teardown.sh', 'task-third'])
wait_for(lambda: expired('old-big'), 'background sweep did not drain too-large hold')
assert not held('old-big').exists()
assert (held('task-third') / 'fresh.bin').exists()
state('old-big')
state('task-third')
print('OBSERVED: the background sweep reclaimed an older 8 MiB too-large hold without another completion and preserved the requester.', flush=True)

(LAB / 'state/task-third.meta').write_text('kind=ship\nproject=' + str(PROJECT) + '\n')
expire('task-third', expected=1)
assert (held('task-third') / 'fresh.bin').exists()
(LAB / 'state/task-third.meta').rename(LAB / 'state/task-third.meta.saved')
lock = LAB / 'state/.meta-task-third.lock'
lock.mkdir()
(lock / 'pid').write_text(str(os.getpid()) + '\n')
expire('task-third', expected=1)
assert (held('task-third') / 'fresh.bin').exists()
lock.rename(LAB / 'state/.meta-task-third.lock.checked')
denied = locked('expire', 'task-third', expected=1, extra={'LIVE_WITHOUT_DCG': '1'})
assert 'dcg is unavailable' in denied.stdout + denied.stderr
assert (held('task-third') / 'fresh.bin').read_bytes() == b'new recovery\x00'
print('OBSERVED: expiry refused a live task, another live process lock, and an unavailable deletion guard, preserving recovery bytes.', flush=True)
print('LIVE_DATA_RESULT: pass', flush=True)
