from pathlib import Path
import json
import os
import signal
import subprocess
import time

root = Path.cwd()
scratch = root / '.nm-live-yeldv-r4'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round4')
fixture = json.loads((evidence / 'fixture.json').read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_'))}
env.update(json.loads((evidence / 'env.json').read_text()))
slot = scratch / 'timeout-slot'
subprocess.run(['git', 'clone', '-q', '--filter=blob:none', Path(fixture['remote']).as_uri(), str(slot)], env=env, check=True)
remote = scratch / 'slow-upload-pack.sh'
remote.write_text('''#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >> "$FM_LAB_PID_FILE"
sleep 60 &
printf '%s\n' "$!" >> "$FM_LAB_PID_FILE"
wait "$!"
exec git upload-pack "$@"
''')
remote.chmod(0o700)
subprocess.run(['git', '-C', str(slot), 'config', 'remote.origin.uploadpack', str(remote)], env=env, check=True)
old = scratch / 'old-nm-run-lib.sh'
old.write_bytes(subprocess.check_output(['git', 'show', '0bcfe6bb^:bin/fm-nm-run-lib.sh'], cwd=root))
driver = scratch / 'run-git-tree.sh'
driver.write_text('''#!/usr/bin/env bash
. "$1"
fm_nm_bounded "$2" 2 git cat-file -e 'ffffffffffffffffffffffffffffffffffffffff^{commit}'
''')
rows = []
for name, library in [('before', old), ('after', root / 'bin/fm-nm-run-lib.sh')]:
    pid_file = scratch / (name + '-remote-pids')
    trace = evidence / (name + '-process-trace.jsonl')
    started = time.monotonic()
    p = subprocess.Popen(['bash', str(driver), str(library), str(slot)], cwd=root, env=env | {'FM_LAB_PID_FILE': str(pid_file), 'GIT_TRACE2_EVENT': str(trace)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        rc = p.wait(timeout=15)
        elapsed = time.monotonic() - started
        ids = [int(x) for x in pid_file.read_text().splitlines()] if pid_file.exists() else []
        records = []
        for pid in ids:
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,ppid=,pgid=,stat=,comm='], text=True, capture_output=True).stdout.strip()
            records.append({'pid': pid, 'state_after_return': state})
        row = {'version': name, 'command': 'fm_nm_bounded <partial-clone> 2 git cat-file -e <missing>^{commit}', 'exit': rc, 'elapsed_seconds': round(elapsed, 4), 'remote_descendants_started': ids, 'descendants_after_return': records, 'all_descendants_gone': bool(ids) and all(not r['state_after_return'] for r in records)}
        rows.append(row)
        print(json.dumps(row), flush=True)
    finally:
        for pid in ([int(x) for x in pid_file.read_text().splitlines()] if pid_file.exists() else []):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if p.poll() is None:
            p.kill()
            p.wait()
(evidence / 'process-tree-proof.json').write_text(json.dumps(rows, indent=2))
