#!/usr/bin/env python3
"""Drive the shipped CLI against disposable, workspace-local Git and home data."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import threading
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4ZEKNC14QM3J3ZZ3Q1TTCJA')
LAB = ROOT / '.test-live'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
for key in ('TYPESAFE_API_KEY', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT'):
    ENV.pop(key, None)
ENV.update(TMPDIR=str(LAB / 'tmp'), GIT_CONFIG_GLOBAL='/dev/null',
           GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0', PYTHONDONTWRITEBYTECODE='1')
SCRIPT = ROOT / 'bin/fm-drift-nightly.sh'
HEAD = '516926a92e179b5cbc4bff564b9e6c5ff1a71190'
UPSTREAM = '7df545bf74ff729ed1733f77b0aea02a9b164ac1'
log = (EVIDENCE / 'live-cli-transcript.log').open('w')
results = []

def run(args, expected=0, env=None, record=True, cwd=ROOT):
    args = [str(x) for x in args]
    proc = subprocess.run(args, cwd=cwd, env=env or ENV, capture_output=True, text=True)
    if record:
        log.write('$ ' + shlex.join(args) + '\n')
        log.write(proc.stdout + proc.stderr)
        log.write(f'exit: {proc.returncode}\n\n')
        log.flush()
    if proc.returncode != expected:
        raise AssertionError(f'{shlex.join(args)}: expected {expected}, got {proc.returncode}: {proc.stderr}')
    return proc.stdout + proc.stderr

def git(repo, *args, **kwargs):
    return run(['git', '-C', repo, *args], **kwargs)

def commit(repo, message):
    git(repo, 'add', '-A', record=False)
    git(repo, '-c', 'user.name=Live validation', '-c', 'user.email=validation@example.invalid',
        '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
        'commit', '-qm', message, record=False)
    return git(repo, 'rev-parse', 'HEAD', record=False).strip()

def check(repo, *args, expected=0, env=None):
    return run(['bash', SCRIPT, 'check', '--no-fetch', '--repo', repo, *args], expected, env)

def scenario(name, fn):
    log.write('\nSCENARIO: ' + name + '\n')
    try:
        fn()
        results.append({'name': name, 'result': 'pass', 'live': True})
    except Exception as exc:
        log.write('ERROR: ' + str(exc) + '\n')
        results.append({'name': name, 'result': 'fail', 'live': True, 'error': str(exc)})
    log.flush()
    (EVIDENCE / 'live-cli-results.json').write_text(json.dumps(results, indent=2) + '\n')

def shipped():
    repo = LAB / 'shipped-repository'
    out = check(repo, '--upstream', UPSTREAM)
    assert 'path-drift:' not in out
    assert f'keep: {HEAD} ' in out
    assert 'path-ok: drift-proof.txt' in out
    (EVIDENCE / 'shipped-proof-check.log').write_text(out + 'exit: 0\n')
    for file in ('bin/fm-spawn.sh', 'bin/fm-drift-nightly.sh', 'drift-proof.txt'):
        with (repo / file).open('a') as f:
            f.write('\n# an unapproved later edit for live validation\n')
    later = commit(repo, 'Unapproved edits to previously proven paths')
    out = check(repo, '--upstream', UPSTREAM, expected=1)
    for file in ('bin/fm-spawn.sh', 'bin/fm-drift-nightly.sh', 'drift-proof.txt'):
        assert 'path-drift: ' + file in out
    assert f'unproven: {later}' in out

def repo_init(name):
    repo = LAB / name
    repo.mkdir()
    git(repo, 'init', '-q', '-b', 'main', record=False)
    (repo / 'README').write_text('Disposable Git validation repository\n')
    commit(repo, 'Upstream baseline')
    git(repo, 'branch', 'upstream', record=False)
    return repo

def hidden_deletion():
    repo = repo_init('deletion-repository')
    (repo / 'original.txt').write_text('identical contents\n')
    commit(repo, 'Upstream original file')
    git(repo, 'branch', '-f', 'upstream', 'HEAD', record=False)
    (repo / 'copy.txt').write_text('identical contents\n')
    kept = commit(repo, 'Proven copy')
    proof = LAB / 'deletion-proof.txt'
    proof.write_text(kept + '\n')
    check(repo, '--upstream', 'upstream', '--proof', proof)
    git(repo, 'config', 'diff.renames', 'true', record=False)
    git(repo, 'rm', '-q', 'original.txt', record=False)
    commit(repo, 'Unproven deletion resembling a rename')
    out = check(repo, '--upstream', 'upstream', '--proof', proof, expected=1)
    assert 'path-ok: copy.txt' in out and 'path-drift: original.txt' in out

def missing_patch_and_mode():
    repo = repo_init('missing-patch-repository')
    (repo / 'kept.txt').write_text('Proven retained contents\n')
    kept = commit(repo, 'Proven addition')
    proof = LAB / 'missing-proof.txt'
    proof.write_text(kept + '\n')
    (repo / 'kept.txt').chmod(0o755)
    commit(repo, 'Unproven mode change')
    out = check(repo, '--upstream', 'upstream', '--proof', proof, expected=1)
    assert 'path-drift: kept.txt' in out
    git(repo, 'rm', '-q', 'kept.txt', record=False)
    commit(repo, 'Delete a proven patch')
    out = check(repo, '--upstream', 'upstream', '--proof', proof, expected=1)
    assert 'path-drift: kept.txt' in out

def concurrent_snapshot(ref):
    repo = repo_init('concurrent-' + ref)
    for i in range(60):
        (repo / f'kept-{i:02}.txt').write_text('Proven file\n')
    kept = commit(repo, 'Proven files')
    proof = LAB / ('concurrent-' + ref + '-proof.txt')
    proof.write_text(kept + '\n')
    git(repo, 'switch', '-q', '-c', 'future', record=False)
    (repo / 'later-unproven.txt').write_text('New unproven contents\n')
    future = commit(repo, 'Concurrent later commit')
    git(repo, 'switch', '-q', 'main', record=False)
    trace = LAB / ('concurrent-' + ref + '.trace.jsonl')
    trace.touch()
    env = dict(ENV, GIT_TRACE2_EVENT=str(trace))
    args = ['bash', str(SCRIPT), 'check', '--no-fetch', '--repo', str(repo),
            '--fork', 'main', '--upstream', 'upstream', '--proof', str(proof)]
    log.write('$ ' + shlex.join(args) + '\n')
    proc = subprocess.Popen(args, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    observed = False
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and proc.poll() is None:
        for line in trace.read_text().splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            argv = event.get('argv', [])
            if event.get('event') == 'start' and 'diff' in argv and '--name-only' in argv:
                observed = True
                break
        if observed:
            break
        time.sleep(0.005)
    assert observed, 'Could not synchronize the concurrent ref change with the real Git trace'
    target = 'refs/heads/' + ref
    git(repo, 'update-ref', target, future)
    out, err = proc.communicate(timeout=30)
    log.write(out + err + f'exit: {proc.returncode}\n\n')
    assert proc.returncode == 0 and 'behind: 0\nahead: 1\n' in out
    assert 'later-unproven.txt' not in out
    assert git(repo, 'rev-parse', target).strip() == future
    log.write('The actual ref advanced after the captured snapshot; the report retained the original counts, paths and commit.\n')
    if ref == 'main':
        out = check(repo, '--upstream', 'upstream', '--proof', proof, expected=1)
        assert 'path-drift: later-unproven.txt' in out

def recovery():
    repo = LAB / 'archive-consumer'
    run(['git', 'clone', '--no-checkout', ROOT / 'archives/fork-cuts.bundle', repo])
    git(repo, 'bundle', 'verify', ROOT / 'archives/fork-cuts.bundle')
    out = git(repo, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/remotes/origin/archive/')
    refs = [line.split() for line in out.splitlines()]
    assert len(refs) == 9
    for sha, ref in refs:
        assert sha in ref
        git(repo, 'cat-file', '-e', sha + '^{commit}', record=False)
    ref = next(ref for sha, ref in refs if sha.startswith('814465e1'))
    git(repo, 'checkout', '--detach', ref)
    assert git(repo, 'rev-parse', 'HEAD').strip() == '814465e1383e1654aea41db0544c28cd1f30fa92'
    log.write('The archived pre-cut tree checked out successfully; all nine named archive branches resolve to their original commits.\n')

def routing_and_fallback():
    home = LAB / 'routing-home'
    (home / 'config').mkdir(parents=True)
    (home / 'state').mkdir()
    (home / 'usage').mkdir()
    env = dict(ENV, FM_HOME=str(home), FM_CURSOR_USAGE_DIR=str(home / 'usage'))
    config = {
        'default': {'harness':'grok','model':'grok-4.7','effort':'xhigh'},
        'label_routes': {
            'docs-only': {'harness':'grok','model':'grok-4.7','effort':'xhigh'},
            'ep-opus': {'harness':'claude','model':'claude-opus-5-5[1m]','effort':'xhigh'},
            'sol': {'harness':'codex','model':'gpt-6.1-sol','effort':'max'}},
        'cursor_fallback': {'models_pct':85,'max_age_h':26}}
    path = home / 'config/crew-dispatch.json'
    path.write_text(json.dumps(config))
    resolve = ['bash', ROOT / 'bin/fm-dispatch-resolve.sh', '--labels']
    for labels, harness, model, effort in [('', 'grok','grok-4.7','xhigh'),
        ('docs-only','grok','grok-4.7','xhigh'), ('ep-opus','claude','claude-opus-5-5[1m]','xhigh'),
        ('sol','codex','gpt-6.1-sol','max')]:
        out = run(resolve + [labels], env=env)
        profile = next(line for line in out.splitlines() if line.strip().startswith('profile:')).strip()[9:]
        assert shlex.split(profile) == ['--harness',harness,'--model',model,'--effort',effort]
    for labels in ('docs-only,ep-opus','ep-opus,docs-only'):
        out = run(resolve + [labels], expected=1, env=env)
        assert 'status: refused' in out and 'profile:' not in out
    config['label_routes']['sol']['effort'] = 'ultra'
    path.write_text(json.dumps(config))
    out = run(resolve + ['sol'], expected=2, env=env)
    assert 'malformed rules file:' in out and 'profile:' not in out
    config['label_routes']['sol']['effort'] = 'max'
    path.write_text(json.dumps(config))
    fallback = ['bash', ROOT / 'bin/fm-cursor-guard.sh', 'fallback']
    out = run(fallback + ['task-a'], env=env)
    assert out.startswith('codex no Cursor spending file')
    spending = home / 'usage/now-spending.txt'
    for value, prefix in [('84','cursor'), ('85','codex Cursor Models at 85%'),
                          ('89','codex Cursor Models at 89%'), ('bad','codex cursor_models_pct missing')]:
        spending.write_text('cursor_models_pct=' + value + '\n')
        out = run(fallback + ['task-a'], env=env)
        assert out.startswith(prefix)
    spending.write_text('cursor_models_pct=10\n')
    os.utime(spending, (946684800,946684800))
    out = run(fallback + ['task-a'], env=env)
    assert out.startswith('codex newest Cursor spending file is')
    spending.write_text('cursor_models_pct=89\n')
    (home / 'state/task-a.codex-limit').write_text('Recorded Codex usage limit\n')
    out = run(fallback + ['task-a'], env=env)
    assert out.startswith('claude Cursor Models at 89%')
    out = run(fallback + ['task-b'], env=env)
    assert out.startswith('codex Cursor Models at 89%')
    spending.write_text('cursor_models_pct=10\n')
    out = run(fallback + ['task-a'], env=env)
    assert out.strip() == 'cursor'

def schedule_preview():
    home = LAB / 'schedule-preview'
    home.mkdir()
    env = dict(ENV, FM_DRIFT_AGENT_DIR=str(home / 'agents'))
    out = run(['bash',SCRIPT,'install','--dry-run','--repo',LAB / 'shipped-repository'], env=env)
    assert 'hour: 3\nminute: 17' in out and 'dry-run: install' in out
    run(['bash',SCRIPT,'uninstall','--dry-run'], env=env)
    assert not (home / 'agents').exists()
    log.write('Both real public dry-run commands left the requested agent directory absent.\n')

scenario('The shipped head passes exact proof; later edits to proven source, guard and manifest fail', shipped)
scenario('Rename detection cannot hide an unproved deletion behind a proved copy', hidden_deletion)
scenario('Removing a proven file or changing its executable mode is drift', missing_patch_and_mode)
scenario('A concurrent fork fast-forward cannot change the snapshot or report', lambda: concurrent_snapshot('main'))
scenario('A concurrent upstream fast-forward cannot change the snapshot or report', lambda: concurrent_snapshot('upstream'))
scenario('Cut commits recover from the shipped bundle into a fresh checkout', recovery)
scenario('Label routing and quota fallbacks emit the expected profiles and refusal reasons', routing_and_fallback)
scenario('An operator previews the nightly schedule and removal without side effects', schedule_preview)
log.close()
print(json.dumps(results, indent=2))
raise SystemExit(any(x['result'] == 'fail' for x in results))
