#!/usr/bin/env python3
"""Disposable live verification; no fake product, forge CLI, backlog CLI, or dcg."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53B462Z5XMWXCWAM0Z5M7BA')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M53B462Z5XMWXCWAM0Z5M7BA')
LAB = ROOT / '.test-phase/live'
HELPER = ROOT / 'bin/fm-task-data.py'
LOCKED = EVIDENCE / 'drive-task-data-command.sh'
P4 = 'https://github.com/groovejones/groove-sight-platform/pull/4364'
P5 = 'https://github.com/groovejones/groove-sight-platform/pull/4365'
results = []
recovery_only = sys.argv[1:] == ['--recovery-only']
logfile = (EVIDENCE / ('recovery-cycle.log' if recovery_only else 'live-task-data.log')).open('w')

def log(value):
    print(value, flush=True)
    print(value, file=logfile, flush=True)

def run(args, env=None, cwd=ROOT, expected=0):
    log('$ ' + shlex.join(map(str, args)))
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=env,
                       capture_output=True, text=True, timeout=120)
    if p.stdout.strip():
        log(p.stdout.rstrip())
    if p.stderr.strip():
        log('stderr: ' + p.stderr.rstrip())
    log('exit=' + str(p.returncode))
    assert p.returncode == expected, p.stderr
    return p

def check(condition, detail):
    log(('PASS: ' if condition else 'FAIL: ') + detail)
    assert condition, detail

def row(task='retired', pr='', project='demo', date='', notes=''):
    suffix = f' (done {date})' if date else ''
    return f'- [x] {task} - finished {pr} (repo: {project}){suffix}\n' + notes

def new_home(name, current='', archived='', files=None):
    h = LAB / name
    for rel in ('data/retired', 'state', 'config', 'projects/demo', 'history',
                'user', 'xdg-config', 'xdg-cache', 'tmp'):
        (h / rel).mkdir(parents=True, exist_ok=False)
    (h / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "history/completed.md"\n')
    (h / 'data/backlog.md').write_text('# Backlog\n\n## Done\n' + current)
    (h / 'history/completed.md').write_text('# Archive\n' + archived)
    for name, contents in (files or {'current-pr-only.bin': b'current evidence\x00\xff',
                                   'discard.bin': b'unlinked scratch\x00\xff'}).items():
        (h / 'data/retired' / name).write_bytes(contents)
    return h

token = subprocess.run(['gh', 'auth', 'token', '--user', 'gsp-agent'],
                       capture_output=True, text=True, check=True).stdout.strip()
assert token

def environment(h, invalid_token=False):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('FM_', 'TASKS_AXI_', 'BEADS_', 'BR_', 'GIT_'))
           and k not in ('STATE', 'DATA', 'CONFIG', 'PROJECTS', 'NO_MISTAKES_GATE', 'GH_TOKEN', 'GITHUB_TOKEN')}
    env.update(FM_HOME=str(h), HOME=str(h / 'user'),
               XDG_CONFIG_HOME=str(h / 'xdg-config'), XDG_CACHE_HOME=str(h / 'xdg-cache'),
               TMPDIR=str(h / 'tmp'), GH_TOKEN='disposable-invalid-token' if invalid_token else token,
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    return env

def action(h, kind, project=None, pr=None, helper=HELPER, invalid=False, expected=0):
    args = ['bash', LOCKED, ROOT, h / 'data', h / 'state', 'retired', helper, kind]
    if kind == 'stage':
        args += [project or h / 'projects/demo', pr or '']
    return run(args, environment(h, invalid), expected=expected)

def record(h):
    return json.loads((h / 'data/retired/record/data-cleanup.json').read_text())

def snapshot(h, phase):
    task = h / 'data/retired'
    listing = sorted(str(p.relative_to(task)) for p in task.rglob('*') if p.is_file())
    log(json.dumps({'home': h.name, 'phase': phase, 'files': listing,
                    'record': record(h) if (task / 'record/data-cleanup.json').exists() else None}, indent=2))

def scenario(name, fn):
    if recovery_only and not name.startswith('One-cycle recovery'):
        return
    log('\nSCENARIO: ' + name)
    try:
        fn()
        results.append({'name': name, 'result': 'pass', 'live': True})
    except Exception as error:
        log('SCENARIO FAILED: ' + str(error))
        results.append({'name': name, 'result': 'fail', 'live': True, 'error': str(error)})

def real_readers():
    for number in (4364, 4365):
        text = (ROOT / f'.test-phase/pr-{number}.txt').read_text()
        log('$ bash bin/fm-task-data-lib.sh references ' + (P4 if number == 4364 else P5))
        log('\n'.join(text.splitlines()[:7]))
        check(f'number: {number}' in text and 'state: merged' in text,
              f'real GitHub helper returned PR {number} including full body, comments and reviews')
        log(f'exit=0 response_bytes={len(text.encode())} sha256={hashlib.sha256(text.encode()).hexdigest()}')

p4text = (ROOT / '.test-phase/pr-4364.txt').read_text()
p5text = (ROOT / '.test-phase/pr-4365.txt').read_text()
pr_only = next(n for n in ('initial.title', 'encodeURIComponent', 'DealForm.events.test.tsx')
               if n in p4text and n not in p5text)
log('Real PR 4364-only binary filename selected from the actual response: ' + pr_only)
LAB.mkdir(exist_ok=recovery_only)

scenario('Both named GSP PRs are readable through the real references helper', real_readers)

def current_priority(variant, helper=HELPER, baseline=False):
    h = new_home(variant, current=row(pr=P4, date='' if 'undated' in variant else '2026-10-01',
                                      notes='  [capture](current-pr-only.bin)\n'),
                 archived=row(pr=P5, project='obsolete', date='2026-10-10'))
    (h / 'projects/obsolete').mkdir()
    (h / 'data/retired' / pr_only).write_bytes(b'referenced only by real PR 4364\x00\xff')
    action(h, 'prepare', helper=helper)
    source = record(h)['sources'][-1]
    log('SELECTED: ' + json.dumps({'project': source['project'], 'pr': source['pr']}))
    if baseline:
        check(source['pr'] == P5, 'pre-fix executable selects the archived PR despite the current checked row')
    else:
        check(source['pr'] == P4 and source['project'] == str(h / 'projects/demo'),
              'current checked row supplies the project and PR despite archive date')
    action(h, 'stage', source['project'], source['pr'], helper=helper)
    snapshot(h, 'after-stage')
    action(h, 'expire', helper=helper)
    snapshot(h, 'after-expire')
    present = (h / 'data/retired' / pr_only).exists()
    if baseline:
        check(not present, 'pre-fix executable deletes the binary referenced only by the current real PR')
        log('EXPECTED BASELINE FAILURE reproduced: current PR-only evidence deleted')
    else:
        check(present, 'actual current-PR-only binary survives both staging and expiry')
        check((h / 'data/retired/current-pr-only.bin').read_bytes() == b'current evidence\x00\xff',
              'current-pr-only.bin survives both staging and expiry unchanged')
        check(not (h / 'data/retired/.cleanup-hold').exists(), 'unlinked scratch expires')

old_bin = ROOT / '.test-phase/pre-fix-bin'
old_bin.mkdir(exist_ok=recovery_only)
for path in (ROOT / 'bin').iterdir():
    if path.name != 'fm-task-data.py' and not recovery_only:
        (old_bin / path.name).symlink_to(path)
if not recovery_only:
    (old_bin / 'fm-task-data.py').write_bytes(subprocess.run(
        ['git', 'show', 'fa6c951c:bin/fm-task-data.py'], cwd=ROOT, capture_output=True, check=True).stdout)
scenario('Pre-fix counterfactual reproduces the reported evidence deletion',
         lambda: current_priority('baseline-current-undated', old_bin / 'fm-task-data.py', True))
scenario('Current undated checked row beats a dated archive through stage and expiry',
         lambda: current_priority('current-undated'))
scenario('Older dated current checked row beats a newer archive through stage and expiry',
         lambda: current_priority('current-older'))

def uncertain_sources():
    variants = {
        'missing-row': ('', ''),
        'active-row': ('- [ ] retired - active (repo: demo)\n', row(date='2026-10-10')),
        'archive-undated': ('', row(pr=P5) + row(pr=P4, date='2026-10-11')),
        'archive-tied': ('', row(pr=P5, date='2026-10-10') + row(pr=P4, date='2026-10-10')),
        'archive-invalid': ('', row(pr=P5, date='2026-99-99') + row(pr=P4, date='2026-10-11')),
        'current-tied': (row(pr=P5, date='2026-10-10') + row(pr=P4, date='2026-10-10'), ''),
        'project-tied': ('', row(project='obsolete', date='2026-10-10') + row(date='2026-10-10')),
        'multiple-note-prs': (row(notes=f'  GitLab merge request https://gitlab.example.invalid/group/repo/-/merge_requests/7\n  Gerrit change https://review.example.invalid/c/group/repo/+/7\n'), ''),
    }
    for name, (current, archive) in variants.items():
        h = new_home(name, current, archive)
        before = {p.name: p.read_bytes() for p in (h / 'data/retired').iterdir()}
        response = action(h, 'prepare')
        check('retired' in response.stderr and 'retained whole' in response.stderr,
              name + ': successful pass names the retained folder')
        check({p.name: p.read_bytes() for p in (h / 'data/retired').iterdir()} == before,
              name + ': every original file stays in place; no hold or cleanup record invented')

scenario('Missing, active and unprovably ordered conflicting rows retain and name the whole folder', uncertain_sources)

def named_beads_and_latest():
    h = new_home('archive-and-bead', archived=row(pr=P5, project='obsolete', date='2026-10-10')
                 + row(pr=P4, date='2026-10-11', notes='  [row capture](row-only.bin)\n'))
    owner = h / 'user/dev/gsp-beads'
    owner.mkdir(parents=True)
    run(['br', 'init', '--prefix', 'gsp'], environment(h), owner)
    created = run(['br', 'create', 'Disposable cleanup proof', '--description', '[bead capture](bead-only.bin)', '--json'], environment(h), owner)
    parsed = json.loads(created.stdout)
    bead = parsed['id']
    with (h / 'history/completed.md').open('a') as file:
        file.write('  Bead ' + bead + '\n')
    for name in ('bead-only.bin', 'row-only.bin'):
        (h / 'data/retired' / name).write_bytes(b'evidence\x00\xff')
    action(h, 'prepare')
    source = record(h)['sources'][-1]
    check(source['pr'] == P4 and source['beads'] == [bead], 'latest distinct valid archive date supplies PR and named bead')
    action(h, 'stage', source['project'], source['pr'])
    action(h, 'expire')
    snapshot(h, 'after-expire')
    check(all((h / 'data/retired' / name).read_bytes() == b'evidence\x00\xff'
              for name in ('bead-only.bin', 'row-only.bin')), 'real named gsp bead and completed-row evidence both survive expiry')

scenario('Latest provable archive row and a real named gsp bead retain their evidence', named_beads_and_latest)

def duplicate_sources():
    h = new_home('duplicate-sources', archived=row(notes='  [older capture](older-row.bin)\n')
                 + row(date='2026-10-11', notes='  [newer capture](newer-row.bin)\n'))
    for name in ('older-row.bin', 'newer-row.bin'):
        (h / 'data/retired' / name).write_bytes(b'row proof')
    action(h, 'prepare')
    source = record(h)['sources'][-1]
    check(all(name in source['backlog']['text'] for name in ('older-row.bin', 'newer-row.bin')),
          'duplicate possible rows with identical project and PR preserve both row bodies')
    action(h, 'stage', source['project'], source['pr'])
    action(h, 'expire')
    snapshot(h, 'after-expire')
    check(all((h / 'data/retired' / name).read_bytes() == b'row proof'
              for name in ('older-row.bin', 'newer-row.bin')), 'both unordered same-identity rows retain their evidence')

scenario('Duplicate possible rows for one project and PR retain all referenced evidence', duplicate_sources)

def late_conflicts():
    original = row(notes='  [capture](current-pr-only.bin)\n')
    h = new_home('late-conflicts', current=original)
    action(h, 'prepare')
    backlog = h / 'data/backlog.md'
    base = backlog.read_text()
    backlog.write_text(base + row(pr=P5))
    response = action(h, 'stage')
    check('retired' in response.stderr and not (h / 'data/retired/.cleanup-hold').exists(),
          'ambiguity appearing after preparation prevents any staging')
    backlog.write_text(base)
    action(h, 'stage')
    held = h / 'data/retired/.cleanup-hold/discard.bin'
    check(held.exists(), 'resolved sources permit staging')
    for changed in (row(pr=P5), row(project='obsolete')):
        backlog.write_text('# Backlog\n\n## Done\n' + changed)
        response = action(h, 'expire')
        check('changed project or PR' in response.stderr and held.exists(),
              'changed identity preserves the existing recovery at expiry')
    backlog.write_text(base + row(pr=P5))
    response = action(h, 'expire')
    check('retired' in response.stderr and held.exists(), 'late ambiguity preserves the existing recovery')
    backlog.write_text(base + '  [late capture](discard.bin)\n')
    action(h, 'expire')
    snapshot(h, 'after-late-reference-restore')
    check((h / 'data/retired/discard.bin').read_bytes() == b'unlinked scratch\x00\xff',
          'a newly linked held file is restored before deletion')

scenario('Late ambiguity or changed identity blocks cleanup; refreshed links restore recovery', late_conflicts)

def note_only_prs():
    for name, pr in (('gitlab', 'https://gitlab.example.invalid/group/repo/-/merge_requests/7'),
                     ('gerrit', 'https://review.example.invalid/c/group/repo/+/7')):
        h = new_home('note-only-' + name, current=row(notes='  Completed ' + pr + '\n'))
        action(h, 'prepare')
        check(record(h)['sources'][-1]['pr'] == pr, name + ': continuation note supplies the complete PR identity')
        response = action(h, 'stage', pr=pr)
        check(pr in response.stderr and 'unread PR' in response.stderr,
              name + ': unread remote is named without failing the pass')
        check((h / 'data/retired/discard.bin').exists() and not (h / 'data/retired/.cleanup-hold').exists(),
              name + ': note-only PR prevents pruning when the remote is unavailable')

scenario('Note-only GitLab and Gerrit identities are extracted and unread remotes retain data', note_only_prs)

def unread_retry():
    h = new_home('unread-pr-retry', current=row(pr=P4))
    (h / 'data/retired' / pr_only).write_bytes(b'actual PR evidence')
    action(h, 'prepare')
    response = action(h, 'stage', pr=P4, invalid=True)
    check(P4 in response.stderr and record(h)['sources'][-1]['unread'] == [P4],
          'failed real forge read names and records the unread PR without failing the pass')
    check(not (h / 'data/retired/.cleanup-hold').exists() and (h / 'data/retired/discard.bin').exists(),
          'unread PR keeps the whole folder in place')
    action(h, 'expire')
    check((h / 'data/retired/.cleanup-hold/discard.bin').exists(),
          'next readable cycle retries staging and grants a full recovery cycle')
    check(record(h)['sources'][-1]['unread'] == [], 'successful real reread clears unread state')
    action(h, 'expire')
    snapshot(h, 'after-expire')
    check((h / 'data/retired' / pr_only).read_bytes() == b'actual PR evidence',
          'PR-only evidence survives retry and expiry')

scenario('A real unread PR preserves the folder and a later readable cycle retries safely', unread_retry)

def recovery_cycle():
    h = new_home('recovery-cycle-retry' if recovery_only else 'recovery-cycle', current=row(notes='  [capture](current-pr-only.bin)\n'),
                 files={'current-pr-only.bin': b'keep', 'discard.bin': os.urandom(2 * 1024 * 1024)})
    task = h / 'data/retired'
    original_inode = (task / 'discard.bin').stat().st_ino
    run(['du', '-sk', task])
    run(['df', '-k', task])
    action(h, 'prepare')
    args = ['bash', LOCKED, ROOT, h / 'data', h / 'state', 'retired', 'cycle', h / 'projects/demo', '']
    run(args, environment(h))
    held = task / '.cleanup-hold/discard.bin'
    check(held.stat().st_ino == original_inode, 'staging renames the same inode; bytes are not reclaimed yet')
    log('staged_bytes=2097152 staged_GiB=0.001953125 (disposable fixture only)')
    run(['du', '-sk', task])
    run(args, environment(h))
    check(held.exists(), 'repeating the same task cleanup does not expire its own hold')
    (h / 'data/next-task').mkdir()
    with (h / 'data/backlog.md').open('a') as file:
        file.write(row(task='next-task'))
    run(['bash', LOCKED, ROOT, h / 'data', h / 'state', 'next-task', HELPER, 'prepare'], environment(h))
    run(['bash', LOCKED, ROOT, h / 'data', h / 'state', 'next-task', 'cycle', h / 'projects/demo', ''], environment(h))
    snapshot(h, 'after-next-different-task')
    check(not held.exists() and record(h)['expired'], 'next different completed task expires unlinked scratch through real dcg')
    run(['du', '-sk', task])
    run(['df', '-k', task])

scenario('One-cycle recovery preserves space while staged and expires only on another completed task', recovery_cycle)

result_path = EVIDENCE / 'live-task-data-results.json'
if recovery_only:
    previous = json.loads(result_path.read_text())
    retried = {item['name'] for item in results}
    results = [item for item in previous if item['name'] not in retried] + results
    log('Retry setup correction: source fm-pr-lib.sh, as the real retirement caller does; no product change.')
result_path.write_text(json.dumps(results, indent=2) + '\n')
log('\nLIVE RESULT: ' + json.dumps(results))
sys.exit(1 if any(item['result'] == 'fail' for item in results) else 0)
