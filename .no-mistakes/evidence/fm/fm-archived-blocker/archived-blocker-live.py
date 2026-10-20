#!/usr/bin/env python3
"""Drive the real task, fleet, summary and bearings CLIs in disposable local homes."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5CGASNXHDRR59BT65X36T6X')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5CGASNXHDRR59BT65X36T6X')
LAB = Path(tempfile.mkdtemp(prefix='.nm-archived-blocker-', dir=ROOT))
(EVIDENCE / 'disposable-root.txt').write_text(str(LAB) + '\n')
LOG = (EVIDENCE / 'archived-blocker-live.log').open('w', buffering=1)
RESULTS = []

def save(name, value):
    (EVIDENCE / name).write_text(json.dumps(value, indent=2) + '\n')


def make_home(name):
    home = LAB / name
    for child in ('data', 'state', 'config', 'projects'):
        (home / child).mkdir(parents=True)
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    return home


def environment(home, data=None):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('FM_') or key.startswith('TASKS_AXI_'):
            env.pop(key)
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(ROOT),
               FM_STATE_OVERRIDE=str(home / 'state'), FM_DATA_OVERRIDE=str(data or home / 'data'),
               FM_CONFIG_OVERRIDE=str(home / 'config'), FM_PROJECTS_OVERRIDE=str(home / 'projects'))
    return env


def run(label, command, home, data=None, json_output=False):
    LOG.write('\n$ ' + shlex.join(map(str, command)) + '\n')
    LOG.write('FM_HOME=' + str(home) + '\n')
    result = subprocess.run(list(map(str, command)), cwd=ROOT, env=environment(home, data),
                            text=True, capture_output=True, timeout=100)
    LOG.write(result.stdout)
    LOG.write(result.stderr)
    LOG.write('exit=' + str(result.returncode) + '\n')
    if result.returncode:
        raise RuntimeError(f'{label}: exit {result.returncode}: {result.stderr}')
    if json_output:
        document = json.loads(result.stdout)
        save(label + '.json', document)
        return document
    return result.stdout


def task(home, *arguments):
    return run('tasks ' + ' '.join(arguments), [ROOT / 'bin/fm-tasks-axi.sh', *arguments], home)


def snapshot(label, home, script=None, data=None):
    return run(label, ['bash', script or ROOT / 'bin/fm-fleet-snapshot.sh', '--json'],
               home, data=data, json_output=True)


def record(document, task_id):
    return next(row for row in document['backlog']['records'] if row.get('id') == task_id)


def check(name, condition, detail):
    LOG.write(('PASS ' if condition else 'FAIL ') + name + ': ' + detail + '\n')
    if not condition:
        raise AssertionError(name + ': ' + detail)


def scenario(name, action):
    try:
        action()
        RESULTS.append({'name': name, 'result': 'pass', 'live': True})
    except Exception as error:
        LOG.write('FAIL ' + name + ': ' + str(error) + '\n')
        RESULTS.append({'name': name, 'result': 'fail', 'live': True, 'reason': str(error)})
    save('live-results.json', RESULTS)

main = make_home('lifecycle')


def lifecycle():
    for task_id, title in [('ac-bkbhy', 'Shipped blocker'), ('ac-c4zpc', 'Dependent implementation'),
                            ('review-ac-vpw4n', 'Dependent review'), ('captain-approval', 'Approval after shipment')]:
        args = ['add', task_id, title, '--kind', 'ship', '--repo', 'disposable-project']
        if task_id != 'ac-bkbhy':
            args += ['--blocked-by', 'ac-bkbhy']
        task(main, *args)
    task(main, 'hold', 'captain-approval', '--reason', 'Approve the completed shipment', '--kind', 'captain')
    initial = snapshot('lifecycle-queued', main)
    check('queued blocker remains unresolved', all(record(initial, task_id)['unresolved_blocker_ids'] == ['ac-bkbhy']
          for task_id in ('ac-c4zpc', 'review-ac-vpw4n', 'captain-approval')), 'all three dependents blocked')
    run('bearings-before', ['bash', ROOT / 'bin/fm-bearings-snapshot.sh', '--json'], main, json_output=True)
    task(main, 'done', 'ac-bkbhy', '--no-prune')
    retained = snapshot('lifecycle-retained-done', main)
    check('retained Done blocker resolves', all(record(retained, task_id)['unresolved_blocker_ids'] == []
          for task_id in ('ac-c4zpc', 'review-ac-vpw4n', 'captain-approval')), 'Done in backlog resolves')
    task(main, 'done', 'ac-bkbhy', '--keep', '0')
    archived = snapshot('lifecycle-archived', main)
    check('archive actually replaced the backlog row', all(row.get('id') != 'ac-bkbhy' for row in archived['backlog']['records'])
          and (main / 'data/done-archive.md').is_file(), 'blocker absent from backlog; archive exists')
    for name in ('backlog.md', 'done-archive.md'):
        (EVIDENCE / ('lifecycle-' + name)).write_bytes((main / 'data' / name).read_bytes())
    check('archived blocker resolves for both reported dependents', all(record(archived, task_id)['unresolved_blocker_ids'] == []
          for task_id in ('ac-c4zpc', 'review-ac-vpw4n')), 'implementation and review are no longer blocked')
    before_bin = LAB / 'before-bin'
    before_bin.mkdir()
    for entry in (ROOT / 'bin').iterdir():
        if entry.name != 'fm-fleet-snapshot.sh':
            (before_bin / entry.name).symlink_to(entry)
    before_script = before_bin / 'fm-fleet-snapshot.sh'
    baseline = subprocess.check_output(['git', 'show', '929f2631:bin/fm-fleet-snapshot.sh'], cwd=ROOT)
    before_script.write_bytes(baseline)
    before = snapshot('historical-before-fix', main, before_script)
    check('before/after reproduction', record(before, 'ac-c4zpc')['unresolved_blocker_ids'] == ['ac-bkbhy']
          and record(archived, 'ac-c4zpc')['unresolved_blocker_ids'] == [], 'same archived records fail before the fix and resolve after it')


def downstream():
    run('publish-home-summary', ['bash', ROOT / 'bin/fm-home-summary-refresh.sh'], main)
    ledger = json.loads((main / 'state/home-summary.json').read_text())
    save('published-home-summary.json', ledger)
    check('published summary is valid', ledger['valid'] is True, 'real atomic home-summary writer published a valid ledger')
    for task_id in ('ac-c4zpc', 'review-ac-vpw4n', 'captain-approval'):
        row = next(row for row in ledger['queued'] if row['id'] == task_id)
        check('published summary resolves ' + task_id, row['unresolved_blocker_ids'] == [], 'no archived blocker remains unresolved')
    check('captain approval becomes actionable', any(row['id'] == 'captain-approval' for row in ledger['decisions_open']),
          'approval appears among open captain calls')
    bearings = run('bearings-after', ['bash', ROOT / 'bin/fm-bearings-snapshot.sh', '--json'], main, json_output=True)
    check('bearings approval classification', any(row['id'] == 'captain-approval' for row in bearings['decisions_open'])
          and not any(row['id'] == 'captain-approval' for row in bearings['gates']), 'approval moves from Charted Next to Captain\'s Call')
    check('bearings no longer names the archived blocker', all(row.get('blocked_by') != 'ac-bkbhy' for row in bearings['gates']),
          'queued dependencies no longer display the archived blocker')
    toon = run('bearings-after-human', ['bash', ROOT / 'bin/fm-bearings-snapshot.sh'], main)
    (EVIDENCE / 'bearings-after.txt').write_text(toon)


def mixed_dependencies():
    home = make_home('mixed-dependencies')
    task(home, 'add', 'archived', 'Archived dependency', '--kind', 'ship')
    task(home, 'add', 'queued', 'Queued dependency', '--kind', 'ship')
    task(home, 'add', 'flight', 'In flight dependency', '--kind', 'ship')
    task(home, 'start', 'flight')
    task(home, 'add', 'gated', 'Work with mixed dependencies', '--kind', 'ship', '--blocked-by', 'archived',
         '--blocked-by', 'queued', '--blocked-by', 'flight')
    task(home, 'done', 'archived', '--keep', '0')
    path = home / 'data/backlog.md'
    text = path.read_text()
    # Add deliberately dangling and repeated edges as serialized task-input fixtures.
    text = text.replace('gated - Work with mixed dependencies', 'gated - Work with mixed dependencies blocked-by: missing blocked-by: archived')
    path.write_text(text)
    output = snapshot('mixed-dependencies', home)
    row = record(output, 'gated')
    check('mixed blockers do not falsely unblock', row['unresolved_blocker_ids'] == ['missing', 'queued', 'flight'],
          'missing, queued and in-flight blockers stay open; both archived references resolve')
    (EVIDENCE / 'mixed-dependencies-backlog.md').write_bytes(path.read_bytes())
    # Adversarial stale archive: a current Queued row must override its old archive entry.
    with path.open('a') as stream:
        stream.write('\n')
    text = path.read_text().replace('## Queued\n', '## Queued\n- [ ] archived - Reopened work (kind: ship)\n')
    path.write_text(text)
    reopened = snapshot('reopened-with-stale-archive', home)
    check('reopened task overrides stale archive', record(reopened, 'gated')['unresolved_blocker_ids'] == ['missing', 'archived', 'queued', 'flight'],
          'current Queued state wins; repeated edges retain existing first-seen normalization')


def archive_boundary():
    home = make_home('archive-boundary')
    path = home / 'data/backlog.md'
    path.write_text('## In flight\n\n## Queued\n- [ ] gated - Strict archive identity blocked-by: exact blocked-by: missing (kind: ship)\n\n## Done\n')
    absent = snapshot('archive-absent', home)
    check('absent archive preserves unknown blockers', record(absent, 'gated')['unresolved_blocker_ids'] == ['exact', 'missing'],
          'snapshot works with no archive')
    (home / 'data/done-archive.md').write_text('# Done archive\n- [x] exact-extra - Similar id is not exact\n  Discussion mentions missing and exact\n')
    unrelated = snapshot('archive-near-match', home)
    check('prose and prefix matches do not resolve', record(unrelated, 'gated')['unresolved_blocker_ids'] == ['exact', 'missing'],
          'only canonical exact task ids resolve')
    data = home / 'alternative-data'
    data.mkdir()
    (data / 'backlog.md').write_bytes(path.read_bytes())
    (data / 'done-archive.md').write_text('# Done archive\n- [x] exact - Resolved beside the selected backlog\n')
    selected = snapshot('archive-data-override', home, data=data)
    check('archive follows selected data directory', record(selected, 'gated')['unresolved_blocker_ids'] == ['missing'],
          'FM_DATA_OVERRIDE uses its adjacent archive, not the default home archive')
    unchanged = snapshot('archive-home-isolation', home)
    check('another data directory cannot resolve blockers', record(unchanged, 'gated')['unresolved_blocker_ids'] == ['exact', 'missing'],
          'returning to default data leaves its blockers open')

scenario('Archive a completed blocker and unblock both dependent tasks, with before-fix reproduction', lifecycle)
scenario('Refresh the published home summary and bearings so archived blockers disappear and the captain call becomes actionable', downstream)
scenario('Mix archived, queued, in-flight, missing and reopened blockers without falsely unblocking work', mixed_dependencies)
scenario('Use exact archived task ids from the selected backlog directory; absent archives and unrelated data stay safe', archive_boundary)
LOG.close()
print(json.dumps({'disposable_root': str(LAB), 'scenarios': RESULTS}, indent=2))
raise SystemExit(any(row['result'] != 'pass' for row in RESULTS))
