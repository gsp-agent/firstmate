from pathlib import Path
import json
import os
import signal
import sqlite3
import subprocess
import time

root = Path.cwd()
scratch = root / '.nm-live-yeldv'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH')
fixture = json.loads((evidence / 'fixture.json').read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_'))}
env.update(json.loads((evidence / 'isolated-env.json').read_text()))
env.update(GIT_AUTHOR_NAME='gsp-agent', GIT_AUTHOR_EMAIL='gsp-agent@users.noreply.github.com', GIT_COMMITTER_NAME='gsp-agent', GIT_COMMITTER_EMAIL='gsp-agent@users.noreply.github.com')

def git(*args):
    return subprocess.check_output(['git', *map(str, args)], env=env, text=True).strip()

head = git('-C', fixture['seed'], 'commit-tree', fixture['head'] + '^{tree}', '-p', fixture['head'], '-m', 'isolated status counterfactual')
slot = scratch / 'status-counterfactual-slot'
git('clone', '-q', '--filter=blob:none', Path(fixture['remote']).as_uri(), slot)
git('-C', slot, 'switch', '-qc', 'fm/lab-yeldv')
git('-C', slot, 'remote', 'add', 'no-mistakes', scratch / 'nm-home/repos/f1ab00000001.git')
git('-C', slot, 'config', 'remote.origin.uploadpack', scratch / 'slow-upload-pack.sh')
now = int(time.time() * 1000)
run_id = '01M5APP0000000000000000002'
with sqlite3.connect(scratch / 'nm-home/state.sqlite') as db:
    db.execute('INSERT INTO repos(id,working_path,upstream_url,default_branch,created_at) VALUES (?,?,?,?,?)', ('f1ab00000002', str(slot), Path(fixture['remote']).as_uri(), 'main', now))
    db.execute('INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,submitted_head_sha,worktree_dir,status,awaiting_agent_since,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)', (run_id, 'f1ab00000002', 'fm/lab-yeldv', head, fixture['submitted'], fixture['submitted'], fixture['seed'], 'running', now, now, now))
    findings = {'findings': [{'id': 'LAB2', 'severity': 'warning', 'description': 'Real status API retains this disposable decision', 'action': 'ask-user'}]}
    db.execute('INSERT INTO step_results(id,run_id,step_name,step_order,status,findings_json) VALUES (?,?,?,?,?,?)', ('lab-review-2', run_id, 'review', 1, 'awaiting_approval', json.dumps(findings)))
driver = scratch / 'status-counterfactual.sh'
driver.write_text('''#!/usr/bin/env bash
. "$1"
fm_nm_run_bounded "$2" 10 axi status
''')
rows = []
for label, lib in [('after-1', root / 'bin/fm-nm-run-lib.sh'), ('after-2', root / 'bin/fm-nm-run-lib.sh'), ('after-3', root / 'bin/fm-nm-run-lib.sh'), ('before', scratch / 'old-nm-run-lib.sh')]:
    pid_file = scratch / (label + '-status-remote-pids')
    trace = evidence / (label + '-status-trace.jsonl')
    output = evidence / (label + '-status.txt')
    started = time.monotonic()
    with output.open('w') as capture:
        proc = subprocess.Popen(['bash', str(driver), str(lib), str(slot)], cwd=root, env=env | {'FM_LAB_PID_FILE': str(pid_file), 'GIT_TRACE2_EVENT': str(trace)}, stdout=capture, stderr=capture)
        try:
            rc = proc.wait(timeout=20)
            elapsed = time.monotonic() - started
            text = output.read_text()
            events = list(map(json.loads, trace.read_text().splitlines()))
            calls = [event['argv'] for event in events if event.get('event') == 'start']
            lazy = [args for args in calls if 'fetch' in args and '--stdin' in args]
            row = {'version': label, 'head': head, 'command': 'fm_nm_run_bounded <partial-clone-with-slow-promisor> 10 axi status', 'exit': rc, 'elapsed_seconds': round(elapsed, 6), 'returns_gate_and_finding': 'gate:' in text and 'LAB2,warning' in text, 'implicit_lazy_fetches': lazy}
            rows.append(row)
            print(json.dumps(row), flush=True)
        finally:
            if pid_file.exists():
                groups = set()
                for pid in map(int, pid_file.read_text().splitlines()):
                    try:
                        groups.add(os.getpgid(pid))
                    except ProcessLookupError:
                        pass
                for group in groups:
                    assert group != os.getpgrp()
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if proc.poll() is None:
                proc.kill()
                proc.wait()
missing = subprocess.run(['git', '-C', str(slot), 'cat-file', '-e', head + '^{commit}'], env=env | {'GIT_NO_LAZY_FETCH': '1'}, capture_output=True).returncode != 0
(evidence / 'status-counterfactual-proof.json').write_text(json.dumps({'head_remains_absent': missing, 'runs': rows}, indent=2))
