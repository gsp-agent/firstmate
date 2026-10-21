import os,pathlib,subprocess,signal,time,json
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5QFQD3801ZHQ2XDKPQEQ9')
ready=root/'.validation-tmp/before-ready'
ready.unlink(missing_ok=True)
env=os.environ.copy();env.update(FM_VALIDATION_SUITE=str(root/'.validation-tmp/pre-fix-suite.bash'),FM_VALIDATION_READY=str(ready),FM_VALIDATION_MODE='failure',TMPDIR=str(root/'.validation-tmp'),FM_TEST_STUB_MAX_BLOCK_SECONDS='1')
def alive(pid):
    s=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
    return bool(s) and not s.startswith('Z')
with (evidence/'before-fix-driver.log').open('w') as log:
    p=subprocess.Popen(['bash','.validation-tmp/load-wrapper.bash'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    ids={}
    try:
        end=time.monotonic()+25
        while not ready.exists() and p.poll() is None and time.monotonic()<end:time.sleep(.03)
        ids=json.loads(ready.read_text()); code=p.wait(timeout=20)
        time.sleep(1.6)
        row=dict(stub_bound_seconds=1,observed_after_exit_seconds=1.6,commit='fe60494c^',exit=code,pids={k:ids[k] for k in ['node','grant','outcome']},alive_after_suite={k:alive(ids[k]) for k in ['node','grant','outcome']},fixture_removed=not pathlib.Path(ids['home']).exists())
        print(json.dumps(row),flush=True)
        (evidence/'before-fix-reproduction.json').write_text(json.dumps(row,indent=2)+'\n')
    finally:
        try:os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        if p.poll() is None:p.wait()
        for k in ['grant','outcome']:
            if k in ids and alive(ids[k]):os.kill(ids[k],signal.SIGKILL)
