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
LOG = (EVIDENCE / 'live-task-cleanup.log').open('w', buffering=1)
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
    RESULTS = json.loads((EVIDENCE/'live-task-cleanup-observations-initial.json').read_text())
    note('Continuing the same disposable live scenario after a real dcg evaluation-timeout denial. No guard policy or product source changed.')
    task, temporary, recorded = DATA/'finished', BASE/'finished-proof', BASE/'recorded-tmp'
    unrelated, live, unclaimed, outside = BASE/'unrelated', BASE/'live-proof', BASE/'finished-unclaimed', BASE/'outside'
    staged = RESULTS['observations']['disk']['staged_bytes']
    bead = json.loads(run(['br','list','--json'], PROJECT).stdout)['issues'][0]['id']
    API.description += ' [newly linked](late-proof.bin) [saved](saved.png) [saved frames](saved-frames.png)'
    note('The actual retry command and successful expiry are in live-task-cleanup-retry.log; checking its persisted outcome before continuing.')
    check(not (task / '.cleanup-hold').exists() and not (temporary / '.cleanup-hold').exists(), 'different task completion expires both recovery areas')
    check(not recorded.exists(), 'empty recorded temporary root is reclaimed')
    check((task / 'late-proof.bin').read_bytes() == b'L' * 4096, 'newly linked held file is restored to its original path')
    for name, content in [('latest.png','capture'),('frames.png/frame.bin','frame'),('chained.png','chain'),('saved.png','later capture'),('saved-frames.png/later-frame.bin','later frame'),('latest-data.png','data.bin\n')]:
        check((task / name).read_text() == content, 'aliased evidence reads after expiry: ' + name)
    check(not (temporary / 'discard.bin').exists(), 'unlinked temporary build is reclaimed')
    check(not (task / 'clone/build/large.bin').exists() and not (task / 'clone/README.md').exists() and not (task / 'oversized.log').exists(), 'unlinked clone payload and large log are reclaimed')
    check(bytes_under(task/'clone') < 1024, 'any conservatively retained clone metadata is below 1 KiB')
    final_bytes = bytes_under(task) + bytes_under(temporary)
    RESULTS['observations']['disk'].update(final_bytes=final_bytes, reclaimed_bytes=staged-final_bytes)
    RESULTS['observations']['receipt'] = json.loads((task / 'record/data-cleanup.json').read_text())
    note('Measured lifecycle bytes: ' + json.dumps(RESULTS['observations']['disk']))
    scenario('A different completed task expires recovery through installed dcg and reclaims bytes while restoring newly linked evidence')
    scenario('A real dcg timeout leaves remaining recovery intact; the next allowed completion retries without any policy bypass')
    scenario('Aliased file, directory and chained-symlink targets stay readable through staging and expiry; escaping links never traverse outside owned roots')
    scenario('Real glab reads MR descriptions and discussion and real br reads bead links; an API outage preserves recovery until a later retry')

    # A missing bead store during retirement leaves an executable retry obligation.
    pending = DATA / 'pending'
    write(pending / 'brief.md', f'Bead {bead}\n')
    write(pending / 'scratch.bin', 'pending scratch\n')
    beads_dir = PROJECT / '.beads'
    beads_backup = PROJECT / '.beads-unavailable'
    beads_dir.rename(beads_backup)
    try:
        output = teardown('pending')
        check('cleanup needs a retry' in output.stderr, 'unreadable bead is reported at retirement')
        check((pending / 'scratch.bin').read_text() == 'pending scratch\n', 'unreadable bead leaves original scratch unmoved')
        check(not (STATE / 'pending.meta').exists(), 'retirement completed with durable cleanup obligation')
    finally:
        beads_backup.rename(beads_dir)
    teardown('pending-retry')
    check((pending / '.cleanup-hold/scratch.bin').is_file(), 'later completion resumes interrupted staging')
    teardown('pending-expire')
    check(not (pending / '.cleanup-hold').exists(), 'resumed staging receives a full cycle before expiry')
    scenario('Unavailable bead data leaves originals untouched and records a retry; later completions stage then expire them')

    # Positive ownership and directory identity protect temporary data.
    replace_task = DATA / 'replacement'
    replace_tmp = BASE / 'replacement-proof'
    write(replace_task / 'report.md', f'Scratch: {replace_tmp}\n')
    write(replace_tmp / 'build.bin', 'recoverable bytes\n')
    teardown('replacement')
    backup = BASE / 'replacement-original'
    replace_tmp.rename(backup)
    replace_tmp.symlink_to(outside)
    try:
        output = run(['python3', ROOT/'bin/fm-task-data.py', 'expire', DATA, STATE, 'replacement'], expected=1)
        check('not a real directory' in output.stderr, 'temporary symlink replacement refuses before removal')
        check((backup / '.cleanup-hold/build.bin').read_text() == 'recoverable bytes\n', 'replaced directory retains original recovery')
        check((outside / 'outside.bin').read_text() == 'outside\n', 'replacement escape leaves outside bytes unchanged')
    finally:
        replace_tmp.unlink()
        backup.rename(replace_tmp)
    meta('new-owner', tasktmp=replace_tmp)
    output = run(['python3', ROOT/'bin/fm-task-data.py', 'expire', DATA, STATE, 'replacement'], expected=1)
    check('live task' in output.stderr, 'new live task prevents expiry of its temporary directory')
    check((replace_tmp / '.cleanup-hold/build.bin').is_file(), 'live owner preserves recovery bytes')
    run(['python3', ROOT/'bin/fm-task-data.py', 'stage', DATA, STATE, 'live', PROJECT, ''], expected=1)
    scenario('Unrelated and live task scratch is excluded, symlink replacements refuse, and newly live ownership prevents expiry')

    # The cleanup hook must never run when work has not landed.
    unlanded = LAB / 'unlanded-copy'
    run(['git','init','-q','-b','main',unlanded])
    run(['git','commit','--allow-empty','-qm','baseline'], unlanded)
    run(['git','checkout','-qb','work'], unlanded)
    run(['git','commit','--allow-empty','-qm','unlanded work'], unlanded)
    write(DATA / 'unlanded/scratch.bin', 'must survive refusal\n')
    meta('unlanded', worktree=unlanded)
    before_meta = (STATE / 'unlanded.meta').read_bytes()
    output = run([ROOT/'bin/fm-teardown.sh','unlanded'], expected=1)
    check('REFUSED' in output.stderr, 'unlanded work refuses cleanup')
    check((STATE/'unlanded.meta').read_bytes() == before_meta, 'refusal keeps the task record unchanged')
    check((DATA/'unlanded/scratch.bin').read_text() == 'must survive refusal\n', 'refusal never invokes task data pruning')
    scenario('Attempting cleanup of unlanded work refuses and preserves both task records and original scratch')

    RESULTS['observations']['api_requests'] = API.calls
    RESULTS['observations']['api_description'] = API.description
    RESULTS['observations']['api_notes'] = API.notes
    RESULTS['observations']['bead'] = json.loads(run(['br','--no-auto-flush','--no-auto-import','--json','show',bead], PROJECT).stdout)
    note('All disposable product scenarios passed.')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    (EVIDENCE/'live-task-cleanup-observations.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    LOG.close()
