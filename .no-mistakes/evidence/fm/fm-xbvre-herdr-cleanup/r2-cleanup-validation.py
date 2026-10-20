#!/usr/bin/env python3
"""Live cleanup revalidation; the transport forwards every call to the real lab.

The imported evidence helper only supplies guarded lifecycle, journaling,
transparent snapshot-call counting, and a file mutation after a real snapshot.
It never fabricates Herdr responses or substitutes for the cleanup product.
"""
import collections
import importlib.util
import json
import os
import secrets
import shutil
import time
from pathlib import Path

ROOT = Path.cwd()
E = Path('/Users/dalecarman/.no-mistakes/evidence/01M5BJC9DERBCXTG4TD2TYVSB4')
spec = importlib.util.spec_from_file_location('cleanup_lab', E / 'cleanup-live-lib.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.TMP = ROOT / '.test-cleanup-r2'
m.TRANSCRIPT = E / 'r2-cleanup-live.log'
m.ENV.update(TMPDIR=str(m.TMP), FM_HERDR_LAB_STATE_DIR=str(m.TMP / 'lab-records'), PYTHONDONTWRITEBYTECODE='1')
for key in ['FM_TASK_ID', 'FM_TEST_SEAM', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_WORKSPACE_ID', 'HERDR_TAB_ID']:
    m.ENV.pop(key, None)
old_cli = m.Lab.cli

def traced_cli(self, *args, check=True):
    p = old_cli(self, *args, check=False)
    with (E / 'r2-product-cli.jsonl').open('a') as f:
        f.write(json.dumps({'session': self.name, 'args': args, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}) + '\n')
    if check and p.returncode:
        raise RuntimeError(f'{args}: {p.stdout}{p.stderr}')
    return p
m.Lab.cli = traced_cli
results = []

def focus(s):
    return [s.get('focused_workspace_id'), s.get('focused_tab_id'), s.get('focused_pane_id')]

def result(name, **observed):
    record = {'name': name, 'result': 'pass', 'live': True, **observed}
    results.append(record)
    (E / 'r2-cleanup-results.json').write_text(json.dumps(results, indent=2) + '\n')
    m.log(json.dumps(record))

lab = m.Lab('r2-confirm-batch')
try:
    lab.provision()
    lab.anchor_create()
    v1 = lab.create('stale-v1')
    v2 = lab.create('stale-v2', version=2)
    unmatched = [lab.create(f'unmatched-{i}', journal=False) for i in range(53)]
    for i in range(68):
        lab.write_journal({'id': f'journal-only-{i}', 'token': secrets.token_urlsafe(16)})
    before = lab.snapshot('before')
    assert len(before['workspaces']) == 56
    assert len(list((lab.home / 'state').glob('*.herdr-presentation'))) == 70
    elapsed = lab.cleanup('batch')
    after = lab.snapshot('after')
    reads = collections.Counter(lab.counts.read_text().splitlines())
    assert sum(reads.values()) == 76, reads
    assert reads['stale-v1'] == reads['stale-v2'] == 4, reads
    assert all(reads[f'journal-only-{i}'] == 1 for i in range(68))
    assert not lab.present(v1) and not lab.present(v2)
    assert not lab.retained(v1) and not lab.retained(v2)
    assert all(lab.present(f) for f in unmatched)
    assert focus(before) == focus(after)
    metrics = {'initial_journals': 70, 'title_matching_workspaces': 55,
               'journal_snapshot_calls': sum(reads.values()), 'calls_by_task': dict(reads),
               'closed_exact_panes': [v1['pane'], v2['pane']], 'unmatched_panes_preserved': 53,
               'elapsed_seconds': elapsed, 'focus_before': focus(before), 'focus_after': focus(after),
               'comparison_context': 'Author baseline: 337 seconds with 70 journals and 55 workspaces; this disposable layout has two valid stale candidates.'}
    (E / 'r2-cleanup-batch-metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    result('70 journals and 55 candidate workspaces use one discovery pass and retain exact v1/v2 safety checks', **metrics)
    lab.cleanup('repeat')
    again = lab.snapshot('repeat-after')
    assert focus(after) == focus(again)
    assert all(lab.present(f) for f in unmatched)
    assert lab.cli('pane', 'get', lab.anchor['pane'], check=False).returncode == 0
    panes_after = sorted(p['pane_id'] for p in after['panes'])
    panes_again = sorted(p['pane_id'] for p in again['panes'])
    assert panes_after == panes_again
    assert len(panes_again) == 54
    result('Repeat cleanup leaves unmatched panes and the exact active workspace and tab unchanged', remaining_panes=panes_again, focus=focus(again))
finally:
    lab.teardown()

lab = m.Lab('r2-safety-guards')
try:
    lab.provision()
    lab.anchor_create()
    ambiguous = lab.create('ambiguous')
    lab.write_journal(ambiguous, id='fm-ambiguous')
    duplicate = lab.create('duplicate')
    token_copy = lab.create('token-copy', token=duplicate['token'], journal=False)
    meta = lab.create('current-task')
    (lab.home / 'state/current-task.meta').write_text('current-task-owned\n')
    other_home = lab.work / 'other-home'
    other_home.mkdir()
    foreign = lab.create('foreign-home', version=2, home=other_home)
    mismatch = lab.create('mismatched-binding', version=2, pane=lab.anchor['pane'])
    active = lab.create('active-target')
    malformed = lab.create('malformed-journal')
    lab.journal_path(malformed['id']).write_text('version=1\ntask_id=someone-else\nprojection_id=' + malformed['token'] + '\n')
    lab.cli('tab', 'focus', active['tab'])
    before = lab.snapshot('before')
    lab.cleanup('guards')
    after = lab.snapshot('after')
    cases = [ambiguous, duplicate, token_copy, meta, foreign, mismatch, active, malformed]
    assert all(lab.present(f) for f in cases)
    assert all(lab.retained(f) for f in cases if f != token_copy)
    assert focus(before) == focus(after)
    result('Cleanup preserves ambiguous journals, duplicate workspace tokens, current tasks, foreign or incorrect bindings, malformed journals, and the focused target', preserved_panes=[f['pane'] for f in cases], focus=focus(after))
finally:
    lab.teardown()

lab = m.Lab('r2-late-changes')
try:
    lab.provision()
    lab.anchor_create()
    baseline = lab.work / 'before-fix'
    shutil.copytree(ROOT / 'bin', baseline / 'bin')
    previous = baseline / 'bin/fm-herdr-session-cleanup.sh'
    previous.write_text(m.run(['git', 'show', 'd3bc4c32:bin/fm-herdr-session-cleanup.sh']).stdout)
    control = lab.create('before-fix-control')
    lab.cleanup('before-fix-control', source=previous)
    assert not lab.present(control) and not lab.retained(control)
    race_observations = []
    for tag, source in [('before-fix', previous), ('target', None)]:
        f = lab.create('late-' + tag)
        alias = 'fm-' + f['id']
        change = {'path': str(lab.journal_path(alias)), 'content': lab.content(f, id=alias)}
        lab.mutation.write_text(json.dumps([change]))
        before = lab.snapshot(tag + '-race-before')
        lab.cleanup(tag + '-race', source=source)
        after = lab.snapshot(tag + '-race-after')
        assert json.loads(lab.mutation.with_suffix('.applied').read_text()) == [change]
        observed = {'implementation': tag, 'pane': f['pane'], 'pane_retained': lab.present(f),
                    'original_journal_retained': lab.retained(f), 'duplicate_journal_retained': lab.journal_path(alias).exists(),
                    'focus_preserved': focus(before) == focus(after)}
        race_observations.append(observed)
    assert race_observations[0]['pane_retained'] is False
    assert race_observations[0]['original_journal_retained'] is False
    assert all(race_observations[1][key] for key in ['pane_retained', 'original_journal_retained', 'duplicate_journal_retained', 'focus_preserved'])
    result('Adding a second matching journal after the locked snapshot preserves the pane and both journals; the prior commit reproduces the failure', comparison=race_observations)
    changes_observed = []
    for kind in ['journal-change', 'metadata-appears', 'binding-change']:
        f = lab.create(kind, version=2 if kind == 'binding-change' else 1)
        if kind == 'journal-change':
            path, content = lab.journal_path(kind), lab.content(f, token=secrets.token_urlsafe(16))
        elif kind == 'binding-change':
            path, content = lab.journal_path(kind), lab.content(f, version=2, pane=lab.anchor['pane'])
        else:
            path, content = lab.home / 'state' / (kind + '.meta'), 'newly-owned-task\n'
        change = {'path': str(path), 'content': content}
        lab.mutation.write_text(json.dumps([change]))
        before = lab.snapshot(kind + '-before')
        lab.cleanup(kind)
        after = lab.snapshot(kind + '-after')
        assert json.loads(lab.mutation.with_suffix('.applied').read_text()) == [change]
        assert lab.present(f) and lab.retained(f)
        assert focus(before) == focus(after)
        output = (E / (lab.label + '-' + kind + '-output.log')).read_text()
        assert 'immediate revalidation changed or was unreadable' in output
        changes_observed.append({'change': kind, 'pane_retained': True, 'journal_retained': True, 'focus_preserved': True})
    result('Changing a journal token, v2 endpoint binding, or task metadata after the locked snapshot prevents closure', observations=changes_observed)
    f = lab.create('foreign-collision')
    other_home = lab.work / 'foreign-home'
    other_home.mkdir()
    lab.write_journal(f, version=2, home=other_home, id='fm-' + f['id'])
    before = lab.snapshot('foreign-collision-before')
    lab.cleanup('foreign-collision')
    after = lab.snapshot('foreign-collision-after')
    assert not lab.present(f) and not lab.retained(f)
    assert lab.journal_path('fm-' + f['id']).exists()
    assert focus(before) == focus(after)
    result('A title collision from a foreign-home journal does not block cleanup of the uniquely valid home-local orphan', valid_pane_closed=f['pane'], foreign_journal_retained=True, focus_preserved=True)
finally:
    lab.teardown()

m.log('All live cleanup scenarios passed; every owned named session was removed and each default-session tripwire passed.')
