import json,os,pathlib,signal,subprocess,time
R=pathlib.Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW')
E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW')
D=R/'.gate-test-phase/runner-live';D.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','GIT_'))}
env.update(HOME=str(R/'.gate-test-phase/user-home'),TMPDIR=str(R/'.gate-test-phase/scratch'),FM_TEST_MACHINE_GATE='',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
results={}
def fixture(name,body):
    p=D/name;p.write_text('#!/usr/bin/env bash\n'+body);p.chmod(0o755);return p
def alive(pid):
    r=subprocess.run(['ps','-p',str(pid),'-o','stat='],text=True,capture_output=True)
    return bool(r.stdout.strip()) and not r.stdout.lstrip().startswith('Z')
script=fixture('padded.test.sh','echo "fixture: completed and returning its own exit 7"\nexit 7\n')
p=subprocess.run(['bash','bin/fm-test-run.sh','--per-script-timeout-secs','0600',str(script)],cwd=R,env=env,text=True,capture_output=True)
(E/'live-runner-padded.stdout.txt').write_text(p.stdout);(E/'live-runner-padded.stderr.txt').write_text(p.stderr)
print('$ bash bin/fm-test-run.sh --per-script-timeout-secs 0600 '+str(script),flush=True)
print(p.stdout,end='',flush=True)
assert p.returncode==1 and ' exit=7 ' in p.stdout and ' exit=125 ' not in p.stdout
results['padded_bound']={'runner_exit':p.returncode,'script_exit':7,'bound':'0600'}
first=fixture('running.test.sh',"""trap 'echo "fixture: graceful TERM cleanup"; exit 143' TERM
sleep 600 &
printf '%s %s\n' "$$" "$!" > "$OWNED_PIDS"
wait
""")
later=fixture('later.test.sh','echo "BUG: later script started"\ntouch "$LATER_STARTED"\n')
env.update(OWNED_PIDS=str(D/'owned.pids'),LATER_STARTED=str(D/'later.started'))
with (E/'live-runner-killed.stdout.txt').open('w') as out, (E/'live-runner-killed.stderr.txt').open('w') as err:
    p=subprocess.Popen(['bash','bin/fm-test-run.sh','--jobs','1',str(first),str(later)],cwd=R,env=env,stdout=out,stderr=err,text=True,start_new_session=True)
    pids=[]
    try:
        end=time.monotonic()+30
        while time.monotonic()<end and not (D/'owned.pids').exists():time.sleep(.1)
        pids=[int(x) for x in (D/'owned.pids').read_text().split()]
        print('sending SIGKILL to runner process group '+str(p.pid)+'; running fixture PIDs '+str(pids),flush=True)
        os.killpg(p.pid,signal.SIGKILL);rc=p.wait(timeout=15)
        end=time.monotonic()+15
        while time.monotonic()<end and any(alive(pid) for pid in pids):time.sleep(.1)
        survivors=[pid for pid in pids if alive(pid)]
        assert not survivors,survivors
        assert not (D/'later.started').exists()
        output=(E/'live-runner-killed.stdout.txt').read_text()
        assert output.count('FM_TEST_BEGIN ')==1,output
        assert 'fixture: graceful TERM cleanup' in output,output
        results['runner_group_sigkill']={'runner_exit':rc,'owned_fixture_pids':pids,'survivors':survivors,'later_started':False,'begin_markers':output.count('FM_TEST_BEGIN '),'cleanup_output':'fixture: graceful TERM cleanup'}
        print(json.dumps(results['runner_group_sigkill'],sort_keys=True),flush=True)
        print(output,end='',flush=True)
    finally:
        if p.poll() is None:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=15)
        for pid in pids:
            if alive(pid):os.kill(pid,signal.SIGKILL)
(E/'live-runner-results.json').write_text(json.dumps(results,indent=2)+'\n')
