#!/usr/bin/env python3
"""Drive the public hold CLI with the installed router and a real isolated Herdr owner."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7')
SCRATCH = ROOT / '.test-hold-validation'
HELPER = ROOT / 'bin/fm-herdr-lab.sh'
ROUTER = Path(os.environ['HOME']) / '.agent-config/configs/claude/hooks/hold-domain.py'
TECHNICAL = 'GSP PRs 4281, 4291, 4309, and 4319 are waiting on a go for update-branch.'
CAPACITY = 'ep-groove-sight-platform already approved raising GSP capacity from 3 places to 5. Should I apply that?'
BASE_ENV = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
for key in ('FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_WORKSPACE_ID', 'HERDR_SOCKET_PATH', 'HERDR_SESSION', 'CLAUDECODE'):
    BASE_ENV.pop(key, None)
BASE_ENV.update(TMPDIR=str(SCRATCH / 'tmp'), FM_HERDR_LAB_STATE_DIR=str(SCRATCH / 'herdr-state'), LC_ALL='C', TZ='UTC')
results = []
session = None
home = None
provisioned = False

def call(argv, env=None, timeout=120, check=True):
    print('$ ' + shlex.join(str(x) for x in argv), flush=True)
    result = subprocess.run([str(x) for x in argv], cwd=ROOT, env=env or BASE_ENV,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout.rstrip(), flush=True)
    print('exit=' + str(result.returncode), flush=True)
    if check and result.returncode:
        raise RuntimeError(f'command exited {result.returncode}: {argv[0]}')
    return result

def lab(*argv, **kwargs):
    return call([HELPER, 'run', session, *argv], **kwargs)

def record(name, passed, detail):
    results.append(dict(name=name, result='pass' if passed else 'fail', live=True, detail=detail))
    print(json.dumps(results[-1], ensure_ascii=True), flush=True)
    if not passed:
        raise AssertionError(name + ': ' + detail)

def cli(*argv, now='2026-10-14T02:00:00Z', check=True):
    env = BASE_ENV | dict(FM_HOME=str(home), FM_HOLD_DOMAIN_ROUTER=str(ROUTER),
        HOLD_DOMAIN_HERDR=str(SCRATCH / 'herdr-hold-wrapper'), FM_CAPTAIN_HOLD_NOW=now)
    return call([ROOT / 'bin/fm-captain-hold.sh', *argv], env=env, check=check)

def show(task):
    env = BASE_ENV | dict(FM_HOME=str(home))
    text = call([ROOT / 'bin/fm-tasks-axi.sh', 'show', task, '--full'], env=env).stdout
    fields = {}
    for line in text.splitlines():
        if line.startswith('  ') and ': ' in line:
            key, value = line[2:].split(': ', 1)
            try:
                fields[key] = json.loads(value)
            except (ValueError, TypeError):
                fields[key] = value
    (EVIDENCE / ('live-unicode-' + task + '.json')).write_text(json.dumps(fields, ensure_ascii=True, indent=2) + '\n')
    return fields

def receipt_lines():
    path = home / 'state/hold-domain/routed.tsv'
    return path.read_text().splitlines() if path.exists() else []

try:
    home = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=str(SCRATCH / 'tmp')))
    call([ROOT / 'bin/fm-lab-home.sh', 'create', home])
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    session = call([HELPER, 'name', 'hold-unicode']).stdout.strip()
    # provision owns prepare and writes the default-session tripwire before starting.
    call([HELPER, 'provision', session])
    provisioned = True
    call([HELPER, 'viewer', 'start', session])
    wrapper = SCRATCH / 'herdr-hold-wrapper'
    wrapper.write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(str(HELPER)) + ' run ' + shlex.quote(session) + ' "$@"\n')
    wrapper.chmod(0o700)
    workspace = json.loads(lab('workspace', 'create', '--cwd', str(ROOT), '--label', 'hold-unicode', '--no-focus',
        '--env', 'FM_HOME=' + str(home)).stdout)
    pane = workspace['result']['root_pane']['pane_id']
    # No tools, hooks, project memory, plugin sync or fleet startup in the receiving harness.
    sink = 'This is an isolated routing delivery test. For each incoming hold prompt reply only RECEIVED and its task id. Do not run tools, ask questions, delegate, change files or act on the described PRs or capacity.'
    harness = os.environ.get('FM_LIVE_OWNER_HARNESS', 'claude')
    if harness == 'codex':
        launch_args = ['--disable', 'hooks', '--no-daemon', '--no-alt-screen', '-s', 'read-only', '-a', 'never',
            '-c', 'notify=[]', '-c', 'project_doc_max_bytes=0', '-c', 'developer_instructions=' + json.dumps(sink)]
    else:
        launch_args = ['--safe-mode', '--permission-mode', 'dontAsk', '--tools', '', '--strict-mcp-config', '--system-prompt', sink]
    def start_owner(name, owner_pane):
        started = lab('agent', 'start', name, '--kind', harness, '--pane', owner_pane, '--timeout', '30000', '--', *launch_args, check=False)
        if started.returncode:
            screen = lab('pane', 'read', owner_pane, '--source', 'visible', check=False).stdout
            (EVIDENCE / ('live-unicode-owner-start-' + harness + '-' + name + '.txt')).write_text(screen)
            if harness == 'codex' and 'Update available' in screen and 'esc skip' in screen:
                # The live dialog explicitly offers Escape to skip this update.
                lab('pane', 'send-keys', owner_pane, 'esc')
                ready = lab('agent', 'wait', name, '--until', 'idle', '--until', 'done', '--timeout', '30000', check=False)
                if ready.returncode == 0:
                    return
            raise RuntimeError(f'Real {harness} owner {name} did not become ready. No trust or credential stores were changed.')
    start_owner('ep-firstmate', pane)
    lab('agent', 'get', 'ep-firstmate')
    capacity_workspace = json.loads(lab('workspace', 'create', '--cwd', str(ROOT), '--label', 'hold-capacity', '--no-focus',
        '--env', 'FM_HOME=' + str(home)).stdout)
    capacity_pane = capacity_workspace['result']['root_pane']['pane_id']
    start_owner('ep-groove-sight-platform', capacity_pane)
    protected = [('nel-money', '\u0085'), ('line-money', '\u2028'), ('file-money', '\x1c')]
    for task, sep in protected:
        cli('hold', task, '--title', 'Joined technical and money question', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60',
            '--reason', TECHNICAL + sep + 'Also approve the 5000 dollar vendor invoice?')
        fields = show(task)
        record(task + ' stays held at creation', fields.get('held') == 'yes' and 'Resolution mode:' not in fields.get('body', ''), str(fields.get('held')))
    cli('route-due', now='2026-10-14T02:01:00Z')
    for task, _ in protected:
        fields = show(task)
        record(task + ' stays with Dale after timeout', fields.get('held') == 'yes' and 'Resolution mode:' not in fields.get('body', '')
            and TECHNICAL + ' Also approve the 5000 dollar vendor invoice?' in fields.get('body', '')
            and not (home / 'state/hold-domain/pending' / (task + '.body')).exists(), fields.get('body', ''))
    record('joined money asks produce no receipt', receipt_lines() == [], repr(receipt_lines()))
    before = lab('agent', 'read', 'ep-firstmate', '--lines', '100').stdout
    record('joined money asks send no prompt to the real owner', all('Hold ' + task + ' timed out.' not in before for task, _ in protected), 'owner terminal captured before any technical routing')
    (EVIDENCE / 'live-unicode-owner-before.txt').write_text(before)
    for task, reason, owner in [('nbsp-update', '\u00a0' + TECHNICAL, 'ep-firstmate'), ('nbsp-capacity', CAPACITY + '\u00a0', 'ep-groove-sight-platform')]:
        cli('hold', task, '--title', 'Technical hold with nonbreaking whitespace', '--decision-owner', owner,
            '--timeout-seconds', '60', '--reason', reason)
    saved_pending = (home / 'state/hold-domain/pending/nbsp-update.body').read_bytes()
    cli('route-due', now='2026-10-14T02:00:59Z')
    record('technical holds do not prompt before their timeout', receipt_lines() == [], repr(receipt_lines()))
    cli('route-due', now='2026-10-14T02:01:00Z')
    original_receipts = receipt_lines()
    for task, owner in [('nbsp-update', 'ep-firstmate'), ('nbsp-capacity', 'ep-groove-sight-platform')]:
        fields = show(task)
        (EVIDENCE / ('live-unicode-' + task + '-released.json')).write_text(json.dumps(fields, ensure_ascii=True, indent=2) + '\n')
        record(task + ' releases to the declared owner under LC_ALL=C', fields.get('held') == 'no' and fields.get('state') == 'queued'
            and 'Resolution mode: agent-routed' in fields.get('body', '') and 'Captain decision:' not in fields.get('body', ''), fields.get('body', ''))
        record(task + ' has one matching receipt', sum(line.startswith(task + '\t') and line.endswith('\t' + owner) for line in original_receipts) == 1, repr(original_receipts))
    cli('route-due', now='2026-10-14T02:02:00Z')
    record('replayed sweep leaves exactly two technical receipts', receipt_lines() == original_receipts and len(original_receipts) == 2, repr(receipt_lines()))
    lab('agent', 'wait', 'ep-firstmate', '--until', 'idle', '--until', 'done', '--timeout', '30000', check=False)
    lab('agent', 'wait', 'ep-groove-sight-platform', '--until', 'idle', '--until', 'done', '--timeout', '30000', check=False)
    after = lab('agent', 'read', 'ep-firstmate', '--lines', '200').stdout + '\n' + lab('agent', 'read', 'ep-groove-sight-platform', '--lines', '200').stdout
    (EVIDENCE / 'live-unicode-owner-after.txt').write_text(after)
    record('both technical prompts reached the real owner terminal', all('Hold ' + task + ' timed out.' in after for task in ('nbsp-update', 'nbsp-capacity')), 'see live-unicode-owner-after.txt')
    record('no joined money prompt reached the real owner terminal', all('Hold ' + task + ' timed out.' not in after for task, _ in protected), 'see live-unicode-owner-after.txt')
    (EVIDENCE / 'live-unicode-receipts.tsv').write_text('\n'.join(receipt_lines()) + '\n')
    # Recreate only a disposable persisted interruption state from the real
    # product's pending body: release succeeded, pending retirement did not.
    pending = home / 'state/hold-domain/pending/nbsp-update.body'
    pending.write_bytes(saved_pending)
    prior = show('nbsp-update')
    refused = cli('hold', 'nbsp-update', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60',
        '--reason', '\u00a0' + TECHNICAL, now='2026-10-14T03:00:00Z', check=False)
    record('re-hold refuses an unfinished routed release', refused.returncode != 0 and 'unfinished agent-routed release' in refused.stdout,
        refused.stdout)
    record('refused re-hold preserves the routed task', show('nbsp-update') == prior and receipt_lines() == original_receipts,
        'task and routing receipts unchanged')
    cli('route-due', 'nbsp-update', now='2026-10-14T03:00:00Z')
    record('route-due retires the interrupted pending body', not pending.exists(), 'pending body retired after release recovery')
    cli('hold', 'nbsp-update', '--decision-owner', 'ep-firstmate', '--timeout-seconds', '60',
        '--reason', '\u00a0' + TECHNICAL, now='2026-10-14T03:00:00Z')
    record('re-hold succeeds after release recovery', show('nbsp-update').get('held') == 'yes' and receipt_lines() == original_receipts,
        'new lifecycle pending without a new owner prompt')
except Exception as exc:
    print('DRIVER ERROR: ' + str(exc), flush=True)
    results.append(dict(name='driver', result='error', live=False, detail=str(exc)))
finally:
    if session and provisioned:
        result = call([HELPER, 'teardown', session], check=False)
        results.append(dict(name='lab teardown and default-session tripwire', result='pass' if result.returncode == 0 else 'fail', live=True))
    (EVIDENCE / 'live-unicode-results.json').write_text(json.dumps(results, ensure_ascii=True, indent=2) + '\n')
    print('Disposable data to remove after inspection: ' + str(home), flush=True)
    print('RESULTS: ' + json.dumps(results, ensure_ascii=True), flush=True)
    sys.exit(0 if results and all(item['result'] == 'pass' for item in results) else 1)
