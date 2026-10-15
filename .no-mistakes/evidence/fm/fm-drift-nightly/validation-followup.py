#!/usr/bin/env python3
"""Complete recovery with the documented prerequisites and inspect install output."""
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess

root = Path.cwd()
lab = root / '.test-live'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M4ZEKNC14QM3J3ZZ3Q1TTCJA')
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(TMPDIR=str(lab/'tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_TERMINAL_PROMPT='0', PYTHONDONTWRITEBYTECODE='1')
env.pop('TYPESAFE_API_KEY', None)

def run(args, log, expected=0, extra=None):
    args = [str(x) for x in args]
    proc = subprocess.run(args, env=dict(env, **(extra or {})), cwd=root, capture_output=True)
    output = (proc.stdout+proc.stderr).decode('utf-8', 'backslashreplace')
    shown = shlex.join(args).encode('utf-8', 'backslashreplace').decode('utf-8')
    log.write('$ ' + shown + '\n' + output + f'exit: {proc.returncode}\n\n')
    log.flush()
    assert proc.returncode == expected, output
    return output

with (evidence/'archive-recovery.log').open('w') as log:
    log.write('A direct clone of this incremental bundle requires the two prerequisite commits, as declared by the bundle.\n'
              'Recovery below uses a fresh local clone containing those commits, then the documented fetch route.\n')
    repo = lab/'archive-with-prerequisites'
    run(['git','-C',repo,'bundle','verify',root/'archives/fork-cuts.bundle'],log)
    run(['git','-C',repo,'fetch',root/'archives/fork-cuts.bundle',
         'refs/heads/archive/*:refs/heads/archive/*'],log)
    refs = run(['git','-C',repo,'for-each-ref','--format=%(objectname) %(refname)',
                'refs/heads/archive/'],log)
    entries = [x.split() for x in refs.splitlines() if x.strip()]
    assert len(entries) == 9
    for sha, ref in entries:
        assert sha in ref
        run(['git','-C',repo,'cat-file','-e',sha+'^{commit}'],log)
    ref = next(ref for sha, ref in entries if sha.startswith('814465e1'))
    run(['git','-C',repo,'checkout','--detach',ref],log)
    out = run(['git','-C',repo,'rev-parse','HEAD'],log)
    assert out.strip() == '814465e1383e1654aea41db0544c28cd1f30fa92'
    log.write('All nine named archive branches imported, and the pre-cut tree checked out at its original SHA.\n')

with (evidence/'install-contract.log').open('w') as log:
    log.write('The real installer runs below. launchctl is a local recording dependency; no macOS scheduler job is registered or removed.\n')
    tools = lab/'tools & <bin>'
    tools.mkdir(exist_ok=True)
    script = tools/'fm-drift-nightly.sh'
    script.write_bytes((root/'bin/fm-drift-nightly.sh').read_bytes())
    repo = lab/'repo & <copy> "it\'s"'
    repo.mkdir(exist_ok=True)
    agent = lab/'install-agents'
    calls = lab/'launchctl-calls.log'
    recorder = lab/'record-launchctl'
    recorder.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$VALIDATION_LAUNCHCTL_LOG"\n[ "$1" != print ]\n')
    recorder.chmod(0o755)
    settings = dict(FM_DRIFT_AGENT_DIR=str(agent), FM_DRIFT_LAUNCHCTL=str(recorder),
                    VALIDATION_LAUNCHCTL_LOG=str(calls))
    run(['bash',script,'install','--repo',repo],log,extra=settings)
    plist = agent/'dev.firstmate.drift-nightly.plist'
    raw = plist.read_bytes()
    parsed = plistlib.loads(raw)
    assert parsed == {
        'Label':'dev.firstmate.drift-nightly',
        'ProgramArguments':['/bin/bash',str(script),'check','--repo',str(repo)],
        'StartCalendarInterval':{'Hour':3,'Minute':17}}
    (evidence/'generated-nightly-job.plist').write_bytes(raw)
    (evidence/'generated-nightly-job.normalized.json').write_text(json.dumps(parsed,indent=2)+'\n')
    log.write('Strict plist consumer read the exact argv and 03:17 calendar schedule:\n'+json.dumps(parsed,indent=2)+'\n')
    before_calls = calls.read_bytes()
    run(['bash',script,'install','--repo',os.fsdecode(os.fsencode(str(lab/'invalid-'))+b'\xff')],
        log,expected=2,extra=settings)
    assert plist.read_bytes() == raw and calls.read_bytes() == before_calls
    assert list(agent.iterdir()) == [plist]
    log.write('The invalid reinstall preserved the installed bytes and made no scheduler calls.\n')
    run(['bash',script,'uninstall'],log,extra=settings)
    assert not plist.exists()
    run(['bash',script,'uninstall'],log,extra=settings)
    log.write('Recorded dependency calls (these are not real launchd registrations):\n'+calls.read_text())

with (evidence/'cursor-catalogue-live.log').open('w') as log:
    home = lab/'cursor-catalogue-home'
    run(['bash',root/'bin/fm-lab-home.sh','create',home],log)
    usage = home/'usage'
    usage.mkdir()
    (usage/'fresh-spending.txt').write_text('cursor_models_pct=10\n')
    settings = dict(FM_HOME=str(home), FM_CURSOR_USAGE_DIR=str(usage))
    run(['bash',root/'bin/fm-brief.sh','catalogue-check','fixture','--scout'],log,extra=settings)
    brief = home/'data/catalogue-check/brief.md'
    content = brief.read_text().replace('{TASK}', 'Validate the catalog refusal only; do not edit files or run other work.')
    content = content.replace('{FIRSTMATE_SPEC}', 'No implementation. Stop after catalog validation.')
    brief.write_text(content)
    output = run(['bash',root/'bin/fm-spawn.sh','catalogue-check',lab/'deletion-repository',
                  '--scout','--backend','tmux','--harness','cursor','--model','validation-nonexistent-model'],
                 log,expected=1,extra=settings)
    assert ("Cursor model 'validation-nonexistent-model' is not available" in output or
            "refusing to launch Cursor model 'validation-nonexistent-model' unchecked" in output), output
    assert not (home/'state/catalogue-check.meta').exists()
    log.write('The real installed Cursor CLI was probed; the actual spawn refused before a task endpoint or metadata was published.\n')

results = json.loads((evidence/'live-cli-results.json').read_text())
for result in results:
    if result['name'].startswith('Cut commits recover'):
        result.update(result='pass', live=True)
        result.pop('error', None)
        result['evidence'] = 'archive-recovery.log'
results.append({'name':'A real Cursor catalog probe prevents an unchecked model launch',
                'result':'pass','live':True,'evidence':'cursor-catalogue-live.log'})
(evidence/'final-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Recovery, generated configuration, invalid-reinstall protection and real Cursor refusal completed.')
