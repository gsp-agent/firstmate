#!/usr/bin/env python3
"""Drive the real Cursor guard CLI with isolated, persisted runtime state."""
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
from zoneinfo import ZoneInfo

REPO = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4WXW8KSPQP94CN0XC6NMK69')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4WXW8KSPQP94CN0XC6NMK69')
RUN = EVIDENCE / 'cursor-cap-runtime'
RUN.mkdir(exist_ok=False)
TOOL = REPO / 'bin/fm-cursor-guard.sh'
DAY = datetime.datetime.now(ZoneInfo('America/Chicago')).date().isoformat()
BASE_ENV = dict(os.environ)
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CURSOR_DAY', 'FM_GATE_REFUSE_BYPASS'):
    BASE_ENV.pop(key, None)
TRANSCRIPT = []
RESULTS = []


def record(message):
    TRANSCRIPT.append(message)
    print(message, flush=True)


def home(name):
    path = RUN / name
    for child in ('state', 'config', 'usage', 'pstack/.cursor-plugin'):
        (path / child).mkdir(parents=True, exist_ok=True)
    # The guard consumes plugin metadata and spending files as runtime inputs.
    (path / 'pstack/.cursor-plugin/plugin.json').write_text('{"name":"pstack","version":"0.15.21"}\n')
    return path


def env(path):
    return dict(BASE_ENV, FM_HOME=str(path), FM_CURSOR_USAGE_DIR=str(path / 'usage'), FM_PSTACK_DIR=str(path / 'pstack'))


def invoke(path, op, bead, tool=TOOL, extra_env=None):
    command = ['bash', str(tool), op, bead]
    effective_env = env(path)
    effective_env.update(extra_env or {})
    result = subprocess.run(command, cwd=REPO, env=effective_env, text=True, capture_output=True, timeout=25)
    statefile = path / 'state/cursor-dispatch.json'
    state = json.loads(statefile.read_text()) if statefile.exists() else None
    return {'command': f'bash {tool.name} {op} {bead}', 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr, 'state': state}


def call(path, op, bead, tool=TOOL, extra_env=None):
    result = invoke(path, op, bead, tool, extra_env)
    record(json.dumps(result, sort_keys=True))
    return result


def scenario(name, body):
    record('\nSCENARIO: ' + name)
    try:
        body()
        RESULTS.append({'name': name, 'result': 'pass'})
        record('RESULT: pass')
    except Exception as error:
        RESULTS.append({'name': name, 'result': 'fail', 'error': str(error)})
        record('RESULT: fail: ' + repr(error))


record('Real product entry point: bin/fm-cursor-guard.sh; separate process per invocation, no mocked commands.')
record('Scope: launch accounting and routing decisions only; no Cursor or Grok worker or model request is launched.')
record('Current America/Chicago day: ' + DAY)
record('Target: ' + subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip())


def before_fix():
    previous = RUN / 'before-cap-change.sh'
    previous.write_bytes(subprocess.check_output(['git', 'show', '84c071cc9cbcebf23234d50b1bee210d3b9c97ea^:bin/fm-cursor-guard.sh'], cwd=REPO))
    baseline = home('baseline-two')
    for number in (1, 2):
        result = call(baseline, 'take', 'gate-answers', previous)
        assert result['exit_code'] == 0 and result['state']['beads']['gate-answers'] == number, result
    result = call(baseline, 'take', 'gate-answers', previous)
    assert result['exit_code'] == 1 and result['state']['beads']['gate-answers'] == 2, result
    assert 'instead of a 3rd run' in result['stderr'], result


def six_then_stop():
    path = home('six-launches')
    for number in range(1, 7):
        result = call(path, 'take', 'gate-answers')
        assert result['exit_code'] == 0 and result['stdout'] == '' and result['stderr'] == '', result
        assert result['state'] == {'day': DAY, 'beads': {'gate-answers': number}}, result
    statefile = path / 'state/cursor-dispatch.json'
    before = hashlib.sha256(statefile.read_bytes()).hexdigest()
    for attempt in (7, 8):
        result = call(path, 'take', 'gate-answers')
        assert result['exit_code'] == 1 and result['stdout'] == '', result
        assert result['stderr'] == f'cursor guard: refused gate-answers, already launched 6 times today ({DAY}); write blocked: instead of a run past the daily cap of 6\n', result
        assert hashlib.sha256(statefile.read_bytes()).hexdigest() == before, result


def independent_beads():
    path = RUN / 'six-launches'
    for number in range(1, 9):
        bead = f'independent-{number}'
        result = call(path, 'take', bead)
        assert result['exit_code'] == 0 and result['state']['beads'][bead] == 1, result
        assert result['state']['beads']['gate-answers'] == 6, result


def failed_spawn():
    path = RUN / 'six-launches'
    result = call(path, 'give', 'gate-answers')
    assert result['exit_code'] == 0 and result['state']['beads']['gate-answers'] == 5, result
    result = call(path, 'take', 'gate-answers')
    assert result['exit_code'] == 0 and result['state']['beads']['gate-answers'] == 6, result
    result = call(path, 'take', 'gate-answers')
    assert result['exit_code'] == 1 and result['state']['beads']['gate-answers'] == 6, result


def rollover():
    path = home('day-rollover')
    yesterday = (datetime.date.fromisoformat(DAY) - datetime.timedelta(days=1)).isoformat()
    # Exercise the public documented day seam to create yesterday's actual state.
    for number in range(1, 7):
        result = call(path, 'take', 'same-task', extra_env={'FM_CURSOR_DAY': yesterday})
        assert result['exit_code'] == 0 and result['state']['day'] == yesterday, result
    result = call(path, 'take', 'same-task')
    assert result['exit_code'] == 0 and result['state'] == {'day': DAY, 'beads': {'same-task': 1}}, result


def competing_takes():
    path = home('concurrent-takes')
    for number in range(1, 6):
        result = call(path, 'take', 'race-task')
        assert result['exit_code'] == 0, result
    # Separate real guard processes race for one remaining slot using its real lock.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: invoke(path, 'take', 'race-task'), range(8)))
    for result in results:
        record(json.dumps(result, sort_keys=True))
    statuses = sorted(result['exit_code'] for result in results)
    assert statuses == [0, 1, 1, 1, 1, 1, 1, 1], statuses
    state = json.loads((path / 'state/cursor-dispatch.json').read_text())
    record('Final concurrent state: ' + json.dumps(state))
    assert state == {'day': DAY, 'beads': {'race-task': 6}}, state
    assert not (path / 'state/cursor-dispatch.lock').exists()


def fallback():
    path = home('spending-routing')
    spending = path / 'usage/live-spending.txt'
    for pct, expected in ((84, 'cursor\n'), (85, 'grok Cursor Models at 85% (limit 85%)\n'), (90, 'grok Cursor Models at 90% (limit 85%)\n')):
        spending.write_text(f'cursor_models_pct={pct}\n')
        result = call(path, 'fallback', 'spending-task')
        assert result['exit_code'] == 0 and result['stdout'] == expected and result['stderr'] == '', result
    spending.write_text('cursor_models_pct=84\n')
    old = datetime.datetime.now().timestamp() - 27 * 3600
    os.utime(spending, (old, old))
    result = call(path, 'fallback', 'spending-task')
    assert result['exit_code'] == 0 and result['stdout'].startswith('grok newest Cursor spending file is 27 h old'), result
    missing = home('missing-spending')
    result = call(missing, 'fallback', 'spending-task')
    assert result['exit_code'] == 0 and result['stdout'].startswith('grok no Cursor spending file in '), result


scenario('Before the change, launch three is refused with a persisted count of two', before_fix)
scenario('Six separate guard processes admit one task today; attempts seven and eight refuse without changing its count', six_then_stop)
scenario('Eight other tasks still receive their own launch allowances', independent_beads)
scenario('Returning a failed spawn restores exactly one slot at the cap', failed_spawn)
scenario('A task at yesterday\'s cap starts again at one on the real Central date', rollover)
scenario('Eight simultaneous requests for the last slot admit exactly one and persist six', competing_takes)
scenario('Spending routing stays on Cursor at 84%, chooses Grok at 85% and 90%, and fails closed for stale or missing data', fallback)

(EVIDENCE / 'cursor-cap-runtime.log').write_text('\n'.join(TRANSCRIPT) + '\n')
(EVIDENCE / 'cursor-cap-runtime-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
raise SystemExit(1 if any(result['result'] != 'pass' for result in RESULTS) else 0)
