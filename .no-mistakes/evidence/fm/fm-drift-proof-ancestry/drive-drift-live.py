#!/usr/bin/env python3
"""Drive the real drift CLI in disposable Git repositories; never install a job."""
import collections
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5BVRCV3QQMRTF34PSAMRW21')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5BVRCV3QQMRTF34PSAMRW21')
SCRATCH = ROOT / '.agent-state/drift-live-validation-v2'
(SCRATCH / 'tmp').mkdir(parents=True)
SCRIPT = ROOT / 'bin/fm-drift-nightly.sh'
TARGET = '0ac1c7a8dbe1b93e225dacb1ee08c08ae011d78a'
LEAN = '8a8b47345424ebaf2fef14d5d20b6d637a00d4b3'
UPSTREAM = '7df545bf74ff729ed1733f77b0aea02a9b164ac1'
ARCHIVE = 'b2216803f3f438b4fc68f03fbed9816b626769c9'
ENV = dict(os.environ)
for name in list(ENV):
    if name in ('GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE') or name.startswith(('FM_', 'TASKS_AXI_')):
        ENV.pop(name)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0',
           GIT_AUTHOR_NAME='Firstmate Tests', GIT_AUTHOR_EMAIL='tests@example.invalid',
           GIT_COMMITTER_NAME='Firstmate Tests', GIT_COMMITTER_EMAIL='tests@example.invalid',
           GIT_OPTIONAL_LOCKS='0', TMPDIR=str(SCRATCH / 'tmp'), TZ='America/Chicago',
           PYTHONDONTWRITEBYTECODE='1')
RESULTS = []
LOG = (EVIDENCE / 'drift-live-cli.log').open('w')


def run(args, *, cwd=ROOT, expected=0, stdin=None, env=None, show=True):
    args = [str(a) for a in args]
    LOG.write('$ ' + shlex.join(args) + '\n')
    LOG.flush()
    proc = subprocess.run(args, cwd=cwd, env=env or ENV, input=stdin, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if show:
        LOG.write(proc.stdout)
        LOG.write(proc.stderr)
    LOG.write(f'[exit {proc.returncode}]\n\n')
    LOG.flush()
    if expected is not None:
        assert proc.returncode == expected, (shlex.join(args), proc.returncode, expected, proc.stderr)
    return proc


def git(repo, *args, **kwargs):
    return run(['git', '-C', repo, *args], **kwargs)


def write(repo, path, data):
    dest = repo / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(data)


def commit(repo, subject, paths):
    git(repo, 'add', '--', *paths)
    git(repo, 'commit', '-qm', subject)
    return git(repo, 'rev-parse', 'HEAD').stdout.strip()


def init(name, base_files=None):
    repo = SCRATCH / name
    git(SCRATCH, 'init', '-q', '-b', 'main', repo)
    write(repo, 'base.txt', 'upstream\n')
    for path, data in (base_files or {}).items():
        write(repo, path, data)
    commit(repo, 'upstream baseline', ['base.txt', *(base_files or {})])
    git(repo, 'branch', 'upstream')
    return repo


def check(repo, label, *, expected=0, extra=(), script=SCRIPT):
    result = run(['bash', script, 'check', '--no-fetch', '--repo', repo,
                  '--upstream', 'upstream', *extra], expected=expected)
    (EVIDENCE / f'{label}.txt').write_text(result.stdout + result.stderr + f'exit: {result.returncode}\n')
    return result.stdout, result.stderr


def scenario(name, fn):
    LOG.write('SCENARIO: ' + name + '\n\n')
    LOG.flush()
    try:
        detail = fn()
        RESULTS.append(dict(name=name, result='pass', live=True, evidence=detail, reason=''))
        print('PASS ' + name, flush=True)
    except Exception as exc:
        RESULTS.append(dict(name=name, result='fail', live=True, evidence='drift-live-cli.log', reason=str(exc)))
        print('FAIL ' + name + ': ' + str(exc), flush=True)
    (EVIDENCE / 'drift-live-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')


def real_history():
    repo = SCRATCH / 'real-history'
    git(SCRATCH, 'init', '-q', repo)
    git(repo, 'fetch', '-q', '--no-tags', ROOT, TARGET, UPSTREAM, ARCHIVE,
        'ec259ec5895012a507c4abd2d7f10de967249e9e')
    git(repo, 'switch', '-q', '--detach', LEAN)
    git(repo, 'branch', 'upstream', UPSTREAM)
    previous = SCRATCH / 'previous-fm-drift-nightly.sh'
    previous.write_text(run(['git', 'show', f'{TARGET}^:bin/fm-drift-nightly.sh'], show=False).stdout)
    previous.chmod(0o755)
    out, err = check(repo, 'real-upstream-lean-before', script=previous, expected=2)
    assert 'proof commit is not reachable from fork: ec259ec5' in err
    out, err = check(repo, 'real-upstream-lean-after', extra=('--proof', ROOT / 'drift-proof.txt'))
    counts = collections.Counter(line.split(': ', 1)[0] for line in out.splitlines())
    assert counts['path-drift'] == counts['unproven'] == 0
    assert counts['path-ok'] == 107 and counts['pending'] == 59 and counts['keep'] == 26, counts
    counts['behind'] = int(re.search(r'^behind: (\d+)$', out, re.M).group(1))
    counts['ahead'] = int(re.search(r'^ahead: (\d+)$', out, re.M).group(1))
    counts['path-drift'] = counts['unproven'] = 0
    report = {line.split()[1]: line for line in out.splitlines() if line.startswith(('keep: ', 'pending: '))}
    subjects = git(repo, 'log', '--first-parent', '--format=%H %s', f'{UPSTREAM}..{LEAN}').stdout
    prs = {}
    for line in subjects.splitlines():
        match = re.search(r'(?:Merge pull request #|Merge PR #?|\(#)(\d+)', line)
        if match:
            prs[int(match.group(1))] = line.split()[0]
    for pr in (8, 11, 12, 16, 17, 18, 22, 36, 38, 43, 47, 50, 49):
        assert report[prs[pr]].startswith(f'pending: {prs[pr]} .agent-config-dtjsb '), (pr, report.get(prs[pr]))
    assert report[prs[25]].startswith('keep: ')
    (EVIDENCE / 'real-upstream-lean-measurement.json').write_text(json.dumps(dict(
        fork=LEAN, upstream=UPSTREAM, counts=counts,
        required_pending={str(pr): report[prs[pr]] for pr in (8, 11, 12, 16, 17, 18, 22, 36, 38, 43, 47, 50, 49)},
        pr25=report[prs[25]]), indent=2) + '\n')
    return 'real-upstream-lean-before.txt; real-upstream-lean-after.txt; real-upstream-lean-measurement.json'


def squash():
    repo = init('squash')
    git(repo, 'switch', '-q', '-c', 'feature')
    write(repo, 'notes.txt', 'accepted patch\n')
    write(repo, 'drift-proof.txt', 'pr: 7\n')
    branch_sha = commit(repo, 'feature patch before squash', ['notes.txt', 'drift-proof.txt'])
    git(repo, 'switch', '-q', 'main')
    git(repo, 'merge', '-q', '--squash', 'feature')
    squash_sha = commit(repo, 'measured feature (#7)', ['notes.txt', 'drift-proof.txt'])
    git(repo, 'merge-base', '--is-ancestor', branch_sha, squash_sha, expected=1)
    out, _ = check(repo, 'squash-self-proof')
    assert f'keep: {squash_sha} measured feature (#7)' in out and 'path-ok: notes.txt' in out
    previous = SCRATCH / 'previous-fm-drift-nightly.sh'
    _, err = check(repo, 'squash-previous-script', expected=2, script=previous)
    assert 'proof line is not a full sha: pr: 7' in err
    write(repo, 'notes.txt', 'accepted patch\nlater unproven edit\n')
    later = commit(repo, 'later edit with no proof', ['notes.txt'])
    out, _ = check(repo, 'squash-later-edit', expected=1)
    assert 'path-drift: notes.txt' in out and f'unproven: {later}' in out
    return 'squash-self-proof.txt; squash-previous-script.txt; squash-later-edit.txt'


def merge_classes():
    for classification, manifest in [('keep', 'pr: 8\n'), ('pending', 'pending-pr: 8 .agent-config-dtjsb\n')]:
        repo = init('merge-' + classification, {'cut.txt': 'upstream retained\n'})
        git(repo, 'switch', '-q', '-c', 'feature')
        write(repo, 'notes.txt', 'accepted merge patch\n')
        write(repo, 'cut.txt', 'must not be reintroduced by replay\n')
        write(repo, 'drift-proof.txt', manifest)
        carried = commit(repo, 'unlabelled carried feature', ['notes.txt', 'cut.txt', 'drift-proof.txt'])
        git(repo, 'switch', '-q', 'main')
        git(repo, 'merge', '-q', '--no-ff', '--no-commit', 'feature')
        write(repo, 'cut.txt', 'upstream retained\n')
        merged = commit(repo, 'Merge pull request #8 from fixture/feature', ['notes.txt', 'cut.txt', 'drift-proof.txt'])
        out, _ = check(repo, 'first-parent-' + classification)
        assert 'path-drift:' not in out and 'cut.txt' not in out and 'unproven:' not in out
        bead = '.agent-config-dtjsb ' if classification == 'pending' else ''
        assert f'{classification}: {carried} {bead}unlabelled carried feature' in out
        assert f'{classification}: {merged} {bead}Merge pull request #8' in out
        git(repo, 'ls-tree', '-r', '--name-only', 'HEAD')
    return 'first-parent-keep.txt; first-parent-pending.txt'


def malformed():
    repo = init('bad-manifests')
    write(repo, 'notes.txt', 'unproven patch\n')
    sha = commit(repo, 'feature (#7)', ['notes.txt'])
    cases = [
        ('forgotten', '# no manifest entry\n', 1, 'path-drift: notes.txt'),
        ('wrong-number', 'pr: 99\n', 2, 'proof PR has no first-parent commit: 99'),
        ('duplicate', 'pr: 7\npending-pr: 7 bead-7\n', 2, 'duplicate proof entry for PR 7'),
        ('pending-no-bead', 'pending-pr: 7\n', 2, "pending-pr line is not '<number> <bead>'"),
        ('legacy-sha', sha + '\n', 2, 'proof line is not a PR entry'),
    ]
    for label, data, expected, message in cases:
        write(repo, 'manual-proof.txt', data)
        out, err = check(repo, 'manifest-' + label, expected=expected, extra=('--proof', repo / 'manual-proof.txt'))
        assert message in out + err
        if expected == 1:
            assert f'unproven: {sha}' in out
    return '; '.join('manifest-' + case[0] + '.txt' for case in cases)


def committed_only():
    repo = init('committed-only')
    write(repo, 'notes.txt', 'unproven patch\n')
    commit(repo, 'feature (#7)', ['notes.txt'])
    write(repo, 'drift-proof.txt', 'pr: 7\n')
    out, _ = check(repo, 'untracked-proof', expected=1)
    assert 'path-drift: notes.txt' in out
    git(repo, 'add', 'drift-proof.txt')
    out, _ = check(repo, 'staged-proof', expected=1)
    assert 'path-drift: notes.txt' in out
    # Side-branch PR labels cannot serve as first-parent proof entries.
    side = init('side-branch-entry')
    git(side, 'switch', '-q', '-c', 'feature')
    write(side, 'notes.txt', 'feature\n')
    write(side, 'drift-proof.txt', 'pr: 7\npr: 8\n')
    commit(side, 'carried feature (#7)', ['notes.txt', 'drift-proof.txt'])
    git(side, 'switch', '-q', 'main')
    git(side, 'merge', '-q', '--no-ff', '-m', 'Merge PR 8', 'feature')
    _, err = check(side, 'side-branch-entry', expected=2)
    assert 'proof PR has no first-parent commit: 7' in err
    return 'untracked-proof.txt; staged-proof.txt; side-branch-entry.txt'


def recovery():
    repo = SCRATCH / 'archive-consumer'
    git(SCRATCH, 'init', '-q', repo)
    remote = run(['git', 'remote', 'get-url', 'origin']).stdout.strip()
    ref = 'refs/heads/archive/fm-drift-nightly-b2216803'
    listed = run(['git', 'ls-remote', remote, ref, 'refs/heads/fm/fm-drift-nightly'])
    assert f'{ARCHIVE}\t{ref}' in listed.stdout
    git(repo, 'fetch', '-q', '--no-tags', remote, ref)
    assert git(repo, 'rev-parse', 'FETCH_HEAD').stdout.strip() == ARCHIVE
    git(repo, 'cat-file', '-e', f'{ARCHIVE}^{{commit}}')
    # Show an original proof-bearing commit remains retrievable from the archived graph.
    git(repo, 'merge-base', '--is-ancestor', 'e49413a2ca4ed44ea7b8ebddabad1ad2dd307089', ARCHIVE)
    history = git(repo, 'log', '-3', '--oneline', 'FETCH_HEAD').stdout
    (EVIDENCE / 'remote-archive-recovery.txt').write_text(listed.stdout + '\nFetched archive commit: ' + ARCHIVE + '\n' + history)
    return 'remote-archive-recovery.txt; drift-live-cli.log (real remote fetch and ancestry check)'


def repair_delivery():
    repo = SCRATCH / 'real-history'
    git(repo, 'switch', '-q', '-c', 'simulated-repair', LEAN)
    patch = run(['git', 'diff', f'{TARGET}^', TARGET, '--', 'CONTRIBUTING.md', 'bin/fm-drift-nightly.sh',
                 'drift-proof.txt', 'drift-measurements.txt', 'tests/fm-drift-nightly.test.sh'], show=False).stdout
    git(repo, 'apply', '--index', '-', stdin=patch)
    manifest = repo / 'drift-proof.txt'
    manifest.write_text(manifest.read_text() + '# Repair measurement: regressions in tests/fm-drift-nightly.test.sh (disposable PR number).\npr: 999999\n')
    sha = commit(repo, 'repair squash simulation (#999999)', ['drift-proof.txt'])
    out, _ = check(repo, 'repair-squash-with-own-proof')
    assert 'path-drift:' not in out and 'unproven:' not in out
    assert f'keep: {sha} repair squash simulation (#999999)' in out
    assert out.count('\npending: ') == 59
    return 'repair-squash-with-own-proof.txt (synthetic PR 999999; no forge publication)'


def nightly():
    upstream = init('nightly-upstream')
    repo = SCRATCH / 'nightly-fork'
    git(SCRATCH, 'clone', '-q', '--no-local', upstream, repo)
    git(repo, 'remote', 'rename', 'origin', 'kunchenguid')
    write(repo, 'notes.txt', 'accepted patch\n')
    write(repo, 'drift-proof.txt', 'pr: 7\n')
    commit(repo, 'accepted feature (#7)', ['notes.txt', 'drift-proof.txt'])
    home = SCRATCH / 'nightly-home'
    home.mkdir()
    env = dict(ENV, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state'),
               FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'),
               FM_PROJECTS_OVERRIDE=str(home / 'projects'))
    log = EVIDENCE / 'nightly-cli-transcript-final.txt'
    for label, expected in [('green', 0), ('red', 1), ('red-repeat', 1)]:
        if label == 'red':
            write(repo, 'notes.txt', 'accepted patch\nunproven edit\n')
            commit(repo, 'unproven edit after measured PR', ['notes.txt'])
        proc = run(['bash', SCRIPT, 'nightly', '--repo', repo, '--log', log], env=env, expected=expected)
        with log.open('a') as stream:
            stream.write(label + '\n' + proc.stdout + proc.stderr + '\n')
        notes = list((home / 'state/inbox').glob('*.note'))
        assert len(notes) == (0 if label == 'green' else 1), (label, notes)
    note = notes[0].read_text()
    assert 'path-drift: notes.txt' in note and f'Log: {log}' in note
    (EVIDENCE / 'nightly-generated-inbox-note.txt').write_text(note)
    return 'nightly-cli-transcript-final.txt; nightly-generated-inbox-note.txt'


scenario('Remeasure actual upstream-lean after the PR 25 squash and retain required pending classifications', real_history)
scenario('Squash a PR carrying its own manifest line; reject a later unproven edit; previous script fails', squash)
scenario('Merge a kept or pending PR and replay its final first-parent patch without restoring a carried cut', merge_classes)
scenario('Reject missing, wrong-number, duplicate, bead-less and legacy-SHA proof entries', malformed)
scenario('Ignore untracked or staged proof and refuse an entry that exists only on a side branch', committed_only)
scenario('Fetch the published nightly recovery archive and recover its pre-squash ancestry', recovery)
scenario('Deliver the repair as a squash carrying its own numbered proof entry', repair_delivery)
scenario('Run nightly with PR proof; green sends no note and repeated red runs create one isolated note', nightly)
LOG.close()
raise SystemExit(0 if all(row['result'] == 'pass' for row in RESULTS) else 1)
