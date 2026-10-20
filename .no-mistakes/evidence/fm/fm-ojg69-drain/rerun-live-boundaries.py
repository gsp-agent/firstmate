import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess

ROOT = Path.cwd()
OUT = Path('/Users/dalecarman/.no-mistakes/evidence/01M5C3XYXFM7NBK7ZVCGA9DWM2')
LAB = ROOT / '.nm-test-tmp/live-boundary-home'
PROJECT = LAB / 'projects/demo'
SUFFIX = os.environ.get('LIVE_BOUNDARY_SUFFIX', '')
DEADLINE_ID = 'deadline-task' + SUFFIX
LINKED_ID = 'linked-task' + SUFFIX
OVERSIZED_ID = 'oversized-task' + SUFFIX
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in (
        'FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND',
        'BEADS_DIR', 'BEADS_DB', 'BR_DB', 'BEADS_JSONL', 'GIT_DIR', 'GIT_WORK_TREE',
    ):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.nm-test-tmp'),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           FM_TEARDOWN_DATA_STAGE_TIMEOUT='600', FM_BACKLOG_ROW_TIMEOUT_SECS='60')


def run(args, cwd=ROOT, expected=0, extra=None):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    result = subprocess.run(args, env=ENV | (extra or {}), cwd=cwd, text=True,
                            capture_output=True, timeout=300)
    print(result.stdout + result.stderr, end='', flush=True)
    print('exit: ' + str(result.returncode), flush=True)
    assert result.returncode == expected, (result.returncode, expected)
    return result


def stage(task, expected=0, extra=None):
    return run(['bash', OUT / 'rerun-locked-taskdata.sh', 'stage', task, PROJECT, ''],
               expected=expected, extra=extra)


def verify_oversized():
    large = LAB / 'data' / OVERSIZED_ID
    stage(OVERSIZED_ID)
    record = json.loads((large / 'record/data-cleanup.json').read_text())
    print(json.dumps({'task': OVERSIZED_ID, 'brief_bytes': (large / 'brief.md').stat().st_size,
                      'cleanup_record': record}, indent=2), flush=True)
    assert not record['complete'] and any('brief.md' in source.get('unread', []) for source in record['sources'])
    assert (large / 'scratch.bin').read_bytes() == b'whole folder retry\x00'
    assert not (large / '.cleanup-hold').exists()
    print('OBSERVED: an oversized retained evidence file was named in the retry record and the whole task folder stayed intact.', flush=True)


if os.environ.get('LIVE_VERIFY_OVERSIZED_ONLY') == '1':
    verify_oversized()
    print('LIVE_OVERSIZED_RESULT: pass', flush=True)
    raise SystemExit(0)


task = LAB / 'data' / DEADLINE_ID
if os.environ.get('LIVE_RESUME_BOUNDARIES') == '1':
    bead = (task / 'brief.md').read_text().split()[1]
    print('Re-driving the preserved setup with the documented warning-only staging-deadline exit status.', flush=True)
elif SUFFIX:
    bead = (LAB / 'data/deadline-task/brief.md').read_text().split()[1]
    task.mkdir()
    (task / 'brief.md').write_text('Bead ' + bead + '\n')
    (task / 'proof.png').write_bytes(b'linked evidence\x00')
    (task / 'scratch.bin').write_bytes(b'retry scratch\x00')
else:
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    (LAB / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (LAB / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['git', 'init', '-q', PROJECT])
    run(['br', 'init', '--prefix', 'proof', '--json'], cwd=PROJECT)
    bead = json.loads(run(['br', 'create', 'Deadline evidence', '-d', '[capture](proof.png)', '--json'], cwd=PROJECT).stdout)['id']
    task.mkdir()
    (task / 'brief.md').write_text('Bead ' + bead + '\n')
    (task / 'proof.png').write_bytes(b'linked evidence\x00')
    (task / 'scratch.bin').write_bytes(b'retry scratch\x00')
run(['br', 'show', bead, '--json'], cwd=PROJECT)
database, = (PROJECT / '.beads').glob('*.db')
with sqlite3.connect(database) as connection:
    connection.execute('PRAGMA journal_mode=DELETE')
    connection.execute('BEGIN EXCLUSIVE')
    print('A real disposable Beads database is exclusively locked while staging has a 1s deadline.', flush=True)
    stage(DEADLINE_ID, expected=0, extra={'FM_TEARDOWN_DATA_STAGE_TIMEOUT': '1'})
    connection.rollback()
record = json.loads((task / 'record/data-cleanup.json').read_text())
print(json.dumps({'task': DEADLINE_ID, 'cleanup_record': record}, indent=2), flush=True)
assert not record['complete'] and '1s' in record['retained']
assert (task / 'scratch.bin').read_bytes() == b'retry scratch\x00'
assert (task / 'proof.png').read_bytes() == b'linked evidence\x00'
assert not (task / '.cleanup-hold').exists()
stage(DEADLINE_ID)
assert (task / '.cleanup-hold/scratch.bin').read_bytes() == b'retry scratch\x00'
assert (task / 'proof.png').read_bytes() == b'linked evidence\x00'
print('OBSERVED: a blocked real evidence reader hit the staging deadline before any move; after unlocking it, retry staged scratch and kept linked evidence.', flush=True)

outside = LAB / ('outside-target' + SUFFIX)
outside.mkdir()
(outside / 'sentinel.bin').write_bytes(b'outside task directory\x00')
(LAB / 'data' / LINKED_ID).symlink_to(outside, target_is_directory=True)
stage(LINKED_ID, expected=1)
assert (LAB / 'data' / LINKED_ID).is_symlink()
assert (outside / 'sentinel.bin').read_bytes() == b'outside task directory\x00'
assert not (outside / '.cleanup-hold').exists()
print('OBSERVED: staging refused a symlinked task directory and left the target bytes untouched.', flush=True)

large = LAB / 'data' / OVERSIZED_ID
large.mkdir()
(large / 'brief.md').write_bytes(b'x' * (16 * 1024 * 1024 + 1))
(large / 'scratch.bin').write_bytes(b'whole folder retry\x00')
verify_oversized()
print('LIVE_BOUNDARIES_RESULT: pass', flush=True)
