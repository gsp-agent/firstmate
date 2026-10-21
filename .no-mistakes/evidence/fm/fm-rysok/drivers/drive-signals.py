import os, pathlib, signal, subprocess, time, json
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5F5QFQD3801ZHQ2XDKPQEQ9')
results=[]
def alive(pid):
    p = subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return bool(p.stdout.strip()) and not p.stdout.strip().startswith('Z')
for sig in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT]:
    ready=root/'.validation-tmp'/f'ready-{sig.name}'
    env=os.environ.copy()
    env.update(TMPDIR=str(root/'.validation-tmp'), FM_VALIDATION_READY=str(ready))
    with (evidence/f'sibling-{sig.name}.log').open('w') as log:
        p=subprocess.Popen(['bash','.validation-tmp/signal-launch.bash'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            deadline=time.monotonic()+100
            while not ready.exists() and p.poll() is None and time.monotonic()<deadline:
                time.sleep(.05)
            if not ready.exists():
                raise RuntimeError(f'{sig.name}: sibling not reached, suite exit {p.poll()}')
            suite,child=map(int,ready.read_text().split())
            was_alive=alive(child)
            os.kill(suite,sig)
            os.kill(suite,signal.SIGCONT)
            code=p.wait(timeout=30)
            remains=alive(child)
            row=dict(signal=sig.name,suite_pid=suite,sibling_pid=child,sibling_alive_before_signal=was_alive,exit=code,sibling_alive_after_suite=remains,result='pass' if was_alive and not remains and code==128+int(sig) else 'fail')
            results.append(row)
            print(json.dumps(row),flush=True)
        finally:
            if p.poll() is None:
                os.killpg(p.pid,signal.SIGCONT)
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=8)
                except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
(evidence/'sibling-signals.json').write_text(json.dumps(results,indent=2)+'\n')
