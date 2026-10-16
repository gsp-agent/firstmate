#!/usr/bin/env python3
"""Drive the real cleanup CLI with disposable worktree-local homes and real tools."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import unicodedata

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
BASE = ROOT / '.validation-task-data' / 'live'
BASE.mkdir(parents=True, exist_ok=True)
RESULTS = []
ENV = {key: value for key, value in os.environ.items()
       if not (key.startswith('FM_') or key.startswith('TASKS_AXI_')
               or key.startswith('BEADS_') or key in ('TMUX', 'TMUX_PANE', 'HERDR_SESSION',
                                                    'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE'))}
ENV.update(TMPDIR=str(ROOT / '.validation-task-data' / 'tmp'),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')

def run(args, env=None, cwd=ROOT, expected=0):
    print('$ ' + shlex.join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env or ENV,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=100)
    print(result.stdout.rstrip(), flush=True)
    print('exit=' + str(result.returncode), flush=True)
    if expected is not None:
        assert result.returncode == expected, result.stdout
    return result

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        path.write_text(data)
    else:
        path.write_bytes(data)

def executable(path, body):
    write(path, body)
    path.chmod(0o755)

def home(name):
    lab = BASE / name
    run(['bash', ROOT / 'bin/fm-lab-home.sh', 'create', lab])
    write(lab / '.tasks.toml', 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    env = dict(ENV, FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'))
    (lab / 'tmux').mkdir()
    write(lab / 'config/backend', 'tmux\n')
    project = lab / 'projects/example'
    project.mkdir()
    run(['git', 'init', '-q', project], env)
    # This scopes the unrelated global orphan sweep to this disposable home.
    # Every other process query delegates to the installed ps; no fleet worker
    # can be selected or signalled by this test.
    real_ps = shutil.which('ps')
    executable(lab / 'tools/ps', '#!/usr/bin/env python3\nimport subprocess,sys\n'
               f'r=subprocess.run([{real_ps!r}, *sys.argv[1:]],capture_output=True)\n'
               "if '-u' in sys.argv and 'pid=,command=' in sys.argv:\n"
               f" r.stdout=b'\\n'.join(line for line in r.stdout.splitlines() if {str(lab).encode()!r} in line)\n"
               'sys.stdout.buffer.write(r.stdout)\nsys.stderr.buffer.write(r.stderr)\nsys.exit(r.returncode)\n')
    real_guard = shutil.which('dcg')
    executable(lab / 'tools/dcg', '#!/usr/bin/env python3\nimport json,subprocess,sys\n'
               'data=sys.stdin.read()\n'
               f'r=subprocess.run([{real_guard!r}],input=data,text=True,capture_output=True)\n'
               f'with open({str(EVIDENCE / "task-data-dcg.jsonl")!r},"a") as out:\n'
               ' out.write(json.dumps({"request":json.loads(data),"response":r.stdout,"stderr":r.stderr,"exit":r.returncode})+"\\n")\n'
               'sys.stdout.write(r.stdout)\nsys.stderr.write(r.stderr)\nsys.exit(r.returncode)\n')
    env['PATH'] = str(lab / 'tools') + os.pathsep + ENV['PATH']
    return lab, env, project

def task(lab, env, project, task_id, body=''):
    args = ['tasks-axi', 'add', task_id, 'Disposable cleanup validation', '--start']
    if body:
        args += ['--body', body]
    run(args, env, lab)
    # A finished worker whose endpoint and local copy are already gone is a
    # supported end-user cleanup case. No server, agent, pool or PR is created.
    write(lab / 'state' / (task_id + '.meta'),
          f'endpoint_task_id={task_id}\nworktree={lab}/missing-{task_id}\nproject={project}\nkind=ship\nmode=local-only\n')
    root = lab / 'data' / task_id
    root.mkdir(exist_ok=True)
    return root

def teardown(lab, env, task_id):
    return run(['bash', ROOT / 'bin/fm-teardown.sh', task_id], env, ROOT)

def measure(path):
    rows = []
    for file in path.rglob('*'):
        if file.is_file() and not file.is_symlink():
            stat = file.stat()
            rows.append((str(file.relative_to(path)), stat.st_size, stat.st_blocks * 512))
    return {'bytes': sum(row[1] for row in rows), 'allocated_bytes': sum(row[2] for row in rows), 'files': rows}

LOCK_DRIVER = EVIDENCE / 'task-data-locked.sh'
write(LOCK_DRIVER, '''#!/usr/bin/env bash
set -u
code=$1
action=$2
lab=$3
id=$4
shift 4
. "$code/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$lab/state/$id.meta") || exit 1
fm_lock_try_acquire "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
helper=${TASK_DATA_HELPER:-$code/bin/fm-task-data.py}
if [ -n "${TASK_DATA_CHILD_PATH:-}" ]; then
  env "PATH=$TASK_DATA_CHILD_PATH" python3 "$helper" "$action" "$lab/data" "$lab/state" "$id" "$@"
else
  python3 "$helper" "$action" "$lab/data" "$lab/state" "$id" "$@"
fi
''')

def cleanup(action, lab, env, task_id, project=None, pr='', expected=0):
    args = ['bash', LOCK_DRIVER, ROOT, action, lab, task_id]
    if action in ('prepare', 'stage'):
        args.extend([project, pr] if action == 'stage' else [pr])
    return run(args, env, expected=expected)

def record(name, details):
    print('OBSERVED: ' + name + '\n' + json.dumps(details, ensure_ascii=False, indent=2), flush=True)
    RESULTS.append({'name': name, 'details': details})
    (EVIDENCE / 'task-data-live-results.json').write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2) + '\n')

if __name__ == '__main__':
    lab, env, project = home('lifecycle')
    root = task(lab, env, project, 'proof-owner', '[owning task evidence](bead-artifacts/)')
    nfc, nfd = 'café', unicodedata.normalize('NFD', 'résumé')
    expected = {'proof(1).png': b'escaped image\x00\xff', 'capture.bin': b'symlink target\x00\xff',
                f'{nfc}/frame.bin': b'NFC directory evidence\x00\xff',
                f'{nfd}/frame.bin': b'NFD directory evidence\x00\xff',
                'bead-artifacts/frame.bin': b'owning task directory evidence\x00\xff',
                'single/capture.png': b'single image\x00\xff'}
    for rel, content in expected.items():
        write(root / rel, content)
    (root / nfc / 'member.bin').symlink_to(root / 'capture.bin')
    outside = lab / 'external-temp/proof-owner-scratch/keep.bin'
    write(outside, b'external scratch must remain\x00\xff')
    (root / nfc / 'external.bin').symlink_to(outside)
    write(root / 'report.md', rf'[escaped capture](proof\(1\).png) [NFC]({nfc}/) [NFD]({nfd}/) [one image](single/capture.png)' + '\n')
    write(root / 'brief.md', 'Finish this task.\n')
    write(root / 'record/status', 'durable record\n')
    write(root / 'unlinked.json', '{"safe conservative retention":true}\n')
    write(root / 'single/discard.bin', b'unlinked sibling')
    write(root / 'prose-only/blob.bin', b'not a directory link')
    write(root / 'later(1).png', b'late escaped link\x00\xff')
    write(root / 'later-artifacts/frame.bin', b'late directory evidence\x00\xff')
    write(root / 'scratch/blob.bin', b'\xa5' * (4 * 1024 * 1024))
    run(['git', 'init', '-q', root / 'clone'], env)
    write(root / 'clone/README.md', 'nested repository text is scratch\n')
    write(root / 'clone/build.bin', b'\x5a' * (2 * 1024 * 1024))
    initial = measure(root)
    teardown(lab, env, 'proof-owner')
    held = measure(root)
    assert not (lab / 'state/proof-owner.meta').exists()
    for rel, content in expected.items():
        assert (root / rel).read_bytes() == content, rel
    assert (root / '.cleanup-hold/scratch/blob.bin').read_bytes() == b'\xa5' * (4 * 1024 * 1024)
    assert (root / '.cleanup-hold/clone/README.md').is_file()
    assert (root / '.cleanup-hold/single/discard.bin').is_file()
    assert (root / 'unlinked.json').is_file() and (root / 'record/status').is_file()
    hold_inode = (root / '.cleanup-hold/scratch/blob.bin').stat().st_ino
    cleanup('stage', lab, env, 'proof-owner', project)
    assert (root / '.cleanup-hold/scratch/blob.bin').stat().st_ino == hold_inode
    record('Finished task holds original scratch for one cycle and preserves linked evidence',
           {'before': initial, 'staged': held, 'same_task_does_not_expire': True,
            'unchanged_sha256': {rel: hashlib.sha256(data).hexdigest() for rel, data in expected.items()}})

    # Make an active task with a staged recovery, then republish its live metadata.
    active = lab / 'data/active-owner'
    write(active / 'blob.bin', b'live recovery')
    cleanup('stage', lab, env, 'active-owner', project)
    write(lab / 'state/active-owner.meta', 'kind=ship\nspawn_gen=active-validation\n')
    report = root / 'report.md'
    report.write_text(report.read_text() + r' [late image](later\(1\).png) [late directory](later-artifacts/)' + '\n')
    task(lab, env, project, 'proof-next')
    teardown(lab, env, 'proof-next')
    final = measure(root)
    assert not (root / '.cleanup-hold').exists()
    assert not (root / 'scratch').exists() and not (root / 'clone').exists()
    assert not (root / 'single/discard.bin').exists()
    for rel, content in expected.items():
        assert (root / rel).read_bytes() == content, rel
    assert (root / 'later(1).png').read_bytes() == b'late escaped link\x00\xff'
    assert (root / 'later-artifacts/frame.bin').read_bytes() == b'late directory evidence\x00\xff'
    assert (root / nfc / 'member.bin').read_bytes() == expected['capture.bin']
    assert outside.read_bytes() == b'external scratch must remain\x00\xff'
    assert (active / '.cleanup-hold/blob.bin').read_bytes() == b'live recovery'
    assert held['bytes'] - final['bytes'] > 6 * 1024 * 1024
    record('A different task completion restores new links, expires scratch, and leaves live/external data intact',
           {'expired': final, 'reclaimed_bytes': held['bytes'] - final['bytes'],
            'newly_linked_files_restored': True, 'live_task_recovery_unchanged': True,
            'external_scratch_and_symlink_target_unchanged': True,
            'owning_backlog': run(['tasks-axi', 'show', 'proof-owner', '--full'], env, lab).stdout})

    # Guard availability and root ownership are actual executable refusal paths.
    guarded = lab / 'data/guard-owner'
    write(guarded / 'blob.bin', b'guarded original')
    cleanup('stage', lab, env, 'guard-owner', project)
    path_without_guard = lab / 'without-guard'
    path_without_guard.mkdir()
    for name in ('bash', 'python3', 'dirname', 'basename', 'cat', 'date', 'hostname', 'id', 'mkdir',
                 'mktemp', 'mv', 'readlink', 'rm', 'rmdir', 'tr', 'ps', 'stat', 'uname',
                 'awk', 'grep', 'head', 'sed', 'sort', 'wc', 'sleep', 'touch'):
        source = shutil.which(name)
        if source:
            (path_without_guard / name).symlink_to(source)
    missing_guard = dict(env, TASK_DATA_CHILD_PATH=str(path_without_guard))
    refusal = cleanup('expire', lab, missing_guard, 'guard-owner', expected=None)
    assert refusal.returncode != 0 and 'dcg is unavailable' in refusal.stdout
    assert (guarded / '.cleanup-hold/blob.bin').read_bytes() == b'guarded original'
    cleanup('expire', lab, env, 'guard-owner')
    assert not (guarded / '.cleanup-hold').exists()
    for task_id, phrase in (('active-owner', 'still live'), ('../external-temp', 'invalid task id')):
        refusal = cleanup('stage', lab, env, task_id, project, expected=None)
        assert refusal.returncode != 0 and phrase in refusal.stdout
    (lab / 'data/escaped').symlink_to(outside.parent, target_is_directory=True)
    refusal = cleanup('stage', lab, env, 'escaped', project, expected=None)
    assert refusal.returncode != 0 and 'not a real directory' in refusal.stdout
    assert outside.read_bytes() == b'external scratch must remain\x00\xff'
    record('Unavailable deletion guard and unsafe or live roots refuse without losing data',
           {'missing_guard_retained_original': True, 'real_guard_retry_succeeded': True,
            'live_task_traversal_and_symlink_escape_refused': True})

    print('LIVE_SCENARIOS_COMPLETE', flush=True)
