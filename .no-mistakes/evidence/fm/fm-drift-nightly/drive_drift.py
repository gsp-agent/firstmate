#!/usr/bin/env python3
import json, os, select, shlex, shutil, subprocess, sys, threading, time
from pathlib import Path

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4XNE5RJ4SWE239K2J4FBE3K')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4XNE5RJ4SWE239K2J4FBE3K')
ARCHIVE_ONLY = '--archive-only' in sys.argv
WORK = ROOT / '.agent-state' / ('live-drift-archive-redrive-01M4XNE5' if ARCHIVE_ONLY else 'live-drift-test-01M4XNE5')
WORK.mkdir(parents=True, exist_ok=False)
TMP = WORK / 'tmp'
TMP.mkdir()
ENV = os.environ.copy()
for key in ('GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
    ENV.pop(key, None)
ENV.update(TMPDIR=str(TMP), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Drift Validation', GIT_AUTHOR_EMAIL='validation@example.invalid',
           GIT_COMMITTER_NAME='Drift Validation', GIT_COMMITTER_EMAIL='validation@example.invalid',
           FM_TEST_SKIP_ORPHAN_REAP='1')
SCRIPT = ROOT / 'bin' / 'fm-drift-nightly.sh'
RESULTS = [r for r in json.loads((EVIDENCE / 'scenario-results.json').read_text()) if not r['name'].startswith('Removed custom patches')] if ARCHIVE_ONLY else []
LOGS = {}

def log(name):
    if name not in LOGS:
        LOGS[name] = open(EVIDENCE / name, 'a' if ARCHIVE_ONLY else 'w', encoding='utf-8', buffering=1)
    return LOGS[name]

def command(args, *, cwd=ROOT, expected=0, record=None, env=ENV):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True, capture_output=True)
    if record:
        dest = log(record)
        dest.write('$ ' + shlex.join([str(a) for a in args]) + '\n')
        dest.write(result.stdout)
        if result.stderr:
            dest.write('stderr:\n' + result.stderr)
        dest.write(f'exit: {result.returncode}\n\n')
    if expected is not None and result.returncode != expected:
        raise AssertionError(f'{args}: expected exit {expected}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result

def git(repo, *args, **kwargs):
    return command(['git', '-C', repo, *args], **kwargs)

def commit(repo, message):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-qm', message)
    return git(repo, 'rev-parse', 'HEAD').stdout.strip()

def repository(name, files=None):
    repo = WORK / name
    repo.mkdir()
    git(repo, 'init', '-q', '-b', 'main')
    for name, content in (files or {'notes.txt': 'upstream\n'}).items():
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    base = commit(repo, 'upstream baseline')
    git(repo, 'branch', 'upstream')
    return repo, base

def proof(repo, shas):
    path = repo.parent / (repo.name + '-proof.txt')
    path.write_text('\n'.join(shas) + '\n')
    return path

def check(repo, accepted=None, expected=0, record='cli-live.log', fetch=False):
    args = ['bash', SCRIPT, 'check', '--repo', repo, '--upstream', 'kunchenguid/main' if fetch else 'upstream']
    if not fetch:
        args.append('--no-fetch')
    if accepted:
        args.extend(['--proof', accepted])
    return command(args, expected=expected, record=record)

def require(result, *lines):
    output = result.stdout.splitlines()
    for line in lines:
        assert line in output, f'Missing public output {line!r}: {output!r}'

def scenario(name, fn, live=True):
    if ARCHIVE_ONLY and fn.__name__ != 'archive_and_diff':
        return
    try:
        fn()
        item = dict(name=name, result='pass', live=live)
    except Exception as error:
        item = dict(name=name, result='fail', live=live, reason=str(error))
    RESULTS.append(item)
    print(json.dumps(item), flush=True)


def automated():
    command(['bash', 'tests/fm-drift-nightly.test.sh'], record='focused-tests.log')
scenario('Focused existing guard regression tests', automated, False)


def archive_and_diff():
    upstream = '7df545bf74ff729ed1733f77b0aea02a9b164ac1'
    result = command(['git', 'diff', '--name-only', upstream, 'HEAD'], record='archive-recovery.log')
    expected = {'archives/fork-cuts.bundle', 'bin/fm-drift-nightly.sh', 'docs/scripts.md',
                'drift-measurements.txt', 'drift-proof.txt', 'tests/fm-drift-nightly.test.sh'}
    assert set(result.stdout.splitlines()) == expected
    command(['git', 'bundle', 'verify', 'archives/fork-cuts.bundle'], record='archive-recovery.log')
    seed = WORK / 'source.bundle'
    command(['git', 'bundle', 'create', seed, 'HEAD'])
    restored = WORK / 'recovery'
    command(['git', 'clone', '-q', str(seed), restored])
    heads = command(['git', 'bundle', 'list-heads', 'archives/fork-cuts.bundle'], record='archive-recovery.log')
    entries = [line.split() for line in heads.stdout.splitlines()]
    assert len(entries) == 8
    for sha, ref in entries:
        git(restored, 'fetch', ROOT / 'archives/fork-cuts.bundle', f'{ref}:{ref}', record='archive-recovery.log')
        actual = git(restored, 'rev-parse', ref, record='archive-recovery.log').stdout.strip()
        assert actual == sha
        command(['git', 'cat-file', '-e', sha + '^{tree}'])
    original = command(['git', 'show', '--no-patch', '--format=%B', '85bc5153']).stdout
    cut_shas = [line.split()[1] for line in original.splitlines() if line.startswith('cut ') and len(line.split()[1]) == 40 and all(c in '0123456789abcdef' for c in line.split()[1])]
    remote = command(['git', 'ls-remote', 'https://github.com/gsp-agent/firstmate.git', 'refs/heads/archive/*'],
                     expected=None, record='archive-recovery.log')
    if remote.returncode == 0:
        archived = {line.split()[0] for line in remote.stdout.splitlines()}
        missing = set(cut_shas) - archived
        assert not missing, f'Missing remote archive branches: {sorted(missing)}'
        log('archive-recovery.log').write(f'All {len(cut_shas)} earlier cuts have remote archive heads; all 8 additional cuts were fetched and restored from the bundle.\n')
    else:
        RESULTS.append(dict(name='Verify earlier cuts have remote recovery branches', result='untested', live=False,
                            reason='Read-only git ls-remote could not reach gsp-agent/firstmate; provide repository read access and network reachability.'))
scenario('Removed custom patches leave only the requested guard; all eight new archive branches recover their exact commits', archive_and_diff)


def exact_proof():
    repo, base = repository('exact', {'notes.txt': ''.join(f'line {i}\n' for i in range(1, 21))})
    original = (repo / 'notes.txt').read_text()
    (repo / 'notes.txt').write_text(original.replace('line 20\n', 'measured last line\n'))
    kept = commit(repo, 'accepted last-line patch')
    accepted = proof(repo, [kept])
    require(check(repo, accepted), 'path-ok: notes.txt', f'keep: {kept} accepted last-line patch')
    (repo / 'notes.txt').write_text((repo / 'notes.txt').read_text().replace('line 1\n', 'unproved first line\n'))
    later = commit(repo, 'unproved edit to accepted file')
    require(check(repo, accepted, expected=1), 'path-drift: notes.txt', f'unproven: {later} unproved edit to accepted file')
    (repo / 'notes.txt').write_text(original.replace('line 20\n', 'measured last line\n'))
    commit(repo, 'remove unproved edit')
    require(check(repo, accepted), 'path-ok: notes.txt')
    (repo / 'notes.txt').chmod(0o755)
    commit(repo, 'unproved executable permission')
    require(check(repo, accepted, expected=1), 'path-drift: notes.txt')
scenario('An accepted patch passes; later edits and file modes fail, and cutting the edit restores a pass', exact_proof)


def exemptions_and_missing():
    repo, base = repository('guard-paths')
    for name in ('bin/fm-drift-nightly.sh', 'tests/fm-drift-nightly.test.sh', 'docs/scripts.md', 'drift-proof.txt'):
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('guard baseline\n' if name != 'drift-proof.txt' else '# proof baseline\n')
    kept = commit(repo, 'accepted guard files')
    accepted = proof(repo, [kept])
    require(check(repo, accepted), 'path-ok: bin/fm-drift-nightly.sh')
    for name in ('bin/fm-drift-nightly.sh', 'tests/fm-drift-nightly.test.sh', 'docs/scripts.md', 'drift-proof.txt'):
        with (repo / name).open('a') as stream:
            stream.write('# unproved edit\n')
    commit(repo, 'unproved changes to guard paths')
    require(check(repo, accepted, expected=1), *(f'path-drift: {p}' for p in ('bin/fm-drift-nightly.sh', 'tests/fm-drift-nightly.test.sh', 'docs/scripts.md', 'drift-proof.txt')))
    missing, base = repository('missing-proof')
    (missing / 'accepted.txt').write_text('accepted\n')
    kept = commit(missing, 'accepted file')
    accepted = proof(missing, [kept])
    git(missing, 'rm', '-q', 'accepted.txt')
    commit(missing, 'unproved removal of accepted file')
    require(check(missing, accepted, expected=1), 'path-drift: accepted.txt')
scenario('Guard and proof files have no exemption; deleting an accepted patch fails even when the fork otherwise matches upstream', exemptions_and_missing)


def rename_deletion():
    repo, base = repository('rename', {'original.txt': 'identical contents\n'})
    git(repo, 'config', 'diff.renames', 'true')
    (repo / 'copy.txt').write_bytes((repo / 'original.txt').read_bytes())
    kept = commit(repo, 'accepted identical copy')
    accepted = proof(repo, [kept])
    git(repo, 'rm', '-q', 'original.txt')
    later = commit(repo, 'unproved original deletion')
    git(repo, 'diff', '--name-status', 'upstream', 'HEAD', record='rename-deletion.log')
    require(check(repo, accepted, expected=1, record='rename-deletion.log'),
            'path-ok: copy.txt', 'path-drift: original.txt', f'unproven: {later} unproved original deletion')
scenario('Rename detection cannot hide an unproved original-file deletion behind an accepted identical copy', rename_deletion)


def invalid_proof():
    repo, base = repository('invalid-proof')
    accepted = proof(repo, ['0' * 40])
    result = check(repo, accepted, expected=2)
    assert 'proof commit not found:' in result.stderr
    git(repo, 'switch', '-q', '-c', 'unrelated')
    (repo / 'not-on-fork.txt').write_text('unaccepted branch\n')
    other = commit(repo, 'unreachable proof')
    git(repo, 'switch', '-q', 'main')
    accepted = proof(repo, [other])
    result = check(repo, accepted, expected=2)
    assert 'proof commit is not reachable from fork:' in result.stderr
scenario('Unknown and unreachable proof commits produce actionable errors rather than authorization', invalid_proof)


def real_fetch():
    remote, base = repository('fetch-upstream')
    fork = WORK / 'fetch-fork'
    command(['git', 'clone', '-q', remote, fork])
    git(fork, 'remote', 'rename', 'origin', 'kunchenguid')
    (fork / 'accepted.txt').write_text('measured patch\n')
    kept = commit(fork, 'accepted patch')
    accepted = proof(fork, [kept])
    (remote / 'upstream-later.txt').write_text('upstream update\n')
    newest = commit(remote, 'upstream advanced')
    require(check(fork, accepted, record='fetch-and-snapshot.log', fetch=True),
            'behind: 1', 'ahead: 1', 'path-ok: accepted.txt', f'keep: {kept} accepted patch')
    assert git(fork, 'rev-parse', 'kunchenguid/main', record='fetch-and-snapshot.log').stdout.strip() == newest
scenario('A real fetch updates upstream before the check captures and reports its comparison', real_fetch)


def moving_ref(which):
    repo, base = repository('moving-' + which)
    kept = []
    for i in range(12):
        (repo / f'accepted-{i:02}.txt').write_text('measured patch\n')
        kept.append(commit(repo, f'accepted patch {i}'))
    accepted = proof(repo, kept)
    if which == 'fork':
        git(repo, 'switch', '-q', '-c', 'later', 'main')
        (repo / 'unproved-later.txt').write_text('unproved update\n')
        future = commit(repo, 'unproved future commit')
        ref = 'refs/heads/main'
    else:
        git(repo, 'switch', '-q', '-c', 'later', 'upstream')
        (repo / 'upstream-later.txt').write_text('upstream update\n')
        future = commit(repo, 'future upstream commit')
        ref = 'refs/heads/upstream'
    git(repo, 'switch', '-q', 'main')
    before = git(repo, 'rev-parse', ref, record='fetch-and-snapshot.log').stdout.strip()
    race_tmp = TMP / which
    race_tmp.mkdir()
    race_env = ENV.copy()
    race_env['TMPDIR'] = str(race_tmp)
    directory_fd = os.open(race_tmp, os.O_RDONLY)
    queue = select.kqueue()
    event = select.kevent(directory_fd, filter=select.KQ_FILTER_VNODE,
                         flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)
    queue.control([event], 0)
    args = ['bash', str(SCRIPT), 'check', '--repo', str(repo), '--upstream', 'upstream', '--no-fetch', '--proof', str(accepted)]
    process = subprocess.Popen(args, cwd=ROOT, env=race_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    events = queue.control(None, 1, 10)
    assert events, 'No real filesystem event observed during guard execution'
    dirs = list(race_tmp.glob('fm-drift.*'))
    assert dirs, 'Guard did not create its runtime comparison directory'
    assert process.poll() is None, 'The check finished before a concurrent ref movement could be injected'
    git(repo, 'update-ref', ref, future, before, record='fetch-and-snapshot.log')
    running_after_move = process.poll() is None
    stdout, stderr = process.communicate(timeout=30)
    queue.close()
    os.close(directory_fd)
    dest = log('fetch-and-snapshot.log')
    dest.write(f'Observed real filesystem event {dirs[0].name}; advanced {which} ref while the guard was running.\n')
    dest.write('$ ' + shlex.join(args) + '\n' + stdout + stderr + f'exit: {process.returncode}\n')
    dest.write(f'Process was still running immediately after ref update: {running_after_move}\n\n')
    assert process.returncode == 0
    assert running_after_move
    assert stdout.splitlines()[:2] == ['behind: 0', 'ahead: 12']
    assert set(line for line in stdout.splitlines() if line.startswith('keep: ')) == {
        f'keep: {sha} accepted patch {i}' for i, sha in enumerate(kept)}
    assert 'unproved-later.txt' not in stdout and 'upstream-later.txt' not in stdout
    assert git(repo, 'rev-parse', ref, record='fetch-and-snapshot.log').stdout.strip() == future
    if which == 'fork':
        require(check(repo, accepted, expected=1, record='fetch-and-snapshot.log'),
                'ahead: 13', 'path-drift: unproved-later.txt', f'unproven: {future} unproved future commit')
    else:
        require(check(repo, accepted, record='fetch-and-snapshot.log'), 'behind: 1', 'ahead: 12')
scenario('A fork advancing during validation cannot alter the captured comparison or report; the next run detects its new drift', lambda: moving_ref('fork'))
scenario('An upstream advancing during validation cannot alter the captured comparison or report; the next run sees the update', lambda: moving_ref('upstream'))


def dry_run():
    agents = WORK / 'agents'
    dry_env = ENV.copy()
    dry_env['FM_DRIFT_AGENT_DIR'] = str(agents)
    result = command(['bash', SCRIPT, 'install', '--dry-run', '--repo', WORK / 'fetch-fork', '--hour', '4', '--minute', '5'],
                     env=dry_env, record='scheduler-dry-run.log')
    require(result, 'dry-run: install', 'hour: 4', 'minute: 5')
    assert not agents.exists()
    command(['bash', SCRIPT, 'uninstall', '--dry-run'], env=dry_env, record='scheduler-dry-run.log')
    assert not agents.exists()
scenario('An operator previews nightly installation and uninstallation without changing files or loading a LaunchAgent', dry_run)

(EVIDENCE / 'scenario-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
for stream in LOGS.values():
    stream.close()
print('WORK=' + str(WORK), flush=True)
print('Failed scenarios: ' + str(sum(r['result'] == 'fail' for r in RESULTS)), flush=True)
