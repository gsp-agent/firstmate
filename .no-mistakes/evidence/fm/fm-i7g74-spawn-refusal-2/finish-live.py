import pathlib, os, subprocess, json, time, shutil
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.gate-live/live3'
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5H65BTPXNAE8EY0SAZPJGPX')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE'): env.pop(k)
env.update(HOME=str(LAB/'operator-home'),PATH=str(LAB/'bin')+':'+env['PATH'],SHELL='/bin/bash',FM_HOME=str(LAB/'home'),FM_SPAWN_NO_GUARD='1',FM_BACKEND='tmux',TMUX='fm-lab,1,0',TREEHOUSE_ROOT=str(LAB/'pool'),TMPDIR=str(ROOT/'.gate-live/tmp'),FM_LIVE_SESSION_CHECK=str(LAB/'detector.py'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
out=[]
def run(args,ok=True):
    r=subprocess.run(list(map(str,args)),env=env,text=True,capture_output=True,timeout=120)
    if ok and r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r
def tm(*a):return run([LAB/'bin/tmux',*a])
def note(s):
    print(s,flush=True);out.append(s);(EVID/'live-preservation-and-late-signal.txt').write_text('\n'.join(out)+'\n')
def reserve(who): (LAB/'reservation/reserve').write_text(f'start: {int(time.time())-1}\nminutes: 20\nwho: {who}\n')
meta=LAB/'home/state/live-ship.meta'
data=dict(x.split('=',1) for x in meta.read_text().splitlines() if '=' in x)
wt=pathlib.Path(data['worktree']); before=meta.read_bytes()
brief=LAB/'home/data/live-ship/brief.md'; beforebrief=brief.read_bytes()
try:
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',wt,'/bin/bash --noprofile --norc')
    tm('new-window','-t','primary','-n','fm-live-ship','-c',wt,'/bin/bash --noprofile --norc')
    tm('send-keys','-t','primary:fm-live-ship','/bin/sleep 600','Enter')
    time.sleep(.4)
    assert tm('display-message','-p','-t','primary:fm-live-ship','#{pane_current_command}').stdout.strip()=='sleep'
    tm('send-keys','-t','primary:fm-live-ship','C-c')
    time.sleep(.4)
    assert tm('display-message','-p','-t','primary:fm-live-ship','#{pane_current_command}').stdout.strip()=='bash'
    for who in ('ep-agent-config','pm-other-abc'):
        reserve(who)
        r=run([ROOT/'bin/fm-spawn.sh','live-ship','--relaunch','--harness','codex'],False)
        note(f'$ fm-spawn.sh live-ship --relaunch; stopped endpoint; reservation={who}\nexit={r.returncode}\n{r.stdout}{r.stderr}')
        assert r.returncode==75
        assert meta.read_bytes()==before
        assert brief.read_bytes()==beforebrief
        assert (wt/'in-progress.txt').read_text()=='Work to preserve during refused relaunch.\n'
        assert tm('display-message','-p','-t','primary:fm-live-ship','#{pane_current_command}').stdout.strip()=='bash'
        note('Observed: stopped endpoint remains bash; instructions, metadata and uncommitted work preserved.')
    reserve('pm-other-abc')
    realtree=shutil.which('treehouse')
    (LAB/'bin/treehouse').write_text(f'#!/bin/sh\nif [ "$1" = get ]; then\n  printf "start: %s\\nminutes: 20\\nwho: ep-agent-config\\n" "$(date +%s)" > "{LAB}/reservation/reserve"\nfi\nexec "{realtree}" "$@"\n')
    (LAB/'bin/treehouse').chmod(0o755)
    run(['tasks-axi','add','late-live','Live signal arrives during preparation','--kind','ship','--file',LAB/'home/data/backlog.md'])
    d=LAB/'home/data/late-live';d.mkdir()
    (d/'brief.md').write_text("# Task\n## Captain's intent\nExercise isolated late-signal refusal.\n\n## Firstmate spec\nRemain idle.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n")
    r=run([ROOT/'bin/fm-spawn.sh','late-live',LAB/'agent-config','--mode','no-mistakes','--yolo','off','/bin/sleep 600'],False)
    note(f'$ fm-spawn.sh late-live agent-config --mode no-mistakes --yolo off "/bin/sleep 600"\nexit={r.returncode}\n{r.stdout}{r.stderr}')
    assert r.returncode==75
    assert 'live signal=machine-line-reservation' in r.stderr+r.stdout
    assert not (LAB/'home/state/late-live.meta').exists()
    assert 'fm-late-live' not in tm('list-windows','-t','primary','-F','#{window_name}').stdout
    row=run(['tasks-axi','show','late-live','--file',LAB/'home/data/backlog.md']).stdout
    assert 'state: queued' in row
    note('Observed: the reservation became live when real Treehouse acquisition began; final detector read refused dispatch, left no task endpoint or metadata, and kept the row queued.')
finally:
    r=run([LAB/'bin/tmux','kill-server'],False)
    note(f'Private lab server stopped: exit={r.returncode}')
