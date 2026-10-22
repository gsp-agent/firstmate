import os,pathlib,subprocess,time
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.gate-live/live3'
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5H65BTPXNAE8EY0SAZPJGPX')
normal_home=os.environ['HOME']
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE'): env.pop(k)
env.update(HOME=str(LAB/'operator-home'),PATH=str(LAB/'bin')+':'+env['PATH'],SHELL='/bin/bash',FM_HOME=str(LAB/'home'),FM_SPAWN_NO_GUARD='1',FM_BACKEND='tmux',TMUX='fm-lab,1,0',TMPDIR=str(ROOT/'.gate-live/tmp'),FM_LIVE_SESSION_CHECK=str(LAB/'detector.py'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,ok=True):
    r=subprocess.run(list(map(str,args)),env=env,text=True,capture_output=True,timeout=90)
    if ok and r.returncode:raise RuntimeError(r.stdout+r.stderr)
    return r
def tm(*a):return run([LAB/'bin/tmux',*a])
lines=[]
def note(s):
    print(s,flush=True);lines.append(s);(EVID/'real-claude-control-refusal.txt').write_text('\n'.join(lines)+'\n')
meta=LAB/'home/state/live-ship.meta'
original=meta.read_text(); data=dict(x.split('=',1) for x in original.splitlines() if '=' in x)
wt=pathlib.Path(data['worktree']); brief=LAB/'home/data/live-ship/brief.md'
try:
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',wt,'/bin/bash --noprofile --norc')
    tm('new-window','-t','primary','-n','fm-live-ship','-c',wt,'-e','HOME='+normal_home,'claude')
    for _ in range(30):
        command=tm('display-message','-p','-t','primary:fm-live-ship','#{pane_current_command}').stdout.strip()
        capture=tm('capture-pane','-p','-t','primary:fm-live-ship').stdout
        if (command=='claude' or command.startswith('2.1.')) and capture.strip():break
        time.sleep(.3)
    note('Actual normal-login Claude CLI, on private 120x40 lab terminal; no prompt or trust answer submitted.\n'+capture)
    assert command=='claude' or command.startswith('2.1.'),command
    cli_command=command
    # Disposable setup: bind the existing lab task to the real CLI now in its endpoint.
    meta.write_text(original.replace('harness=sleep\n','harness=claude\n'))
    before=meta.read_bytes(); beforebrief=brief.read_bytes()
    pane_pid=tm('display-message','-p','-t','primary:fm-live-ship','#{pane_pid}').stdout
    for who in ('ep-agent-config','pm-other-abc'):
        (LAB/'reservation/reserve').write_text(f'start: {int(time.time())-1}\nminutes: 20\nwho: {who}\n')
        r=run([ROOT/'bin/fm-control.sh','live-ship','relaunch','--note','Resume only once the detector clears.'],False)
        note(f'$ fm-control.sh live-ship relaunch --note <note>; reservation={who}\nexit={r.returncode}\n{r.stdout}{r.stderr}')
        assert r.returncode==75
        assert meta.read_bytes()==before
        assert brief.read_bytes()==beforebrief
        assert (wt/'in-progress.txt').read_text()=='Work to preserve during refused relaunch.\n'
        assert tm('display-message','-p','-t','primary:fm-live-ship','#{pane_current_command}').stdout.strip()==cli_command
        assert tm('display-message','-p','-t','primary:fm-live-ship','#{pane_pid}').stdout==pane_pid
        note('Observed: same real Claude process remains; metadata and instructions byte-identical; uncommitted file unchanged.')
finally:
    meta.write_text(original)
    r=run([LAB/'bin/tmux','kill-server'],False)
    note(f'Private lab server and Claude CLI stopped: exit={r.returncode}')
