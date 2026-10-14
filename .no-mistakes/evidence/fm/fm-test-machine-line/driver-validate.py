#!/usr/bin/env python3
"""Drive unmodified Firstmate suite CLIs through the installed native gate."""
import datetime
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path.cwd()
WORK = ROOT / '.live-machine-line'
EVIDENCE = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M4WN4HWS9WNQ0STXQVSD1KF2')
GATE = pathlib.Path('/Users/dalecarman/.agent-state/machine-gate.sh')
RUNNER = ROOT / 'bin/fm-test-run.sh'
FIXTURE = WORK / 'candidate-repo'
RESULTS = []
PROCESSES = []
NAMES = ['fm-dod-lib', 'fm-forge-detect', 'fm-project-mode', 'fm-trace-context-lib']
for directory in [WORK / 'temp', FIXTURE / 'bin', FIXTURE / 'tests', FIXTURE / 'skills/tools/harness']:
    directory.mkdir(parents=True, exist_ok=True)
for name in ['fm-test-run.sh', 'fm-test-isolation-proof.sh', 'fm-test-machine-line-lib.sh', 'fm-timeout-lib.sh']:
    shutil.copy2(ROOT / 'bin' / name, FIXTURE / 'bin' / name)
shutil.copy2(ROOT / 'tests/git-config-helpers.sh', FIXTURE / 'tests/git-config-helpers.sh')

WORKLOAD = WORK / 'workload.py'
WORKLOAD.write_text('''import datetime, json, os, pathlib, subprocess, sys, time
events = pathlib.Path(os.environ['LIVE_EVENTS'])
name = sys.argv[1]
tag = os.environ.get('LIVE_TAG', 'suite')
def emit(kind):
    record = dict(kind=kind, tag=tag, workload=name, pid=os.getpid(), ppid=os.getppid(),
                  at=time.time_ns(), utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  nice=os.getpriority(os.PRIO_PROCESS, 0),
                  task=os.environ.get('FM_TASK_ID'), held=os.environ.get('FM_TEST_MACHINE_LINE_HELD'),
                  holder=pathlib.Path(os.environ['MACHINE_LINE_DIR'], 'holder').read_text() if pathlib.Path(os.environ['MACHINE_LINE_DIR'], 'holder').exists() else None)
    descriptor=os.open(events, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(descriptor, (json.dumps(record)+'\\n').encode()); os.close(descriptor)
    print(json.dumps(record), flush=True)
emit('enter')
if os.environ.get('LIVE_NESTED') and name == 'fm-dod-lib':
    childenv = dict(os.environ, LIVE_TAG=tag+'-nested')
    childenv.pop('LIVE_RELEASE', None); childenv.pop('LIVE_NESTED', None)
    subprocess.run(['bash', os.environ['LIVE_RUNNER'], '--json', os.environ['LIVE_NESTED_JSON'], os.environ['LIVE_NESTED']], env=childenv, check=True)
release = os.environ.get('LIVE_RELEASE')
if release:
    deadline = time.monotonic()+45
    while not pathlib.Path(release).exists():
        if time.monotonic()>deadline: raise RuntimeError('workload release deadline')
        time.sleep(.05)
time.sleep(.15)
emit('exit')
sys.exit(int(os.environ.get('LIVE_EXIT', '0')))
''')
for name in NAMES + ['nested', 'single']:
    probe = FIXTURE / 'tests' / (name + '.test.sh')
    probe.write_text('#!/usr/bin/env bash\nexec python3 "$LIVE_WORKLOAD" ' + name + '\n')
    probe.chmod(0o755)

def env_for(case, tag):
    folder = WORK / case
    folder.mkdir(exist_ok=True)
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith('FM_TEST_MACHINE_') or key.startswith('MACHINE_GATE_') or key.startswith('MACHINE_LINE_') or key.startswith('LIVE_') or key in ['FM_TASK_ID', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_HOME', 'GIT_DIR', 'GIT_WORK_TREE']:
            environment.pop(key, None)
    environment.update(TMPDIR=str(WORK / 'temp'), TMP=str(WORK / 'temp'),
                       MACHINE_LINE_DIR=str(folder / 'line'),
                       MACHINE_GATE_HOLD_FILE=str(folder / 'absent-hold'),
                       FM_TEST_MACHINE_LINE_RETRY_SECS='1',
                       LIVE_EVENTS=str(EVIDENCE / (case + '-workloads.jsonl')),
                       LIVE_TAG=tag, LIVE_WORKLOAD=str(WORKLOAD), LIVE_RUNNER=str(RUNNER))
    return environment

def launch(command, environment, label, cwd=ROOT, input_text=None):
    out = open(EVIDENCE / (label + '.stdout.txt'), 'w')
    err = open(EVIDENCE / (label + '.stderr.txt'), 'w')
    process = subprocess.Popen([str(item) for item in command], cwd=cwd, env=environment,
                               stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                               stdout=out, stderr=err, text=True, start_new_session=True)
    out.close(); err.close()
    if input_text is not None:
        process.stdin.write(input_text); process.stdin.close()
    PROCESSES.append(process)
    print('LAUNCH ' + label + ': ' + ' '.join(map(str, command)), flush=True)
    return process

def finish(process, expected=0, seconds=60):
    code = process.wait(timeout=seconds)
    assert code == expected, f'pid {process.pid}: expected exit {expected}, got {code}'
    return code

def events(environment):
    path = pathlib.Path(environment['LIVE_EVENTS'])
    return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

def rows(environment):
    path = pathlib.Path(environment['MACHINE_LINE_DIR']) / 'log.tsv'
    return [line.split('\t', 3) for line in path.read_text().splitlines()] if path.exists() else []

def until(predicate, seconds=40):
    deadline = time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.1)
    raise AssertionError('observable state did not arrive before deadline')

def snapshot_line(environment, label):
    folder = pathlib.Path(environment['MACHINE_LINE_DIR'])
    for name in ['log.tsv', 'holder']:
        if (folder / name).exists(): shutil.copyfile(folder / name, EVIDENCE / (label + '-' + name))

def verify_release(environment, expected_starts):
    log = rows(environment)
    assert len([r for r in log if r[1]=='start']) == expected_starts, log
    assert len([r for r in log if r[1]=='end']) == expected_starts, log
    assert pathlib.Path(environment['MACHINE_LINE_DIR'], 'holder').read_text() == ''
    assert all('cap 180m' in r[3] for r in log if r[1]=='start')

def record(name, action):
    started = time.monotonic()
    try:
        detail = action()
        result = dict(name=name, result='pass', live=True, detail=detail)
    except Exception as error:
        result = dict(name=name, result='fail', live=True, detail=str(error))
    result['wall_seconds'] = round(time.monotonic()-started, 3)
    RESULTS.append(result)
    (EVIDENCE / 'live-scenarios.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    print(json.dumps(result), flush=True)

def admission():
    environment = env_for('admission', 'main')
    environment.update(LIVE_NESTED=str(FIXTURE / 'tests/nested.test.sh'), LIVE_NESTED_JSON=str(EVIDENCE / 'admission-nested.json'))
    command = [FIXTURE / 'bin/fm-test-run.sh', '--jobs', '4', '--json', EVIDENCE / 'admission.json'] + ['tests/' + name + '.test.sh' for name in NAMES]
    finish(launch(command, environment, 'admission'))
    verify_release(environment, 1)
    observed = events(environment)
    assert len([event for event in observed if event['kind']=='enter']) == 5
    assert all(event['held']=='1' for event in observed)
    assert all(event['nice']==os.getpriority(os.PRIO_PROCESS, 0) for event in observed)
    assert all(event['holder'].startswith('fm-test-run\t') for event in observed)
    snapshot_line(environment, 'admission')
    return 'Four real parallel workload commands and a nested suite ran under one native gate start/end; caller niceness was preserved.'

def contention(first, second):
    case = first + '-then-' + second
    a = env_for(case, 'first')
    a['LIVE_RELEASE'] = str(WORK / case / 'release')
    def command(mode, suffix):
        if mode=='proof':
            return [FIXTURE / 'bin/fm-test-isolation-proof.sh', '--pool', 'pure-contract-unit', '--jobs', '4', '--json', EVIDENCE / (case+'-'+suffix+'.json')]
        return [RUNNER, '--json', EVIDENCE / (case+'-'+suffix+'.json'), FIXTURE / 'tests/single.test.sh']
    first_process = launch(command(first, 'first'), a, case+'-first')
    until(lambda: any(e['kind']=='enter' and e['tag']=='first' for e in events(a)))
    b = env_for(case, 'second')
    second_process = launch(command(second, 'second'), b, case+'-second')
    until(lambda: any(r[1]=='busy' for r in rows(a)))
    assert not any(e['tag']=='second' for e in events(a))
    pathlib.Path(a['LIVE_RELEASE']).touch()
    finish(first_process); finish(second_process)
    log = rows(a)
    assert [r[1] for r in log if r[1] in ['start', 'end']] == ['start','end','start','end'], log
    first_exits = [e['at'] for e in events(a) if e['tag']=='first' and e['kind']=='exit']
    second_enters = [e['at'] for e in events(a) if e['tag']=='second' and e['kind']=='enter']
    assert first_exits and second_enters and max(first_exits)<min(second_enters)
    verify_release(a, 2); snapshot_line(a, case)
    return 'The second CLI logged native gate busy, executed no workloads while occupied, and entered after all first-suite workloads exited.'

def relative_paths():
    environment = env_for('relative', 'relative')
    for label, cwd, path in [('bin', FIXTURE / 'bin', './fm-test-run.sh'), ('skill', FIXTURE / 'skills/tools/harness', '../../../bin/fm-test-run.sh')]:
        finish(launch([path, 'tests/single.test.sh'], environment, 'relative-'+label, cwd=cwd))
    verify_release(environment, 2); snapshot_line(environment, 'relative')
    return 'Both documented relative launch forms completed and each took and released the real gate.'

def wait_budget():
    case='wait-budget'
    holder = env_for(case, 'holder')
    holder.update(LIVE_RELEASE=str(WORK / case / 'release'), MACHINE_LINE_NAME='fm-lab-budget-holder')
    held = launch(['bash', GATE, 'run', '--cap', '1', '--', 'bash', FIXTURE / 'tests/single.test.sh'], holder, case+'-holder')
    until(lambda: any(e['kind']=='enter' and e['tag']=='holder' for e in events(holder)))
    environment = env_for(case, 'budget')
    environment.update(LIVE_NESTED=str(FIXTURE / 'tests/nested.test.sh'), LIVE_NESTED_JSON=str(EVIDENCE / 'wait-budget-nested.json'))
    invoked_ms = int(time.time()*1000)
    process = launch([RUNNER, '--max-wall-ms', '1500', '--json', EVIDENCE / 'wait-budget.json', FIXTURE / 'tests/fm-dod-lib.test.sh'], environment, case)
    until(lambda: any(r[1]=='busy' for r in rows(holder)))
    time.sleep(2.2)
    pathlib.Path(holder['LIVE_RELEASE']).touch()
    finish(held); finish(process, expected=1)
    outer = json.loads((EVIDENCE / 'wait-budget.json').read_text())
    nested = json.loads((EVIDENCE / 'wait-budget-nested.json').read_text())
    assert outer['summary']['failed']==0 and outer['summary']['duration_ms']>=2200
    assert outer['summary']['duration_ms']>=int(time.time()*1000)-invoked_ms-1800
    assert nested['summary']['duration_ms']<1500 and nested['started_at']>=outer['started_at']
    assert len([r for r in rows(holder) if r[1]=='start'])==2
    snapshot_line(environment, case)
    return dict(outer_duration_ms=outer['summary']['duration_ms'], nested_duration_ms=nested['summary']['duration_ms'], exit=1, failed_workloads=0)

def failure():
    environment = env_for('failure', 'failing')
    environment['LIVE_EXIT']='75'
    finish(launch([RUNNER, '--json', EVIDENCE / 'failure.json', FIXTURE / 'tests/single.test.sh'], environment, 'failure'), expected=1)
    assert len([e for e in events(environment) if e['kind']=='enter'])==1
    assert [r[3] for r in rows(environment) if r[1]=='end']==['rc 1']
    environment.pop('LIVE_EXIT'); environment['LIVE_TAG']='after-failure'
    finish(launch([RUNNER, FIXTURE / 'tests/single.test.sh'], environment, 'after-failure'))
    verify_release(environment, 2); snapshot_line(environment, 'failure')
    return 'An admitted test exit 75 failed once, returned suite exit 1, released the line, and allowed a subsequent suite.'

def inspection():
    environment = env_for('inspection', 'holder')
    environment.update(LIVE_RELEASE=str(WORK / 'inspection/release'), MACHINE_LINE_NAME='fm-lab-inspection-holder')
    process = launch(['bash', GATE, 'run', '--cap', '1', '--', 'bash', FIXTURE / 'tests/single.test.sh'], environment, 'inspection-holder')
    until(lambda: any(e['kind']=='enter' for e in events(environment)))
    before = len(rows(environment))
    for label, command, code in [('runner', [RUNNER, '--list', '--jobs', '4', FIXTURE / 'tests/fm-dod-lib.test.sh'], 0), ('proof', [FIXTURE / 'bin/fm-test-isolation-proof.sh', '--list', '--pool', 'pure-contract-unit'], 0), ('invalid', [RUNNER, '--jobs', '0', FIXTURE / 'tests/single.test.sh'], 2)]:
        finish(launch(command, environment, 'inspection-'+label), expected=code, seconds=10)
    assert len(rows(environment))==before
    pathlib.Path(environment['LIVE_RELEASE']).touch(); finish(process)
    snapshot_line(environment, 'inspection')
    return 'Both listing commands and invalid invocation returned while the native line remained occupied without attempting admission.'

def fallback():
    for label, override in [('disabled', ''), ('missing', str(WORK / 'missing-gate.sh')), ('inherited', str(GATE))]:
        environment=env_for('fallback-'+label, label)
        environment['FM_TEST_MACHINE_GATE']=override
        if label=='inherited': environment['FM_TEST_MACHINE_LINE_HELD']='1'
        finish(launch([RUNNER, FIXTURE / 'tests/single.test.sh'], environment, 'fallback-'+label))
        assert not rows(environment)
        assert len(events(environment))==2
    return 'Accepted missing/disabled-gate fallback and already-admitted invocation each ran once without fresh admission.'

def main():
    record('main-jobs4-and-nested-admission', admission)
    record('runner-waits-for-runner', lambda: contention('runner', 'runner'))
    record('proof-waits-for-runner', lambda: contention('runner', 'proof'))
    record('runner-waits-for-proof', lambda: contention('proof', 'runner'))
    record('relative-runner-launches', relative_paths)
    record('admission-wait-is-in-budget', wait_budget)
    record('failed-suite-releases-without-retry', failure)
    record('inspection-and-refusal-do-not-wait', inspection)
    record('accepted-admission-exceptions', fallback)
    return 1 if any(r['result']=='fail' for r in RESULTS) else 0

if __name__=='__main__':
    try:
        if sys.argv[1:] == ['admission']:
            previous = json.loads((EVIDENCE / 'live-scenarios.json').read_text())
            RESULTS.extend(r for r in previous if r['name'] != 'main-jobs4-and-nested-admission')
            record('main-jobs4-and-nested-admission', admission)
            sys.exit(1 if RESULTS[-1]['result']=='fail' else 0)
        sys.exit(main())
    finally:
        for process in PROCESSES:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        for process in PROCESSES:
            if process.poll() is None:
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL)
