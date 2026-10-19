import json, os, pathlib, re, signal, subprocess, time
ROOT=pathlib.Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW')
E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW')
LAB=ROOT/'l'
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) and k not in ('STATE','DATA','CONFIG','PROJECTS','TMUX','CLAUDE_CONFIG_DIR')}
base.update(HOME=str(ROOT/'.gate-test-phase/user-home'),TMPDIR=str(ROOT/'.gate-test-phase/scratch'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',CLAUDE_CONFIG_DIR='')
tracked=[]; handles=[]; results={}
def run(args,env=base,**kw):
    return subprocess.run([str(x) for x in args],env=env,cwd=ROOT,text=True,check=True,**kw)
def text(path):
    try: return path.read_text()
    except FileNotFoundError: return ''
def eventually(fn,timeout=35):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        v=fn()
        if v: return v
        time.sleep(.1)
    raise AssertionError('Timed out: '+str(fn))
def start(args,env,label):
    out=(E/(label+'.stdout.txt')).open('w'); err=(E/(label+'.stderr.txt')).open('w'); handles.extend([out,err])
    p=subprocess.Popen([str(x) for x in args],env=env,cwd=ROOT,stdout=out,stderr=err,start_new_session=True,text=True)
    tracked.append(p); return p
def home_env(home):
    e=base.copy();e.update(FM_HOME=str(home),FM_BACKEND='tmux',TMUX=tmux_context,FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999',FM_SECONDMATE_LIVENESS_SECS='99999999',FM_HOME_SUMMARY_INTERVAL='9999999',FM_HOME_SUMMARY_TIMEOUT='1')
    return e
def report(label,data):
    results[label]=data; print(label+': '+json.dumps(data,sort_keys=True),flush=True)
try:
    run(['bash','bin/fm-lab-home.sh','create',LAB],stdout=subprocess.PIPE)
    (LAB/'t').mkdir()
    tmuxenv=base.copy();tmuxenv['TMUX_TMPDIR']=str(LAB/'t')
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','fm-lab-validation','-x','120','-y','40','-c',ROOT,'/bin/sleep','300'],env=tmuxenv)
    tmux_context=run(['tmux','-L','fm-lab','display-message','-p','-t','fm-lab-validation','#{socket_path},#{pid},0'],env=tmuxenv,stdout=subprocess.PIPE).stdout.strip()
    report('private_tmux',{'session':'fm-lab-validation','context':tmux_context,'grid':'120x40'})
    home=LAB/'basic';run(['bash','bin/fm-lab-home.sh','create',home],stdout=subprocess.PIPE); env=home_env(home)
    p=start(['bash','bin/fm-watch.sh'],env,'live-basic')
    beat=home/'state/.last-watcher-beat'
    eventually(lambda:beat.exists())
    first=beat.stat().st_mtime_ns
    eventually(lambda:beat.stat().st_mtime_ns>first)
    second=beat.stat().st_mtime_ns
    eventually(lambda:beat.stat().st_mtime_ns>second)
    assert p.poll() is None
    assert not (home/'state/.last-check').exists()
    assert not (home/'state/home-summary.json').exists()
    process_lines=run(['ps','-axo','pid=,ppid=,command='],stdout=subprocess.PIPE).stdout.splitlines()
    fanout=[line for line in process_lines if str(ROOT)+'/bin/fm-' in line and any(n in line for n in ('fm-home-summary','fm-fleet-snapshot'))]
    # No other command in this driver requests a summary during the idle poll window.
    assert not fanout,fanout
    report('idle_polls',{'watcher_pid':p.pid,'beacon_first_ns':first,'beacon_second_ns':second,'last_check':'absent','summary':'absent','summary_processes':fanout})
    (home/'state/manual.status').write_text('done: isolated live watcher check complete\n')
    assert p.wait(timeout=35)==0
    out=text(E/'live-basic.stdout.txt');queue=text(home/'state/.wake-queue')
    assert 'signal: ' in out and 'manual.status' in out and 'done: isolated live watcher check complete' in queue,(out,queue)
    report('actionable_status',{'stdout':out.strip(),'queue':queue.strip(),'exit':p.returncode})
    home=LAB/'takeover';run(['bash','bin/fm-lab-home.sh','create',home],stdout=subprocess.PIPE);env=home_env(home)
    run(['bash',E/'init-recovery.sh',ROOT],env=env)
    original_marker=text(home/'state/.watcher-down')
    fakebin=home/'slow-clock-bin';fakebin.mkdir()
    (fakebin/'date').write_text("""#!/usr/bin/env bash
if [ -f "$FM_LAB_CLOCK_DIR/enable" ] && [ ! -e "$FM_HOME/state/.watch.lock/pid" ] && mkdir "$FM_LAB_CLOCK_DIR/claimed" 2>/dev/null; then
  /bin/date +%s > "$FM_LAB_CLOCK_DIR/entered"
  /bin/sleep 2.5
fi
exec /bin/date "$@"
""")
    (fakebin/'date').chmod(0o755)
    ownerenv=env.copy();ownerenv.update(PATH=str(fakebin)+os.pathsep+base['PATH'],FM_LAB_CLOCK_DIR=str(fakebin))
    owner=start(['bash','bin/fm-watch-arm.sh'],ownerenv,'live-takeover-owner')
    eventually(lambda:'watcher: started' in text(E/'live-takeover-owner.stdout.txt'))
    old_watcher=int(text(home/'state/.watch.lock/pid').strip())
    (fakebin/'enable').touch()
    successor=start(['bash','bin/fm-watch-arm.sh','--take-over',str(owner.pid)],env,'live-takeover-successor')
    eventually(lambda:(fakebin/'entered').exists())
    start_delay=time.monotonic()
    eventually(lambda:'watcher: started' in text(E/'live-takeover-successor.stdout.txt'))
    delay_elapsed=time.monotonic()-start_delay
    new_watcher=int(text(home/'state/.watch.lock/pid').strip())
    marker=text(home/'state/.watcher-down');ledger=text(home/'state/.watch-cycle-exits.log')
    assert new_watcher!=old_watcher
    assert marker==original_marker,(original_marker,marker,ledger)
    assert 'reason=taken-over\t' in ledger and 'taken-over-unconfirmed-stop' not in ledger,ledger
    assert not text(home/'state/.wake-queue').strip()
    assert successor.poll() is None
    report('delayed_exit_record_takeover',{'old_arm':owner.pid,'old_watcher':old_watcher,'new_arm':successor.pid,'new_watcher':new_watcher,'injected_clock_delay_seconds':2.5,'waited_after_delay_started_seconds':round(delay_elapsed,2),'original_marker':original_marker.strip(),'restored_marker':marker.strip(),'queue':'empty','ledger':ledger.strip(),'owner_exit':owner.wait(timeout=15)})
    (home/'state/manual.status').write_text('done: takeover delivers the next real close\n')
    assert successor.wait(timeout=35)==0
    out=text(E/'live-takeover-successor.stdout.txt');queue=text(home/'state/.wake-queue')
    assert 'signal:' in out and 'manual.status' in out and 'done: takeover delivers the next real close' in queue,(out,queue)
    report('takeover_next_close',{'stdout':out.strip(),'queue':queue.strip(),'exit':successor.returncode})
finally:
    for p in reversed(tracked):
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=5)
    if 'tmuxenv' in globals():
        subprocess.run(['tmux','-L','fm-lab','kill-server'],env=tmuxenv,cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for handle in handles:handle.close()
    (E/'live-watcher-results.json').write_text(json.dumps(results,indent=2)+'\n')
