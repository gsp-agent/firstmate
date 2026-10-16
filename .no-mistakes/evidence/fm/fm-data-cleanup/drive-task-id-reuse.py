#!/usr/bin/env python3
"""Disposable product-level cleanup verification; no fake product executables."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M51QXPD56TVZ2QJZNGZSV4K4')
EVIDENCE = Path(__file__).parent
BASE = ROOT / '.fm-live-task-data'
LAB = BASE / 'home'
PROJECT = LAB / 'projects/sample'
DATA, STATE = LAB / 'data', LAB / 'state'
LOG = (EVIDENCE / 'live-task-id-reuse.log').open('w', buffering=1)
RESULTS = {'commands': [], 'observations': {}, 'scenarios': []}
ENV = {k: v for k, v in os.environ.items() if not k.startswith(
    ('FM_', 'BEADS', 'BR_', 'TASKS_AXI', 'GITLAB', 'GLAB', 'DCG_', 'XDG_', 'TMUX', 'GIT_'))}
ENV.update(FM_HOME=str(LAB), TMPDIR=str(BASE),
    TMUX=str(EVIDENCE / 'absent-lab.sock') + ',0,0',
    DCG_CONFIG=str(BASE / 'dcg.toml'),
    XDG_CONFIG_HOME=str(BASE / 'xdg-config'), XDG_CACHE_HOME=str(BASE / 'xdg-cache'),
    XDG_DATA_HOME=str(BASE / 'xdg-data'), XDG_STATE_HOME=str(BASE / 'xdg-state'),
    GLAB_CONFIG_DIR=str(BASE / 'glab'), GLAB_CHECK_UPDATE='false',
    GLAB_SEND_TELEMETRY='false', GLAB_USE_KEYRING='false', GLAB_NO_PROMPT='true',
    GLAB_API_PROTOCOL='http', GITLAB_HOST='localhost', GIT_CONFIG_NOSYSTEM='1',
    GIT_CONFIG_GLOBAL='/dev/null', GIT_AUTHOR_NAME='Local validation',
    GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='Local validation',
    GIT_COMMITTER_EMAIL='validation@example.invalid', NO_COLOR='1')


def note(message):
    print(message, flush=True)
    LOG.write(message + '\n')


def run(args, cwd=ROOT, expected=0, env=None):
    args = [str(a) for a in args]
    result = subprocess.run(args, cwd=cwd, env=env or ENV, text=True,
                            capture_output=True, timeout=120)
    LOG.write('\n$ ' + shlex.join(args) + '\n')
    LOG.write(result.stdout + result.stderr + 'exit=' + str(result.returncode) + '\n')
    RESULTS['commands'].append({'argv': args, 'cwd': str(cwd), 'exit': result.returncode})
    if expected is not None and result.returncode != expected:
        raise AssertionError(f'{args}: expected {expected}, got {result.returncode}: {result.stderr}')
    return result


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    LOG.write('VERIFIED: ' + description + '\n')


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bytes_under(path):
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file() and not p.is_symlink())


def meta(task_id, pr='', worktree=None, tasktmp=None):
    fields = dict(window=f'firstmate:fm-{task_id}', endpoint_task_id=task_id,
                  worktree=str(worktree or LAB / ('missing-' + task_id)),
                  project=str(PROJECT), kind='ship', mode='local-only',
                  spawn_gen=task_id + '-' + str(time.time_ns()))
    if pr:
        fields['pr'] = pr
    if tasktmp:
        fields['tasktmp'] = str(tasktmp)
    write(STATE / (task_id + '.meta'), ''.join(k + '=' + v + '\n' for k, v in fields.items()))


def teardown(task_id, **kwargs):
    meta(task_id, **kwargs)
    # Only a fresh lab home is driven; no task worktree exists on successful paths,
    # so teardown cannot start/stop a no-mistakes run or return a shared pool slot.
    return run([ROOT / 'bin/fm-teardown.sh', task_id])


def scenario(name):
    RESULTS['scenarios'].append({'name': name, 'result': 'pass', 'live': True})
    note('PASS: ' + name)


class API(http.server.BaseHTTPRequestHandler):
    description = '[PR capture](pr-proof.png) [latest](latest.png) [frames](frames.png) [chain](chained.png) [data](latest-data.png) [external](escape.png)'
    notes = [{'id': 3, 'body': '[discussion capture](comment-proof.bin)'}]
    available = True
    mr_state = 'merged'
    calls = []

    def do_GET(self):
        type(self).calls.append(self.path)
        if not self.available:
            status, data = 503, {'message': 'Disposable reference service unavailable'}
        elif self.path.split('?')[0].endswith('/notes'):
            status, data = 200, self.notes
        elif self.path.split('?')[0].endswith('/approval_state'):
            status, data = 200, {'rules': []}
        elif 'merge_requests/7' in self.path:
            status, data = 200, dict(id=7, iid=7, project_id=1, title='Local cleanup verification',
                state=self.mr_state, description=self.description,
                web_url='https://localhost/team/repo/-/merge_requests/7',
                source_branch='finished', target_branch='main',
                author=dict(id=1, name='Local validation', username='local'))
        else:
            status, data = 200, dict(id=1, name='repo', path='repo',
                path_with_namespace='team/repo', default_branch='main',
                web_url='https://localhost/team/repo',
                http_url_to_repo='https://localhost/team/repo.git')
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
ENV['GITLAB_API_HOST'] = f'127.0.0.1:{server.server_port}'
PR = 'https://localhost/team/repo/-/merge_requests/7'

try:
    note('Real cleanup lifecycle: reuse of the same task ID and path must retain both generations and eventually reclaim each.')
    for variant in ('data','temporary'):
        task_id = 'reuse-' + variant
        task = DATA/task_id
        scratch = task/'scratch' if variant == 'data' else BASE/(task_id+'-build')
        write(task/'report.md', f'Scratch: {scratch}\n')
        write(scratch/'build.bin', 'first generation\n')
        teardown(task_id)
        held = scratch/'.cleanup-hold/build.bin' if variant == 'temporary' else task/'.cleanup-hold/scratch/build.bin'
        check(held.read_text() == 'first generation\n', variant+': first generation is recoverable')
        write(scratch/'build.bin', 'second generation\n')
        output = teardown(task_id)
        check(held.read_text() == 'first generation\n', variant+': same task does not expire its own original')
        check((scratch/'build.bin').read_text() == 'second generation\n', variant+': second generation is not overwritten')
        check(json.loads((task/'record/data-cleanup.json').read_text())['complete'], variant+': collision leaves earlier recovery complete')
        teardown(task_id+'-next')
        check(held.read_text() == 'second generation\n', variant+': next task expires old generation then stages replacement')
        check(not (scratch/'build.bin').exists(), variant+': replacement retains original path mapping in recovery')
        teardown(task_id+'-later')
        check(not (task/'.cleanup-hold').exists(), variant+': second full cycle expires recovery')
        if variant == 'temporary':
            check(not scratch.exists(), 'empty temporary scratch root is reclaimed after reused-path recovery')
        note('PASS: '+variant+' path collision preserves both generations and advances across later task completions')
    scenario('Reusing a finished task ID and data or temporary pathname keeps both generations recoverable and expires them on separate later cycles')
    task_id='unsafe-record'
    task=DATA/task_id
    write(task/'scratch.bin','must remain original\n')
    (task/'record').symlink_to(BASE/'outside')
    meta(task_id)
    original_meta=(STATE/(task_id+'.meta')).read_bytes()
    output=run([ROOT/'bin/fm-teardown.sh',task_id],expected=1)
    check('cleanup could not be recorded' in output.stderr, 'unsafe recovery record refuses task retirement')
    check((STATE/(task_id+'.meta')).read_bytes()==original_meta,'task retirement refusal preserves its original record')
    check((task/'scratch.bin').read_text()=='must remain original\n','task retirement refusal preserves original scratch')
    check((BASE/'outside/outside.bin').read_text()=='outside\n','unsafe receipt parent never overwrites an outside file')
    scenario('An escaping recovery-record directory prevents retirement and leaves task records and original data intact')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    (EVIDENCE/'live-task-id-reuse-observations.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    LOG.close()
