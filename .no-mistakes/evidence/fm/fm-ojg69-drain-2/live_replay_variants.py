import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5ZBADZ07E6NXTYMA3FNF2')
log = (evidence / 'live-replay-variants.log').open('w', buffering=1)
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX'):
        env.pop(key)
env['FM_BOOTSTRAP_NETWORK'] = 'skip'
env['FM_TEARDOWN_DATA_STAGE_TIMEOUT'] = '600'

def run(args, local_env, expected=0, cwd=None):
    result = subprocess.run([str(x) for x in args], env=local_env, cwd=cwd or root, capture_output=True, text=True, timeout=180)
    log.write('$ ' + ' '.join(str(x) for x in args) + '\n' + result.stdout + result.stderr)
    assert result.returncode == expected, (args, result.returncode)
    return result

script = root / '.test-phase-tmp/prepare-interrupted.sh'
script.write_text('''#!/usr/bin/env bash
set -eu
root=$1 home=$2 mode=$3 absent=$4
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-tasks-axi-lib.sh"
. "$root/bin/fm-backlog-transition-lib.sh"
lock=$(fm_meta_lock_path "$home/state/replay-r1.meta")
fm_lock_acquire_wait "$lock"
trap 'fm_lock_release "$lock"' EXIT
flags=()
[ "$mode" = close ] || flags=(--retain)
fm_backlog_close_marker_write "$home/state" replay-r1 "$home/data" live-replay "${flags[@]+"${flags[@]}"}" --note 'local main'
python3 "$root/bin/fm-task-data.py" prepare "$home/data" "$home/state" replay-r1
''')

for mode, absent in [('close', True), ('retain', False), ('retain', True)]:
    label = mode + ('-absent' if absent else '-metadata')
    home = root / '.test-phase-tmp' / ('live-replay-' + label)
    run(['bin/fm-lab-home.sh', 'create', home], env)
    local_env = env | {'FM_HOME': str(home)}
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    (home / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi', 'add', 'replay-r1', 'Interrupted recovery fixture', '--kind', 'ship', '--file', home / 'data/backlog.md'], local_env, cwd=home)
    run(['tasks-axi', 'start', 'replay-r1', '--file', home / 'data/backlog.md'], local_env, cwd=home)
    (home / 'state/replay-r1.meta').write_text('kind=ship\nmode=local-only\nspawn_gen=live-replay\nproject=\n')
    task = home / 'data/replay-r1'
    task.mkdir()
    (task / 'scratch.bin').write_bytes(b'pending replay recovery\n')
    (task / 'review.md').write_text('Retained review text.\n')
    run(['bash', script, root, home, mode, str(int(absent))], local_env)
    if absent:
        command = ['rm', '-f', '--', str(home / 'state/replay-r1.meta')]
        import shlex
        payload = {'tool_name': 'Bash', 'tool_input': {'command': shlex.join(command)}}
        guard = subprocess.run(['dcg'], input=json.dumps(payload), capture_output=True, text=True, env=local_env)
        assert guard.returncode == 0
        if guard.stdout.strip():
            assert json.loads(guard.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'allow'
        run(command, local_env)
    run(['bash', 'bin/fm-task-data-lib.sh', 'sweep', home / 'data', home / 'state'], local_env)
    assert (task / 'scratch.bin').read_bytes() == b'pending replay recovery\n'
    log.write(f'{label}: pending-close protection keeps scratch before session-start recovery.\n')
    run(['bin/fm-bootstrap.sh'], local_env)
    run(['bash', 'bin/fm-task-data-lib.sh', 'sweep', home / 'data', home / 'state'], local_env)
    assert (task / '.cleanup-hold/scratch.bin').read_bytes() == b'pending replay recovery\n'
    assert (task / 'review.md').exists()
    assert (home / 'state/.task-data-sweep.rerun').read_text().strip() == 'replay-r1'
    assert not (home / 'state/replay-r1.meta').exists()
    assert not (home / 'state/replay-r1.backlog-close').exists()
    row = run(['tasks-axi', 'show', 'replay-r1', '--file', home / 'data/backlog.md'], local_env, cwd=home).stdout
    assert ('state: done' if mode == 'close' else 'state: queued') in row
    log.write(f'PASS: {label} replay publishes the latest completion, removes pending protection and preserves fresh recovery.\n')
