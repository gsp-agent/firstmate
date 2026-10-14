#!/usr/bin/env python3
"""Have a real logged-in Codex worker execute the bounded suite workload."""
import json
import os
import pathlib
import runpy
import signal
import subprocess
import time

namespace = runpy.run_path('.live-machine-line/validate.py')
WORK = namespace['WORK']
ROOT = namespace['ROOT']
FIXTURE = namespace['FIXTURE']
EVIDENCE = namespace['EVIDENCE']
LAB = WORK / 'worker-lab-home'
subprocess.run(['bash', str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(LAB)], check=True)
environment = namespace['env_for']('worker', 'worker')
environment.update(FM_TASK_ID='fm-lab-machine-line-worker', FM_HOME=str(LAB),
                   LIVE_RELEASE=str(WORK / 'worker/release'))
command = [str(FIXTURE / 'bin/fm-test-run.sh'), '--jobs', '4', '--json', str(EVIDENCE / 'worker-suite.json')]
command += ['tests/' + name + '.test.sh' for name in namespace['NAMES']]
import shlex
job = WORK / 'worker-job.sh'
job.write_text('#!/usr/bin/env bash\nset -eu\ncd '+shlex.quote(str(FIXTURE))+'\nexec '+' '.join(shlex.quote(part) for part in command)+'\n')
job.chmod(0o755)
prompt = f'''You are a disposable test worker inside an active no-mistakes Test phase.
Your entire task is to execute exactly one prepared shell command: bash {job}
The script runs a bounded Firstmate suite through the installed machine gate in a private disposable lab.
Run it from your shell tool, keep its inherited environment, and wait until it completes.
Do not read project instructions, inspect unrelated state, edit files, run other tests, invoke no-mistakes, or launch another agent.
The supervisor will release the test's workload hold after observing a competing run wait.
After the command completes, return only its exit code in a sentence. Do not substitute a simulated command or report success without running it.
'''
processes = namespace['PROCESSES']
result = {}
try:
    codex = namespace['launch'](['codex', 'exec', '--ignore-user-config', '--ephemeral', '--disable', 'hooks',
                                '-c', 'project_doc_max_bytes=0', '-c', 'approval_policy="never"',
                                '-c', 'model_reasoning_effort="low"', '-c', 'shell_environment_policy.inherit="all"',
                                '-s', 'danger-full-access', '-C', str(ROOT), '--json', '-'],
                               environment, 'codex-worker', input_text=prompt)
    namespace['until'](lambda: any(e['kind']=='enter' and e['tag']=='worker' for e in namespace['events'](environment)), seconds=120)
    assert any(r[1]=='start' and r[2]=='fm-test-run-fm-lab-machine-line-worker' for r in namespace['rows'](environment))
    competitor_environment=namespace['env_for']('worker', 'competing-main')
    competitor=namespace['launch']([str(ROOT / 'bin/fm-test-run.sh'), '--json', str(EVIDENCE / 'worker-competitor.json'), str(FIXTURE / 'tests/single.test.sh')], competitor_environment, 'worker-competitor')
    namespace['until'](lambda: any(r[1]=='busy' and r[2]=='fm-test-run' for r in namespace['rows'](environment)))
    observed=namespace['events'](environment)
    assert not any(e['tag']=='competing-main' for e in observed)
    assert len([e for e in observed if e['kind']=='enter' and e['tag']=='worker'])==4
    pathlib.Path(environment['LIVE_RELEASE']).touch()
    namespace['finish'](competitor)
    namespace['finish'](codex, seconds=120)
    namespace['verify_release'](environment, 2)
    log=namespace['rows'](environment)
    assert [r[1] for r in log if r[1] in ['start','end']]==['start','end','start','end']
    observed=namespace['events'](environment)
    assert max(e['at'] for e in observed if e['tag']=='worker' and e['kind']=='exit') < min(e['at'] for e in observed if e['tag']=='competing-main' and e['kind']=='enter')
    result=dict(result='pass', live=True, worker_name='fm-test-run-fm-lab-machine-line-worker',
                concurrent_worker_workloads=4, competing_overlap=False,
                detail='Real Codex shell command ran the suite, which logged a worker-tagged native gate start/end; competing main suite waited and then entered.')
except Exception as error:
    result=dict(result='fail', live=True, detail=str(error))
finally:
    release=pathlib.Path(environment['LIVE_RELEASE'])
    release.touch()
    for process in processes:
        if process.poll() is None:
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGTERM)
    namespace['snapshot_line'](environment, 'worker')
    (EVIDENCE / 'worker-live-result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)
raise SystemExit(0 if result['result']=='pass' else 1)
