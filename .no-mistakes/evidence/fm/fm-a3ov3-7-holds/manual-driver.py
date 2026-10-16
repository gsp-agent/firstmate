from pathlib import Path
import json
import os
import shutil
import subprocess

root = Path.cwd()
work = root / '.validation-holds'
home = work / 'manual-home'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5247FNFP2RVKSFHYFCSP2RR')
for name in ('data', 'state', 'config', 'projects', 'fakebin'):
    (home / name).mkdir(parents=True, exist_ok=True)
(home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
(home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(home / 'state/capacity.meta').write_text('decision_owner=ep-groove-sight-platform\n')
(home / 'fakebin/herdr').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:3] == ['agent', 'list']:
    print(json.dumps({'result': {'agents': [{'name': 'pm-dale-desk', 'pane_id': 'human-desk-pane'}]}}))
    raise SystemExit(0)
assert sys.argv[1:3] == ['agent', 'prompt'], sys.argv
with Path(os.environ['HOLD_DOMAIN_TEST_LOG']).open('a') as stream:
    stream.write(json.dumps({'owner': sys.argv[3], 'message': sys.argv[4]}) + '\\n')
print('prompt accepted by isolated transport sink')
''')
(home / 'fakebin/herdr').chmod(0o700)
(home / 'fakebin/tmux').write_text('#!/bin/sh\nexit 0\n')
(home / 'fakebin/tmux').chmod(0o700)
env = dict(os.environ)
for key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'FM_TASK_ID', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
    env.pop(key, None)
env.update({
    'FM_HOME': str(home), 'FM_ROOT_OVERRIDE': str(root),
    'FM_STATE_OVERRIDE': str(home / 'state'), 'FM_DATA_OVERRIDE': str(home / 'data'),
    'FM_CONFIG_OVERRIDE': str(home / 'config'), 'FM_PROJECTS_OVERRIDE': str(home / 'projects'),
    'FM_BACKEND': 'tmux', 'FM_HOLD_DOMAIN_ROUTER': '/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py',
    'HOLD_DOMAIN_HERDR': str(home / 'fakebin/herdr'), 'HOLD_DOMAIN_TEST_LOG': str(home / 'owner.jsonl'),
    'PATH': str(home / 'fakebin') + os.pathsep + env['PATH'],
    'TMPDIR': str(work / 'tmp'), 'PYTHONDONTWRITEBYTECODE': '1',
    'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
})
transcript = (evidence / 'hold-routing-cli.txt').open('w')
transcript.write('Real Firstmate CLI and installed hold-domain router; disposable markdown backlog; isolated prompt sink.\n')

def execute(command, now='2026-10-14T02:00:00Z', expect=0):
    local_env = {**env, 'FM_CAPTAIN_HOLD_NOW': now}
    result = subprocess.run(command, cwd=home, env=local_env, capture_output=True, text=True, timeout=90)
    display = [str(x).replace(str(root) + '/', '') for x in command]
    transcript.write('\n$ ' + ' '.join(display) + f' [clock={now}]\n')
    transcript.write(result.stdout + result.stderr + f'exit={result.returncode}\n')
    transcript.flush()
    assert result.returncode == expect, (display, result.returncode, result.stdout, result.stderr)
    return result.stdout

def captain(*args, now='2026-10-14T02:00:00Z', expect=0):
    return execute([str(root / 'bin/fm-captain-hold.sh'), *args], now, expect)

def show(task):
    value = execute([str(root / 'bin/fm-tasks-axi.sh'), 'show', task, '--full'])
    fields = {}
    for line in value.splitlines():
        if line.startswith('  ') and ': ' in line:
            key, item = line.strip().split(': ', 1)
            fields[key] = item
    fields['body'] = json.loads(fields.get('body', '""'))
    return fields

def deliveries():
    path = home / 'owner.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

def snapshot(label):
    target = evidence / label
    target.mkdir(exist_ok=True)
    for name in ('data/backlog.md', 'state/hold-domain/routed.tsv', 'state/hold-domain/sweep-cursor', 'owner.jsonl'):
        path = home / name
        if path.exists():
            dest = target / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)

technical = 'GSP PRs 4281, 4291, 4309, and 4319 are waiting on a go for update-branch.'
capacity = 'ep-groove-sight-platform already approved raising GSP capacity from 3 places to 5. Should I apply that?'
captain('hold', 'branch', '--title', 'Update branch', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60', '--reason', technical)
captain('hold', 'capacity', '--title', 'Approved capacity', '--timeout-seconds', '60', '--reason', capacity)
captain('route-due', now='2026-10-14T02:00:59Z')
assert deliveries() == []
for task in ('branch', 'capacity'):
    assert show(task)['held'] == 'yes'
snapshot('before-deadline')
captain('route-due', now='2026-10-14T02:01:00Z')
for task in ('branch', 'capacity'):
    value = show(task)
    assert value['held'] == 'no' and value['state'] == 'queued'
    assert 'Resolution mode: agent-routed' in value['body']
    assert 'Agent routing evidence:' in value['body'] and 'Captain decision:' not in value['body']
assert sorted(row['owner'] for row in deliveries()) == ['ep-firstmate', 'ep-groove-sight-platform']
captain('route-due', now='2026-10-14T02:02:00Z')
assert len(deliveries()) == 2
snapshot('technical-holds-released')
print('Two technical holds released to their declared owners exactly once; pre-deadline sweep kept both held.', flush=True)

reserved = {
    'money': 'Should I spend money to buy more seats?',
    'credentials': 'Could you provide the OAuth token?',
    'people': 'Should I assign Ashton to the reviewer seat?',
    'client-words': 'May I email the client that the rebase is complete?',
    'production': 'Should I deploy this to production?',
    'accounts': 'May I create a new account?',
    'taste': 'Should the capacity indicator be blue or orange?',
    'mixed-production': technical + ' May I deploy to production too?',
}
for task, reason in reserved.items():
    captain('hold', task, '--title', 'Reserved ' + task, '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60', '--reason', reason)
for owner in ('captain', 'pm-dale-desk', 'human-desk-pane'):
    captain('hold', owner, '--title', 'Human endpoint ' + owner, '--decision-owner', owner, '--timeout-seconds', '60', '--reason', technical)
captain('route-due', now='2026-10-14T02:10:00Z')
for task in (*reserved, 'captain', 'pm-dale-desk', 'human-desk-pane'):
    value = show(task)
    assert value['held'] == 'yes' and 'Resolution mode:' not in value['body']
assert len(deliveries()) == 2
snapshot('reserved-asks-remain-held')
print('Seven reserved ask categories, mixed production ask, and three human endpoints remained held with no extra delivery.', flush=True)

captain('hold', 'answered', '--title', 'Already answered', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60', '--reason', technical)
(home / 'decision.txt').write_text('Proceed with the approved branch update.\n')
captain('answer', 'answered', '--decision-file', str(home / 'decision.txt'), '--release')
captain('route-due', now='2026-10-14T02:10:00Z')
value = show('answered')
assert value['held'] == 'no' and 'Proceed with the approved branch update.' in value['body']
assert 'Resolution mode: agent-routed' not in value['body'] and len(deliveries()) == 2

captain('hold', 'drifted', '--title', 'Live reason changed', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60', '--reason', technical)
execute([str(root / 'bin/fm-tasks-axi.sh'), 'hold', 'drifted', '--kind', 'captain', '--reason', 'Should I deploy this to production?'])
captain('route-due', 'drifted', now='2026-10-14T02:10:00Z', expect=1)
value = show('drifted')
assert value['held'] == 'yes' and len(deliveries()) == 2
captain('hold', 'drifted', '--reason', 'Should I deploy this to production?', now='2026-10-14T02:10:00Z')
captain('route-due', now='2026-10-14T02:11:00Z')
assert not list((home / 'state/hold-domain/pending').glob('*.body'))
snapshot('answer-and-drift-safeguards')
print('A recorded answer was preserved; changing a technical reason to production blocked routing and retained the hold.', flush=True)

captain('hold', 'retry', '--title', 'Recover interrupted release', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60', '--reason', technical)
real_tasks = shutil.which('tasks-axi')
assert real_tasks
shim = home / 'fakebin/tasks-axi'
assert not shim.exists()
shim.write_text('#!/usr/bin/env python3\nimport os, sys\n'
    "if sys.argv[1:3] == ['unhold', 'retry']:\n    print('injected release failure', file=sys.stderr)\n    raise SystemExit(1)\n"
    + 'os.execv(' + repr(real_tasks) + ', [' + repr(real_tasks) + '] + sys.argv[1:])\n')
shim.chmod(0o700)
captain('route-due', 'retry', now='2026-10-14T02:01:00Z', expect=1)
value = show('retry')
assert value['held'] == 'yes' and 'Resolution mode: agent-routed' in value['body']
assert len(deliveries()) == 3
snapshot('release-interrupted')
shim.rename(home / 'fakebin/tasks-axi.disabled')
captain('route-due', now='2026-10-14T02:02:00Z')
captain('route-due', now='2026-10-14T02:03:00Z')
value = show('retry')
assert value['held'] == 'no' and len(deliveries()) == 3
assert value['body'].count('Resolution mode: agent-routed') == 1
assert not list((home / 'state/hold-domain/pending').glob('*.body'))
snapshot('release-recovered-once')
print('A failed release retained its receipt and pending work; repeated sweeps released it once without another prompt.', flush=True)
transcript.close()
