import json, os, pathlib, re, signal, subprocess, time
ROOT=pathlib.Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59Q21RQJTZ7ZCDK9K96MRAW')
E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M59Q21RQJTZ7ZCDK9K96MRAW')
LAB=ROOT/'n'
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
    owner=start(['bash',ROOT/'.gate-test-phase/before/bin/fm-watch-arm.sh'],ownerenv,'live-takeover-owner-before')
    eventually(lambda:'watcher: started' in text(E/'live-takeover-owner-before.stdout.txt'))
    old_watcher=int(text(home/'state/.watch.lock/pid').strip())
    (fakebin/'enable').touch()
    successor=start(['bash',ROOT/'.gate-test-phase/before/bin/fm-watch-arm.sh','--take-over',str(owner.pid)],env,'live-takeover-successor-before')
    eventually(lambda:(fakebin/'entered').exists())
    start_delay=time.monotonic()
    successor.wait(timeout=35)
    out=text(E/'live-takeover-successor-before.stdout.txt')
    ledger=text(home/'state/.watch-cycle-exits.log')
    marker=text(home/'state/.watcher-down')
    assert 'taken-over-unconfirmed-stop' in ledger,ledger
    assert 'check: rearm-resurface' in out,out
    assert marker!=original_marker
    report('before_fix_spurious_recovery',{'injected_clock_delay_seconds':2.5,'stdout':out.strip(),'old_marker':original_marker.strip(),'marker_after':marker.strip(),'ledger':ledger.strip(),'exit':successor.returncode})

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
    (E/'takeover-before-results.json').write_text(json.dumps(results,indent=2)+'\n')
