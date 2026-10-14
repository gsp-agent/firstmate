#!/usr/bin/env python3
"""Replay reported failures against their historical executable versions."""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import time

ROOT=pathlib.Path.cwd()
WORK=ROOT / '.live-machine-line'
EVIDENCE=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M4WN4HWS9WNQ0STXQVSD1KF2')
GATE=pathlib.Path('/Users/dalecarman/.agent-state/machine-gate.sh')
PROCESSES=[]
RESULTS=[]

def tree(name, revision):
    folder=WORK / name
    (folder / 'bin').mkdir(parents=True)
    (folder / 'tests').mkdir()
    for filename in ['fm-test-run.sh','fm-test-isolation-proof.sh']:
        data=subprocess.run(['git','show',revision+':bin/'+filename],cwd=ROOT,check=True,stdout=subprocess.PIPE).stdout
        target=folder / 'bin' / filename
        target.write_bytes(data); target.chmod(0o755)
    shutil.copy2(ROOT / 'tests/git-config-helpers.sh', folder / 'tests/git-config-helpers.sh')
    for filename in ['single.test.sh','fm-dod-lib.test.sh','fm-forge-detect.test.sh','fm-project-mode.test.sh','fm-trace-context-lib.test.sh']:
        shutil.copy2(WORK / 'candidate-repo/tests' / filename, folder / 'tests' / filename)
    return folder

def environment(case, tag):
    directory=WORK / case
    directory.mkdir(exist_ok=True)
    env=dict(os.environ)
    for key in list(env):
        if key.startswith(('FM_TEST_MACHINE_', 'MACHINE_GATE_', 'MACHINE_LINE_', 'LIVE_')) or key=='FM_TASK_ID': env.pop(key,None)
    env.update(TMPDIR=str(WORK / 'temp'),TMP=str(WORK / 'temp'),MACHINE_LINE_DIR=str(directory / 'line'),
               MACHINE_GATE_HOLD_FILE=str(directory / 'absent-hold'),FM_TEST_MACHINE_LINE_RETRY_SECS='1',
               LIVE_EVENTS=str(EVIDENCE / (case+'-workloads.jsonl')), LIVE_TAG=tag, LIVE_WORKLOAD=str(WORK / 'workload.py'))
    return env

def launch(command, env, label, cwd=ROOT):
    with open(EVIDENCE / (label+'.stdout.txt'),'w') as out, open(EVIDENCE / (label+'.stderr.txt'),'w') as err:
        process=subprocess.Popen([str(a) for a in command],env=env,cwd=cwd,stdout=out,stderr=err,start_new_session=True)
    PROCESSES.append(process)
    print('LAUNCH '+label+': '+' '.join(map(str,command)),flush=True)
    return process

def events(env):
    filename=pathlib.Path(env['LIVE_EVENTS'])
    return [json.loads(row) for row in filename.read_text().splitlines()] if filename.exists() else []

def until(predicate):
    deadline=time.monotonic()+35
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.1)
    raise AssertionError('expected workload did not enter')

def finish(process, code=0):
    actual=process.wait(timeout=45)
    assert actual==code, (actual,code)

def snapshot(env, label):
    shutil.copyfile(pathlib.Path(env['MACHINE_LINE_DIR']) / 'log.tsv', EVIDENCE / (label+'-log.tsv'))

def baseline_overlap(base, mode):
    case='baseline-'+mode
    holder=environment(case,'holder')
    holder.update(MACHINE_LINE_NAME='baseline-external-holder',LIVE_RELEASE=str(WORK / case / 'release'))
    first=launch(['bash',GATE,'run','--cap','1','--','bash',base / 'tests/single.test.sh'],holder,case+'-holder')
    until(lambda:any(e['kind']=='enter' and e['tag']=='holder' for e in events(holder)))
    suite=environment(case,'ungated-'+mode)
    if mode=='proof':
        command=[base / 'bin/fm-test-isolation-proof.sh','--pool','pure-contract-unit','--jobs','4']
    else:
        command=[base / 'bin/fm-test-run.sh','--jobs','4','--json',EVIDENCE / (case+'.json')]+['tests/'+name+'.test.sh' for name in ['fm-dod-lib','fm-forge-detect','fm-project-mode','fm-trace-context-lib']]
    second=launch(command,suite,case)
    finish(second)
    observed=events(holder)
    assert len([e for e in observed if e['kind']=='enter' and e['tag']=='ungated-'+mode])==4
    assert not any(e['kind']=='exit' and e['tag']=='holder' for e in observed)
    assert all(e['held'] is None for e in observed if e['tag']=='ungated-'+mode)
    pathlib.Path(holder['LIVE_RELEASE']).touch(); finish(first); snapshot(holder,case)
    RESULTS.append(dict(name=case,result='reproduced',revision='20dcbf91520b1816663b81873ad67d0b93b3e4d6',overlapping_workloads=4,native_gate_suite_starts=0))
    print(json.dumps(RESULTS[-1]),flush=True)

def old_relative(previous):
    env=environment('before-review-relative','relative')
    process=launch(['./fm-test-run.sh','tests/single.test.sh'],env,'before-review-relative',cwd=previous / 'bin')
    finish(process,127)
    assert not events(env)
    snapshot(env,'before-review-relative')
    RESULTS.append(dict(name='relative-reexecution-failure',result='reproduced',revision='516346af',exit=127,workloads_executed=0))
    print(json.dumps(RESULTS[-1]),flush=True)

def old_budget(previous):
    case='before-review-budget'
    holder=environment(case,'holder')
    holder.update(MACHINE_LINE_NAME='budget-external-holder',LIVE_RELEASE=str(WORK / case / 'release'))
    first=launch(['bash',GATE,'run','--cap','1','--','bash',previous / 'tests/single.test.sh'],holder,case+'-holder')
    until(lambda:any(e['kind']=='enter' and e['tag']=='holder' for e in events(holder)))
    suite=environment(case,'old-budget')
    invoked=time.monotonic()
    second=launch([previous / 'bin/fm-test-run.sh','--max-wall-ms','1500','--json',EVIDENCE / (case+'.json'),'tests/single.test.sh'],suite,case)
    logfile=pathlib.Path(holder['MACHINE_LINE_DIR']) / 'log.tsv'
    until(lambda:'\tbusy\t' in logfile.read_text())
    time.sleep(2.2)
    pathlib.Path(holder['LIVE_RELEASE']).touch()
    finish(first); finish(second)
    elapsed=round((time.monotonic()-invoked)*1000)
    summary=json.loads((EVIDENCE / (case+'.json')).read_text())['summary']
    assert elapsed>2200 and summary['duration_ms']<1500
    snapshot(suite,case)
    RESULTS.append(dict(name='wait-dropped-from-budget',result='reproduced',revision='516346af',elapsed_ms=elapsed,reported_ms=summary['duration_ms'],max_wall_ms=1500,exit=0))
    print(json.dumps(RESULTS[-1]),flush=True)

try:
    base=tree('base-commit-repo','20dcbf91520b1816663b81873ad67d0b93b3e4d6')
    previous=tree('before-review-repo','516346af')
    baseline_overlap(base,'runner')
    baseline_overlap(base,'proof')
    old_relative(previous)
    old_budget(previous)
finally:
    for process in PROCESSES:
        if process.poll() is None: os.killpg(process.pid,signal.SIGTERM)
    (EVIDENCE / 'regressions-reproduced.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
