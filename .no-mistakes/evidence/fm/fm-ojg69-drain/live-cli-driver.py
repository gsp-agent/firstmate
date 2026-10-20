import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path.cwd()
LAB = ROOT / '.nm-live-test/cli-home'
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in (
        'FM_GATE_REFUSE_BYPASS', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
        'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'NO_MISTAKES_HOME',
    ):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='live@example.invalid',
           GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='live@example.invalid',
           TMPDIR=str(ROOT / '.nm-live-test/tmp'))

def run(args, cwd=ROOT, expected=0, extra=None):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, cwd=cwd, env={**ENV, **(extra or {})}, text=True, capture_output=True, timeout=120)
    print(p.stdout, end='', flush=True)
    print(p.stderr, end='', flush=True)
    print('exit: ' + str(p.returncode), flush=True)
    assert p.returncode == expected, (args, p.returncode, expected)
    return p.stdout

run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
upstream = LAB / 'projects/upstream'
fork = LAB / 'projects/fork'
run(['git', 'init', '-q', '-b', 'main', upstream])
run(['git', 'commit', '-q', '--allow-empty', '-m', 'upstream baseline'], cwd=upstream)
run(['git', 'clone', '-q', upstream, fork])
run(['git', 'remote', 'rename', 'origin', 'kunchenguid'], cwd=fork)
base = run(['git', 'rev-parse', 'HEAD'], cwd=fork).strip()
(fork / 'accepted.txt').write_text('measured customization\n')
(fork / 'drift-proof.txt').write_text('after: ' + base + '\n')
run(['git', 'add', 'accepted.txt', 'drift-proof.txt'], cwd=fork)
run(['git', 'commit', '-qm', 'accepted measured change'], cwd=fork)
guard = ROOT / 'bin/fm-drift-nightly.sh'
green = run([guard, 'check', '--repo', fork, '--no-fetch'])
assert 'path-drift:' not in green and 'path-ok: accepted.txt' in green
run([guard, 'nightly', '--repo', fork, '--log', LAB / 'nightly.log'])
assert not list((LAB / 'state/inbox').glob('*.note'))
print('OBSERVED: accepted committed patches pass; a green scheduled invocation creates no inbox note.', flush=True)

(fork / 'pending.txt').write_text('accepted while measurement is pending\n')
run(['git', 'add', 'pending.txt'], cwd=fork)
run(['git', 'commit', '-qm', 'pending measurement'], cwd=fork)
pending_sha = run(['git', 'rev-parse', 'HEAD'], cwd=fork).strip()
proof = LAB / 'pending-proof.txt'
proof.write_text('after: ' + base + '\npending: ' + pending_sha + ' proof-followup\n')
pending = run([guard, 'check', '--repo', fork, '--no-fetch', '--proof', proof])
assert 'pending: ' + pending_sha + ' proof-followup' in pending and 'path-drift:' not in pending
print('OBSERVED: pending proof preserves its bead and is reported as pending, never keep.', flush=True)

(fork / 'accepted.txt').write_text('unmeasured replacement\n')
run(['git', 'add', 'accepted.txt'], cwd=fork)
run(['git', 'commit', '-qm', 'unproven edit to accepted file'], cwd=fork)
red = run([guard, 'check', '--repo', fork, '--no-fetch', '--proof', proof], expected=1)
assert 'path-drift: accepted.txt' in red
for attempt in range(2):
    run([guard, 'nightly', '--repo', fork, '--log', LAB / 'nightly.log'], expected=1)
notes = list((LAB / 'state/inbox').glob('*.note'))
assert len(notes) == 1
print('PERSISTED NIGHTLY NOTE:\n' + notes[0].read_text(), flush=True)
assert 'accepted.txt' in notes[0].read_text()
print('OBSERVED: unproven edits fail; repeated red scheduled invocations persist one daily note.', flush=True)
run([guard, 'install', '--dry-run', '--repo', fork, '--log', LAB / 'nightly.log'], extra={'FM_DRIFT_AGENT_DIR': str(LAB / 'agents')})
assert not (LAB / 'agents').exists()
print('OBSERVED: installation preview writes no job or agent directory; cutover was not performed.', flush=True)

def provider(name, remaining, credits=None):
    value = {'provider': name, 'windows': [], 'quotaSemantics': {'status': 'known', 'effectiveAvailability': [
        {'scope': 'all_models', 'status': 'known', 'effectivePercentRemaining': remaining,
         'runway': {'status': 'through_reset' if remaining else 'exhausted_now'}}]}}
    if credits is not None:
        value['credits'] = {'remaining': credits, 'unit': 'credits'}
    return value

quota = LAB / 'quota.json'
obj = {'schemaVersion': 5, 'generatedAt': '2026-10-20T00:00:00Z', 'providers': [
    provider('grok', 0, 50), provider('codex', 30), provider('claude', 30)]}
quota.write_text(json.dumps(obj))
choose = ROOT / 'bin/fm-quota-choose.sh'
assert run([choose, '--snapshot', quota, 'codex:sol', 'claude:sonnet']).strip() == 'codex sol'
assert run([choose, '--snapshot', quota, 'grok:grok-4.7', 'codex:sol']).strip() == 'grok grok-4.7'
obj['providers'][0]['credits']['remaining'] = 0
quota.write_text(json.dumps(obj))
assert run([choose, '--snapshot', quota, 'grok:grok-4.7', 'codex:sol']).strip() == 'codex sol'
print('OBSERVED: the quota consumer preserves candidate order, uses usable prepaid credits, and falls back when those credits are empty.', flush=True)

usage = LAB / 'usage'
usage.mkdir()
(LAB / 'config/crew-dispatch.json').write_text(json.dumps({'cursor_fallback': {'models_pct': 85, 'max_age_h': 26}}))
spending = usage / '2026-10-20-spending.txt'
spending.write_text('cursor_models_pct=100\non_demand=enabled\nprepaid_balance=50\nmonthly_additional_usage_used=1\nmonthly_additional_usage_limit=100\n')
cursor = ROOT / 'bin/fm-cursor-guard.sh'
assert run([cursor, 'fallback', 'proof-routing'], extra={'FM_CURSOR_USAGE_DIR': str(usage)}).strip() == 'cursor'
spending.write_text('cursor_models_pct=100\non_demand=enabled\nprepaid_balance=0\nmonthly_additional_usage_used=100\nmonthly_additional_usage_limit=100\n')
assert run([cursor, 'fallback', 'proof-routing'], extra={'FM_CURSOR_USAGE_DIR': str(usage)}).startswith('codex ')
(LAB / 'state/proof-routing.codex-limit').write_text('Codex usage exhausted\n')
assert run([cursor, 'fallback', 'proof-routing'], extra={'FM_CURSOR_USAGE_DIR': str(usage)}).startswith('claude ')
print('OBSERVED: Cursor credit room retains Cursor; exhausted credits select Codex and a recorded Codex limit selects Claude.', flush=True)

role = ROOT / 'bin/fm-role.sh'
assert run([role, 'report']).strip() == 'fm-role: user (default)'
refusal = run([role, 'check', ROOT], expected=1)
assert refusal.startswith('refused:')
assert run([role, 'report']).strip() == 'fm-role: user (default)'
print('OBSERVED: a fresh home is an operator and cannot authorize upstream publication from repository identity alone.', flush=True)
print('LIVE_CLI_RESULT: pass', flush=True)
