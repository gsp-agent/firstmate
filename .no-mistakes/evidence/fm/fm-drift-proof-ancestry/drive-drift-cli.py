import json, os, pathlib, subprocess

ROOT = pathlib.Path.cwd()
WORK = ROOT / '.drift-live/run2'
WORK.mkdir()
(WORK / 'tmp').mkdir()
EVIDENCE = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FPY4GATHC7W512DH546C9M')
SCRIPT = ROOT / 'bin/fm-drift-nightly.sh'
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k.startswith('GIT_'))}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Firstmate Tests', GIT_AUTHOR_EMAIL='tests@example.invalid',
           GIT_COMMITTER_NAME='Firstmate Tests', GIT_COMMITTER_EMAIL='tests@example.invalid',
           TMPDIR=str(WORK / 'tmp'))
transcript = []
results = []

def run(args, cwd=ROOT, expected=0, input=None, extra=None, record=False):
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=env | (extra or {}),
                       input=input, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if record:
        transcript.append('$ ' + ' '.join(map(str, args)) + '\n' + p.stdout + f'exit: {p.returncode}\n')
    assert p.returncode == expected, f'{args}: expected {expected}, got {p.returncode}\n{p.stdout}'
    return p.stdout

def git(repo, *args, **kwargs):
    return run(['git', '-C', repo, *args], **kwargs).strip()

def write(repo, file, content):
    (repo / file).parent.mkdir(parents=True, exist_ok=True)
    (repo / file).write_text(content)

def commit(repo, subject):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-qm', subject)
    return git(repo, 'rev-parse', 'HEAD')

def fixture(name):
    repo = WORK / name
    git(ROOT, 'init', '-q', '-b', 'main', repo)
    write(repo, 'README', 'base\n')
    commit(repo, 'base')
    git(repo, 'branch', 'upstream')
    return repo

def check(repo, code=0, proof=None, script=SCRIPT):
    args = ['bash', script, 'check', '--repo', repo, '--no-fetch', '--upstream', 'upstream']
    if proof: args += ['--proof', proof]
    return run(args, expected=code, record=True)

def passed(name):
    results.append({'name': name, 'result': 'pass', 'live': True})

try:
    repo = fixture('squash')
    git(repo, 'switch', '-qc', 'feature')
    write(repo, 'notes.txt', 'accepted\n')
    write(repo, 'drift-proof.txt', 'pr: 7\n')
    commit(repo, 'feature work')
    git(repo, 'switch', '-q', 'main')
    git(repo, 'merge', '-q', '--squash', 'feature')
    sha = commit(repo, 'feature (#7)')
    out = check(repo)
    assert f'keep: {sha} feature (#7)' in out and 'path-drift:' not in out
    old = WORK / 'before-pr-key.sh'
    old.write_text(git(ROOT, 'show', 'cfb4a4d1:bin/fm-drift-nightly.sh') + '\n')
    out = check(repo, 2, script=old)
    assert 'error:' in out
    passed('Squash carries its own PR proof; old guard rejects the same manifest')
    write(repo, 'notes.txt', 'unapproved edit\n')
    commit(repo, 'later edit')
    out = check(repo, 1)
    assert 'path-drift: notes.txt' in out
    passed('Later unproven edits cannot borrow accepted proof')

    repo = fixture('conflict-merge')
    git(repo, 'switch', '-qc', 'feature')
    write(repo, 'notes.txt', 'feature\n')
    carried = commit(repo, 'side feature (#77)')
    git(repo, 'switch', '-q', 'main')
    write(repo, 'notes.txt', 'main\n')
    write(repo, 'drift-proof.txt', 'pr: 9\n')
    commit(repo, 'main feature (#9)')
    git(repo, 'merge', '--no-ff', '--no-commit', 'feature', expected=1)
    write(repo, 'notes.txt', 'resolution\n')
    write(repo, 'drift-proof.txt', 'pr: 9\npending-pr: 10 bead-proof\n')
    merge = commit(repo, 'Merge PR #10')
    out = check(repo)
    assert f'pending: {carried} bead-proof' in out and f'pending: {merge} bead-proof' in out
    assert 'missing manifest entry for PR 77' not in out and 'path-drift:' not in out
    passed('Conflict-resolved merge replays only its first-parent patch and carries pending classification')

    previous = WORK / 'before-coverage.sh'
    previous.write_text(git(ROOT, 'show', '8385c50c:bin/fm-drift-nightly.sh') + '\n')
    for kind in ('squash', 'merge'):
        repo = fixture('reverted-' + kind)
        git(repo, 'switch', '-qc', 'feature')
        write(repo, 'notes.txt', 'forgotten\n')
        commit(repo, 'side feature (#17)')
        git(repo, 'switch', '-q', 'main')
        if kind == 'squash':
            git(repo, 'merge', '-q', '--squash', 'feature')
            commit(repo, 'forgotten (#7)')
        else:
            git(repo, 'merge', '-q', '--no-ff', '-m', 'Merge pull request #7 from feature', 'feature')
        git(repo, 'rm', '-q', 'notes.txt')
        write(repo, 'drift-proof.txt', 'pr: 8\n')
        commit(repo, 'revert forgotten (#8)')
        out = check(repo, 1)
        assert 'path-drift:' not in out and 'error: missing manifest entry for PR 7' in out
        assert 'missing manifest entry for PR 17' not in out
        # Same input on the pre-fix executable reproduces the false green.
        out = check(repo, 0, script=previous)
        assert 'path-drift:' not in out
        for entry in ('pr: 7', 'pending-pr: 7 bead-seven'):
            write(repo, 'manual-proof', 'pr: 8\n' + entry + '\n')
            check(repo, proof=repo / 'manual-proof')
        passed(f'Reverted unlisted {kind} PR stays red; either proof class clears it (before/after reproduced)')
        # Real fetch uses a disposable local upstream; real inbox writes only into this fixture home.
        git(repo, 'remote', 'add', 'kunchenguid', str(repo))
        git(repo, 'config', 'remote.kunchenguid.fetch', '+refs/heads/upstream:refs/remotes/kunchenguid/main')
        # fetch main is explicit in the executable; publish a clean upstream repo instead.
        remote = WORK / ('remote-' + kind)
        git(ROOT, 'clone', '-q', '--no-local', repo, remote)
        upstream_sha = git(repo, 'rev-parse', 'upstream')
        git(remote, 'switch', '-q', '--detach', upstream_sha)
        git(remote, 'branch', '-f', 'main', upstream_sha)
        git(repo, 'remote', 'set-url', 'kunchenguid', str(remote))
        git(repo, 'config', 'remote.kunchenguid.fetch', '+refs/heads/main:refs/remotes/kunchenguid/main')
        home = WORK / ('home-' + kind)
        home.mkdir()
        isolation = {'FM_HOME': str(home), 'FM_STATE_OVERRIDE': str(home / 'state'),
                     'FM_DATA_OVERRIDE': str(home / 'data'), 'FM_CONFIG_OVERRIDE': str(home / 'config')}
        args = ['bash', SCRIPT, 'nightly', '--repo', repo, '--log', home / 'drift.log']
        for repeat in range(2): run(args, expected=1, extra=isolation, record=True)
        notes = list((home / 'state/inbox').glob('*.note'))
        assert len(notes) == 1
        body = notes[0].read_text()
        assert 'error: missing manifest entry for PR 7' in body
        (EVIDENCE / ('nightly-' + kind + '.note')).write_text(body)
        passed(f'Nightly fetch reports forgotten {kind} PR and queues exactly one named note on repeat')

    repo = fixture('unnumbered-cut')
    write(repo, 'notes.txt', 'historical\n')
    commit(repo, 'historical unnumbered commit')
    git(repo, 'rm', '-q', 'notes.txt')
    commit(repo, 'cut historical change')
    check(repo)
    write(repo, 'proof', 'pr: 99\n')
    out = check(repo, proof=repo / 'proof')
    assert 'unmatched: 99' in out
    passed('Cut unnumbered history stays green and a future PR entry is unmatched without usage failure')

    repo = ROOT / '.drift-live/history'
    upstream = '7df545bf74ff729ed1733f77b0aea02a9b164ac1'
    args = ['bash', SCRIPT, 'check', '--repo', repo, '--no-fetch', '--upstream', upstream]
    out = run(args + ['--fork', 'cdd12e94', '--proof', ROOT / 'drift-proof.txt'], record=True)
    assert 'path-drift:' not in out and 'unmatched: 53' in out
    (EVIDENCE / 'upstream-history-check.log').write_text(out + 'exit: 0\n')
    tree = git(repo, 'rev-parse', '40dfccda^{tree}')
    squash = git(repo, 'commit-tree', tree, '-p', 'cdd12e94', input='repair drift ancestry (#53)\n')
    out = run(args + ['--fork', squash], record=True)
    assert f'keep: {squash}' in out and 'path-drift:' not in out and 'unmatched:' not in out
    pending = sum(line.startswith('pending:') for line in out.splitlines())
    assert pending == 67, pending
    (EVIDENCE / 'target-squash-history-check.log').write_text(out + 'exit: 0\n')
    passed('Exact target tree squashed as PR 53 on recorded upstream-lean stays green with 67 pending')
finally:
    (EVIDENCE / 'live-drift-cli-transcript.log').write_text('\n'.join(transcript))
    (EVIDENCE / 'live-drift-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
