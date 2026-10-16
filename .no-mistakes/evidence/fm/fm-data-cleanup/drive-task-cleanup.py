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
    note('Real Firstmate cleanup CLI; real git, br, glab and dcg. Synthetic MR data is served only on loopback; no production credentials are used.')
    check((LAB / '.fm-lab-home').read_text().strip() == 'fm-lab-home v1', 'home was minted by fm-lab-home.sh')
    check(not run([ROOT / 'bin/fm-remote-job-reap-orphans.sh', '--dry-run']).stdout.strip(), 'no remote orphan worker would be touched')
    write(STATE / '.last-watcher-beat', '')  # Fixture liveness; no watcher is launched.
    for tool in ('git', 'br', 'glab', 'dcg', 'tmux'):
        note(f'Real executable {tool}: {shutil.which(tool, path=ENV["PATH"])}')
    run(['dcg', '--version'])
    bead = json.loads(run(['br', 'create', 'Disposable evidence', '--description', '[bead capture](bead-proof.bin)', '--json'], PROJECT).stdout)['id']

    # Finished task plus owned temporary directories and conservative evidence.
    task = DATA / 'finished'
    temporary = BASE / 'finished-proof'
    unrelated, live, unclaimed = BASE / 'unrelated', BASE / 'live-proof', BASE / 'finished-unclaimed'
    outside = BASE / 'outside'
    recorded = BASE / 'recorded-tmp'
    for path in (temporary, unrelated, live, unclaimed, outside, recorded):
        path.mkdir(exist_ok=True)
    alias = BASE / 'ancestor-alias'
    bridge = BASE / 'alias-bridge'
    bridge.symlink_to(BASE)
    alias.symlink_to(bridge)
    data_alias = BASE / 'data-alias'
    data_alias.symlink_to(DATA)
    write(task / 'brief.md', f'Bead {bead}\nDisposable cleanup.\n')
    write(task / 'report.md', f'Temporary scratch: {temporary}\nUnrelated: {unrelated}\nLive: {live}\n')
    write(task / 'review.txt', 'retained review\n')
    write(task / 'small-unlinked.json', '{"safe-default":true}\n')
    write(task / 'record/status', '[status capture](status-proof.bin)\n')
    for name in ('pr-proof.png', 'comment-proof.bin', 'bead-proof.bin', 'status-proof.bin', 'data.bin'):
        write(task / name, name + '\n')
    write(task / 'late-proof.bin', b'L' * 4096)
    write(task / 'oversized.log', b'O' * (2 * 1024 * 1024))
    run(['git', 'clone', '-q', str(PROJECT), str(task / 'clone')])
    write(task / 'clone/README.md', 'clone text is scratch\n')
    write(task / 'clone/build/large.bin', b'C' * (4 * 1024 * 1024))
    for rel, data in [('capture.bin', 'capture'), ('frames/frame.bin', 'frame'), ('chain.bin', 'chain'),
                      ('later.bin', 'later capture'), ('later-frames/later-frame.bin', 'later frame')]:
        write(temporary / rel, data)
    write(temporary / 'discard.bin', b'T' * (3 * 1024 * 1024))
    write(recorded / 'build.bin', b'R' * 8192)
    (temporary / 'bridge.bin').symlink_to('chain.bin')
    for name, target in [('latest.png', 'capture.bin'), ('frames.png', 'frames'),
                         ('chained.png', 'bridge.bin'), ('saved.png', 'later.bin'), ('saved-frames.png', 'later-frames')]:
        (task / name).symlink_to(alias / temporary.name / target)
    (task / 'latest-data.png').symlink_to(data_alias / 'finished/data.bin')
    (task / 'escape.png').symlink_to(outside / 'outside.bin')
    for path in (unrelated, live, unclaimed, outside):
        write(path / ('outside.bin' if path == outside else 'blob'), path.name + '\n')
    meta('live', tasktmp=live)
    baseline = bytes_under(task) + bytes_under(temporary) + bytes_under(recorded)
    original = {str(p): digest(p) for p in (task / 'clone/build/large.bin', task / 'oversized.log', temporary / 'discard.bin', recorded / 'build.bin')}
    teardown('finished', pr=PR, tasktmp=recorded)
    for path, expected_hash in original.items():
        path = Path(path)
        owner = task if task in path.parents else temporary if temporary in path.parents else recorded
        held = owner / '.cleanup-hold' / path.relative_to(owner)
        check(held.is_file() and digest(held) == expected_hash, 'original is recoverable without byte changes: ' + str(held.relative_to(BASE)))
        check(not path.exists(), 'scratch left its original location: ' + str(path.relative_to(BASE)))
    for name in ('brief.md','report.md','review.txt','small-unlinked.json','record/status', 'pr-proof.png', 'comment-proof.bin','bead-proof.bin','status-proof.bin'):
        check((task / name).is_file(), 'evidence remains in place: ' + name)
    for name, content in [('latest.png','capture'),('frames.png/frame.bin','frame'),('chained.png','chain'),('latest-data.png','data.bin\n')]:
        check((task / name).read_text() == content, 'aliased evidence reads after staging: ' + name)
    check((task / '.cleanup-hold/saved.png').is_symlink(), 'unlinked evidence link starts in recovery')
    check((temporary / '.cleanup-hold/later.bin').is_file(), 'its unlinked target starts in temporary recovery')
    check((unrelated / 'blob').read_text() == 'unrelated\n', 'unrelated temporary bytes are unchanged')
    check((live / 'blob').read_text() == 'live-proof\n', 'live-task temporary bytes are unchanged')
    check((unclaimed / 'blob').read_text() == 'finished-unclaimed\n', 'task-shaped name without evidence is insufficient ownership')
    check((outside / 'outside.bin').read_text() == 'outside\n', 'symlink escape target remains unchanged')
    staged = bytes_under(task) + bytes_under(temporary) + bytes_under(recorded)
    RESULTS['observations']['disk'] = dict(baseline_bytes=baseline, staged_bytes=staged)
    scenario('Finishing a task stages clone, large data and recorded temporary scratch with intact recovery; linked and bounded text evidence remains')

    # A subsequent cleanup whose reference service is down cannot expire data.
    API.available = False
    output = teardown('outage-cycle')
    check('cleanup needs a retry' in output.stderr, 'reference outage is reported by teardown')
    check((task / '.cleanup-hold/clone/build/large.bin').is_file(), 'reference outage retains prior recovery')
    API.available = True
    API.description += ' [newly linked](late-proof.bin) [saved](saved.png) [saved frames](saved-frames.png)'
    teardown('expiry-cycle')
    check(not (task / '.cleanup-hold').exists() and not (temporary / '.cleanup-hold').exists(), 'different task completion expires both recovery areas')
    check(not recorded.exists(), 'empty recorded temporary root is reclaimed')
    check((task / 'late-proof.bin').read_bytes() == b'L' * 4096, 'newly linked held file is restored to its original path')
    for name, content in [('latest.png','capture'),('frames.png/frame.bin','frame'),('chained.png','chain'),('saved.png','later capture'),('saved-frames.png/later-frame.bin','later frame'),('latest-data.png','data.bin\n')]:
        check((task / name).read_text() == content, 'aliased evidence reads after expiry: ' + name)
    check(not (temporary / 'discard.bin').exists(), 'unlinked temporary build is reclaimed')
    check(not (task / 'clone').exists() and not (task / 'oversized.log').exists(), 'unlinked clone and large log are reclaimed')
    final_bytes = bytes_under(task) + bytes_under(temporary)
    RESULTS['observations']['disk'].update(final_bytes=final_bytes, reclaimed_bytes=staged-final_bytes)
    RESULTS['observations']['receipt'] = json.loads((task / 'record/data-cleanup.json').read_text())
    note('Measured lifecycle bytes: ' + json.dumps(RESULTS['observations']['disk']))
    scenario('A different completed task expires recovery through installed dcg and reclaims bytes while restoring newly linked evidence')
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
