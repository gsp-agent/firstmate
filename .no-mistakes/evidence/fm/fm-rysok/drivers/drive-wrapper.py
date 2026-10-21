import os,pathlib,signal,subprocess,time,json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5QFQD3801ZHQ2XDKPQEQ9')
def alive(pid):
    out=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
    return bool(out) and not out.startswith('Z')
results=[]
for mode,sig in [('normal',None),('failure',None)]+[('linger',s) for s in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP,signal.SIGQUIT]]:
    name=mode if not sig else 'group-'+sig.name
    ready=root/'.validation-tmp'/('wrapper-ready-'+name)
    ready.unlink(missing_ok=True)
    env=os.environ.copy()
    env.update(TMPDIR=str(root/'.validation-tmp'),FM_VALIDATION_MODE=mode,FM_VALIDATION_READY=str(ready))
    with (evidence/f'wrapper-{name}.log').open('w') as log:
        p=subprocess.Popen(['bash','.validation-tmp/load-wrapper.bash'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        ids={}
        try:
            end=time.monotonic()+30
            while not ready.exists() and p.poll() is None and time.monotonic()<end:time.sleep(.02)
            ids=json.loads(ready.read_text())
            before={k:alive(ids[k]) for k in ['node','grant','outcome']}
            if sig:os.killpg(p.pid,sig)
            code=p.wait(timeout=25)
            after={k:alive(ids[k]) for k in ['node','grant','outcome']}
            row=dict(scenario=name,suite_pid=p.pid,pids={k:ids[k] for k in before},alive_before=before,exit=code,alive_after=after,fixture_removed=not pathlib.Path(ids['home']).exists(),result='pass' if all(before.values()) and not any(after.values()) and code==(128+int(sig) if sig else (1 if mode=='failure' else 0)) else 'fail')
            print(json.dumps(row),flush=True);results.append(row)
        finally:
            if p.poll() is None:
                os.killpg(p.pid,signal.SIGTERM)
                try:p.wait(timeout=8)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
            for k in ['node','grant','outcome']:
                if k in ids and alive(ids[k]):os.kill(ids[k],signal.SIGKILL)
(evidence/'wrapper-cleanup.json').write_text(json.dumps(results,indent=2)+'\n')
