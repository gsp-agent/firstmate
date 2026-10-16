#!/usr/bin/env python3
"""Disposable public-command replay; transport is a local protocol sink.

No live agent receives a prompt. The actual hold CLI, watcher, tasks-axi and
installed hold-domain router run without replacement. Fault scenarios replace
only the failing tasks-axi operation and delegate all others to the real tool.
"""
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M51TNXPWD65TJT4SFREF5TCF')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M51TNXPWD65TJT4SFREF5TCF')
SCRATCH = ROOT / '.nm-hold-test'
ROUTER = '/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py'
TASKS = shutil.which('tasks-axi')
BASH = shutil.which('bash')
BRANCH = 'GSP PRs 4281, 4291, 4309, and 4319 are waiting on a go for update-branch.'
CAPACITY = 'ep-groove-sight-platform already approved raising GSP capacity from 3 places to 5. Should I apply that?'
T0 = '2026-10-16T09:00:00Z'
T59 = '2026-10-16T09:00:59Z'
T60 = '2026-10-16T09:01:00Z'
T120 = '2026-10-16T09:02:00Z'
BASE_ENV = dict(os.environ)
for key in list(BASE_ENV):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HOLD_DOMAIN_', 'GIT_CONFIG_')) or key in ('TMUX', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
        BASE_ENV.pop(key, None)
BASE_ENV.update(TMPDIR=str(SCRATCH / 'toolchain-temp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', PYTHONDONTWRITEBYTECODE='1')
LOG = (EVIDENCE / 'product-replay.txt').open('w', buffering=1)
RESULTS = []

def note(text):
    print(text, file=LOG, flush=True)

def call(argv, env=None, expected=0, stdin=None, timeout=90, cwd=ROOT):
    note('$ ' + shlex.join(map(str, argv)))
    result = subprocess.run(list(map(str, argv)), cwd=cwd, env=env or BASE_ENV,
                            input=stdin, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    note(result.stdout.rstrip())
    note('[exit %d]' % result.returncode)
    if expected is not None:
        assert result.returncode == expected, result.stdout
    return result

def scenario(name, fn):
    note('\n=== ' + name + ' ===')
    try:
        fn()
    except Exception as exc:
        RESULTS.append({'name': name, 'result': 'fail', 'error': str(exc)})
        note('OBSERVED FAILURE: ' + repr(exc))
        raise
    else:
        RESULTS.append({'name': name, 'result': 'pass'})

class Lab:
    def __init__(self, name, code=ROOT):
        self.home = SCRATCH / name
        self.code = code
        call([BASH, ROOT / 'bin/fm-lab-home.sh', 'create', self.home])
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        (self.home / 'tmux').mkdir()
        (self.home / 'transport').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ['FM_HOME'])
if sys.argv[1:3] == ['agent', 'list']:
    print(json.dumps({'result': {'agents': [{'name': 'pm-dale-desk', 'pane_id': 'human-desk-pane'}]}}))
    raise SystemExit(0)
if sys.argv[1:3] != ['agent', 'prompt']:
    raise SystemExit(90)
if (home / 'fail-delivery').exists():
    print('isolated transport unavailable')
    raise SystemExit(91)
with (home / 'owner-prompts.jsonl').open('a') as output:
    output.write(json.dumps({'owner': sys.argv[3], 'message': sys.argv[4]}) + '\\n')
print('isolated transport accepted prompt')
''')
        (self.home / 'transport').chmod(0o700)
        self.env = dict(BASE_ENV, FM_HOME=str(self.home), FM_HOLD_DOMAIN_ROUTER=ROUTER,
                        HOLD_DOMAIN_HERDR=str(self.home / 'transport'), TMUX_TMPDIR=str(self.home / 'tmux'),
                        FM_BACKEND='tmux', FM_CHECK_INTERVAL='0', FM_POLL='1', FM_SIGNAL_GRACE='1',
                        FM_HOME_SUMMARY_INTERVAL='999999', FM_SECONDMATE_LIVENESS_SECS='999999')
    def run(self, script, *args, now=T0, expected=0, stdin=None):
        note('context: isolated home=' + self.home.name + ', clock=' + now)
        return call([BASH, self.code / 'bin' / script, *args],
                    dict(self.env, FM_CAPTAIN_HOLD_NOW=now), expected, stdin)
    def hold(self, id, reason=BRANCH, owner='ep-firstmate', now=T0, *extra):
        return self.run('fm-captain-hold.sh', 'hold', id, '--title', id,
                        '--decision-owner', owner, '--timeout-seconds', '60', '--reason', reason, *extra, now=now)
    def show(self, id):
        output = self.run('fm-tasks-axi.sh', 'show', id, '--full').stdout
        fields = {}
        for line in output.splitlines():
            if line.startswith('  ') and ': ' in line:
                key, value = line.strip().split(': ', 1)
                fields[key] = json.loads(value) if key == 'body' else value
        return fields
    def prompts(self):
        path = self.home / 'owner-prompts.jsonl'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
    def needed(self):
        result = call([BASH, SCRATCH / 'supervision.sh', self.home / 'state'], self.env).stdout
        return 'needed=true' in result
    def watch(self, now=T60):
        (self.home / 'state/sentinel.status').write_text('done: disposable replay complete\n')
        return self.run('fm-watch.sh', now=now).stdout
    def fault(self, operation):
        folder = self.home / 'fault-bin'
        folder.mkdir(exist_ok=True)
        tool = folder / 'tasks-axi'
        tool.write_text('#!/usr/bin/env python3\nimport os, pathlib, sys\nhome=pathlib.Path(os.environ["FM_HOME"])\nif (home / "fail-operation").exists() and sys.argv[1] == (home / "fail-operation").read_text().strip():\n    print("injected storage operation failure", file=sys.stderr)\n    raise SystemExit(91)\nos.execv(' + repr(TASKS) + ', [' + repr(TASKS) + '] + sys.argv[1:])\n')
        tool.chmod(0o700)
        (self.home / 'fail-operation').write_text(operation)
        self.env['PATH'] = str(folder) + os.pathsep + BASE_ENV['PATH']
    def recover(self):
        (self.home / 'fail-operation').rename(self.home / 'recovered-operation')

(SCRATCH / 'supervision.sh').write_text('#!/usr/bin/env bash\nset -eu\n. ' + shlex.quote(str(ROOT / 'bin/fm-supervision-lib.sh')) + '\nfm_supervision_status "$1"\nprintf "needed=%s pending=%s inflight=%s checks=%s sources=%s\\n" "$FM_SUP_NEEDED" "$FM_SUP_HOLDS" "$FM_SUP_IN_FLIGHT" "$FM_SUP_CHECKS" "$FM_SUP_SOURCES"\n')
note('Actual Firstmate public CLI + real tasks-axi + installed hold-domain router.\nAll homes, backlog files, receipts, clocks and failure injection are disposable.\nThe Herdr transport is an explicit local protocol sink; no real agent, branch, worker seat, production state or credential is changed.\nThis transcript proves local routing and release, not owner execution of branch/capacity work.\n')

def baseline():
    directory = SCRATCH / 'baseline-code'
    directory.mkdir()
    archive = subprocess.run(['git', 'archive', 'origin/upstream-lean', 'bin'], cwd=ROOT,
                             env=BASE_ENV, check=True, stdout=subprocess.PIPE).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as files:
        files.extractall(directory, filter='data')
    lab = Lab('baseline', directory)
    for id, reason in [('branch', BRANCH), ('capacity', CAPACITY)]:
        lab.run('fm-captain-hold.sh', 'hold', id, '--title', id, '--reason', reason)
    output = lab.watch()
    assert 'signal:' in output
    assert all(lab.show(id)['held'] == 'yes' for id in ('branch', 'capacity'))
    assert lab.prompts() == []
    note('BASELINE: 0/2 owner prompt dispatches; both tasks still held.')

def technical():
    lab = Lab('technical')
    lab.hold('branch')
    (lab.home / 'state/owner-source.meta').write_text('decision_owner=ep-groove-sight-platform\n')
    lab.run('fm-captain-hold.sh', 'hold', 'capacity', '--title', 'capacity', '--origin', 'owner-source',
            '--timeout-seconds', '60', '--reason', CAPACITY)
    (lab.home / 'state/owner-source.meta').rename(lab.home / 'retired-source-meta')
    assert lab.needed()
    lab.run('fm-captain-hold.sh', 'route-due', now=T59)
    assert lab.prompts() == []
    assert 'signal:' in lab.watch()
    for id in ('branch', 'capacity'):
        record = lab.show(id)
        assert record['held'] == 'no' and record['state'] == 'queued'
        assert 'Resolution mode: agent-routed' in record['body']
        assert 'Agent routing evidence:' in record['body'] and 'Captain decision:' not in record['body']
    lab.run('fm-captain-hold.sh', 'route-due', now=T120)
    assert [p['owner'] for p in lab.prompts()] == ['ep-firstmate', 'ep-groove-sight-platform']
    note('DELIVERED TO ISOLATED TRANSPORT: ' + json.dumps(lab.prompts()))
    note('PERSISTED ROUTING RECEIPTS:\n' + (lab.home / 'state/hold-domain/routed.tsv').read_text())
    assert not lab.needed()
    note('TARGET: 2/2 owner prompt dispatches, one per lifecycle; work released, not completed.')

def reserved():
    lab = Lab('reserved')
    asks = ['Should I spend money to buy more seats?', 'Could you provide the OAuth token?',
            'Should I assign Ashton to the reviewer seat?', 'May I email the client that the rebase is complete?',
            'Should I deploy this to production?', 'May I create a new account?',
            'Should the capacity indicator be blue or orange?', BRANCH + ' May I deploy to production too?']
    ids = []
    for i, reason in enumerate(asks):
        id = 'reserved-' + str(i)
        ids.append(id)
        lab.hold(id, reason)
    for owner in ('captain', 'pm-dale-desk', 'human-desk-pane'):
        ids.append(owner)
        lab.hold(owner, owner=owner)
    lab.run('fm-captain-hold.sh', 'route-due', now=T120)
    for id in ids:
        record = lab.show(id)
        assert record['held'] == 'yes' and 'Resolution mode:' not in record['body']
    assert lab.prompts() == [] and not lab.needed()
    note('Protected asks and human endpoints: 11/11 remain held; no owner dispatch.')

def interruptions():
    for mode in ('answered', 'released', 'reconciled'):
        lab = Lab('interrupted-' + mode)
        lab.hold('interrupted')
        decision = lab.home / 'decision.txt'
        decision.write_text('Keep this work paused until the recorded issue is resolved.\nFinish the recorded closure before handing responsibility to another owner.\n')
        lab.fault('unhold' if mode == 'released' else 'done')
        if mode == 'reconciled':
            lab.run('fm-captain-hold.sh', 'bind', 'disposable-board')
            lab.run('fm-captain-hold.sh', 'reconcile-requests', '--source-id', 'disposable-board', '--source', 'disposable captured board result', stdin='interrupted\n')
            args = ('reconcile', 'close', 'interrupted', '--evidence-file', decision)
        else:
            args = ('answer', 'interrupted', '--decision-file', decision) + (('--release',) if mode == 'released' else ())
        assert lab.run('fm-captain-hold.sh', *args, expected=None).returncode != 0
        before = lab.show('interrupted')
        assert before['held'] == 'yes' and ('Resolution mode: ' + mode) in before['body']
        lab.run('fm-captain-hold.sh', 'route-due', 'interrupted', now=T60)
        lab.run('fm-captain-hold.sh', 'route-due', now=T120)
        refused = lab.run('fm-captain-hold.sh', 'hold', 'interrupted', '--reason', BRANCH, now=T120, expected=None)
        assert refused.returncode != 0 and 'recorded resolution awaiting closure' in refused.stdout
        assert lab.show('interrupted') == before and lab.prompts() == [] and not lab.needed()
        lab.recover()
        lab.run('fm-captain-hold.sh', *args)
        assert decision.read_text().rstrip() in lab.show('interrupted')['body']

def history():
    lab = Lab('historical')
    lab.hold('history')
    decision = lab.home / 'decision.txt'
    words = 'Release this work.\nDecision owner: historical-owner\nHold timeout seconds: 98765\nHold reason: Preserve this line exactly.\nCaptain hold origin: historical-origin\nCaptain hold set: 2000-01-01T00:00:00Z\n'
    decision.write_text(words)
    lab.run('fm-captain-hold.sh', 'answer', 'history', '--release', '--decision-file', decision)
    original = lab.show('history')['body']
    lab.hold('history', CAPACITY, 'ep-groove-sight-platform', now='2026-10-16T10:00:00Z')
    lab.run('fm-captain-hold.sh', 'hold', 'history', '--reason', CAPACITY, now='2026-10-16T10:00:59Z')
    lab.run('fm-captain-hold.sh', 'route-due', now='2026-10-16T10:01:00Z')
    lab.run('fm-captain-hold.sh', 'route-due', now='2026-10-16T10:02:00Z')
    record = lab.show('history')
    assert original in record['body'] and words.rstrip() in record['body']
    assert record['held'] == 'no' and record['state'] == 'queued'
    assert len(lab.prompts()) == 1 and lab.prompts()[0]['owner'] == 'ep-groove-sight-platform'

def archival():
    lab = Lab('archival')
    config = lab.home / '.tasks.toml'
    config.write_text(config.read_text().replace('done_keep = 10', 'done_keep = 0'))
    lab.hold('archived')
    pending = lab.home / 'state/hold-domain/pending/archived.body'
    original = pending.read_bytes()
    backlog = lab.home / 'data/backlog.md'
    backlog.rename(lab.home / 'saved-backlog.md')
    backlog.mkdir()
    for args in (('route-due', 'archived'), ('route-due',)):
        assert lab.run('fm-captain-hold.sh', *args, now=T60, expected=None).returncode != 0
        assert pending.read_bytes() == original and lab.needed()
    backlog.rename(lab.home / 'unreadable-backlog')
    (lab.home / 'saved-backlog.md').rename(backlog)
    lab.run('fm-tasks-axi.sh', 'done', 'archived')
    assert 'archived' in (lab.home / 'data/done-archive.md').read_text()
    absent = lab.run('fm-tasks-axi.sh', 'show', 'archived', '--full', expected=None)
    assert absent.returncode != 0 and 'code: NOT_FOUND' in absent.stdout
    lab.run('fm-captain-hold.sh', 'route-due', now=T120)
    lab.run('fm-captain-hold.sh', 'route-due', 'archived', now=T120)
    assert not pending.exists() and not lab.needed() and lab.prompts() == []

def retry():
    lab = Lab('retry')
    lab.hold('retry')
    (lab.home / 'fail-delivery').touch()
    assert lab.run('fm-captain-hold.sh', 'route-due', now=T60, expected=None).returncode != 0
    assert lab.show('retry')['held'] == 'yes' and lab.needed()
    (lab.home / 'fail-delivery').rename(lab.home / 'delivery-recovered')
    lab.fault('unhold')
    assert lab.run('fm-captain-hold.sh', 'route-due', now=T120, expected=None).returncode != 0
    record = lab.show('retry')
    assert record['held'] == 'yes' and 'Agent routing evidence:' in record['body'] and lab.needed()
    lab.recover()
    lab.run('fm-captain-hold.sh', 'route-due', now=T120)
    record = lab.show('retry')
    assert record['held'] == 'no' and record['state'] == 'queued'
    assert len(lab.prompts()) == 1 and record['body'].count('Resolution mode: agent-routed') == 1
    assert not lab.needed()

def guards():
    lab = Lab('guards')
    lab.hold('drift')
    lab.run('fm-tasks-axi.sh', 'hold', 'drift', '--kind', 'captain', '--reason', 'Should I deploy this to production?')
    failure = lab.run('fm-captain-hold.sh', 'route-due', 'drift', now=T120, expected=None)
    assert failure.returncode != 0 and 'divergent hold and routing reasons' in failure.stdout
    assert lab.show('drift')['held'] == 'yes' and lab.needed()
    check = lab.home / 'state/ordinary.check.sh'
    check.write_text('#!/usr/bin/env bash\nprintf "scheduled check ran\\n" >> "$FM_HOME/scheduled.log"\n')
    check.chmod(0o700)
    lab.run('fm-check-register.sh', 'ordinary')
    output = lab.watch()
    assert 'check: hold-domain routing failed:' in output
    note('INDEPENDENT CHECK OUTPUT:\n' + (lab.home / 'scheduled.log').read_text())
    assert (lab.home / 'scheduled.log').read_text() == 'scheduled check ran\n'
    assert lab.prompts() == []
    lab.run('fm-captain-hold.sh', 'hold', 'drift', '--reason', 'Should I deploy this to production?', now=T120)
    lab.hold('deferred')
    lab.run('fm-captain-hold.sh', 'hold', 'deferred', '--until', '2099-01-01', '--reason', BRANCH, now=T59)
    lab.run('fm-captain-hold.sh', 'route-due', 'deferred', now=T120)
    assert lab.show('deferred')['held'] == 'yes' and lab.prompts() == []

try:
    scenario('upstream-lean baseline: both measured technical holds remain waiting', baseline)
    scenario('due technical holds release once through the existing watcher and retain owner evidence', technical)
    scenario('money, credentials, people, client words, production, accounts, taste, mixed asks and human endpoints remain held', reserved)
    scenario('interrupted answers, releases and reconciliations preserve recorded words and reject rerouting', interruptions)
    scenario('a genuinely new hold routes once while preserving historical field-like decision words', history)
    scenario('unreadable backlog preserves pending work; confirmed zero-retention archival retires it', archival)
    scenario('transport and unhold failures retain supervision and retry without duplicate delivery', retry)
    scenario('changed reasons and explicit deferral prevent routing; a routing error still permits scheduled checks', guards)
finally:
    (EVIDENCE / 'product-replay-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    LOG.close()
print(json.dumps(RESULTS, indent=2))
