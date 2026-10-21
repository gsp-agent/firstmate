import os, pathlib, subprocess, time, json, shutil
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5QFQD3801ZHQ2XDKPQEQ9')
scratch = root / '.test-rysok-live'
scratch.mkdir(exist_ok=True)
(scratch/'suite').mkdir(exist_ok=True)
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key)
env['TMPDIR'] = str(scratch/'suite')
env['FM_HOME'] = str(scratch/'suite'/'unused-home')
env['FM_RUNTIME_BACKEND'] = 'tmux'
env['FM_PI_PACKAGE_DIR'] = str(scratch/'pi/lib/node_modules/@earendil-works/pi-coding-agent')
def processes():
    rows = subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,comm='],text=True).splitlines()
    tagged = []
    for row in rows:
        parts = row.strip().split(None,3)
        if len(parts) != 4: continue
        pid,ppid,pgid,comm = parts
        if not any(x in comm for x in ('bash','sh','node','perl','sleep')): continue
        result = subprocess.run(['ps','eww','-p',pid,'-o','command='],capture_output=True,text=True)
        if 'FM_TEST_SEAM=1' in result.stdout:
            tagged.append(dict(pid=int(pid),ppid=int(ppid),pgid=int(pgid),executable=comm,owned=str(scratch) in result.stdout))
    return tagged
before=processes()
(evidence/'pi-process-baseline.json').write_text(json.dumps(before,indent=2)+'\n')
start=time.monotonic()
with (evidence/'pi-suite.log').open('w') as out:
    proc=subprocess.Popen(['bin/fm-test-run.sh','tests/fm-pi-branch-extension.test.sh','--per-script-timeout-secs','900'],stdout=out,stderr=subprocess.STDOUT,env=env,start_new_session=True)
    print(json.dumps(dict(event='started',runner_pid=proc.pid,baseline=before)),flush=True)
    code=proc.wait()
after=processes()
summary=dict(command='bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh --per-script-timeout-secs 900',exit_code=code,elapsed_seconds=round(time.monotonic()-start,2),baseline=before,after=after)
(evidence/'pi-suite-result.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary),flush=True)
if not any(p['owned'] for p in after):
    shutil.rmtree(scratch/'suite')
