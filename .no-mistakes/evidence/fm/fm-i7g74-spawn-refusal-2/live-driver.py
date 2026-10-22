import os, pathlib, subprocess, json, time, shutil, sys

ROOT = pathlib.Path.cwd()
BASE = ROOT / '.gate-live'
LAB = BASE / 'live3'
EVID = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5H65BTPXNAE8EY0SAZPJGPX')
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_')) or key in ('TMUX','TMUX_PANE','CLAUDECODE'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
lines=(EVID/'live-spawn-transcript.txt').read_text().splitlines() if (EVID/'live-spawn-transcript.txt').exists() else []
def call(args, *, ok=True, cwd=ROOT, environ=None, timeout=120):
    r=subprocess.run(list(map(str,args)), cwd=cwd, env=environ or env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if ok and r.returncode: raise RuntimeError(f'{args}: exit {r.returncode}: {r.stdout}')
    return r
def note(s):
    print(s, flush=True); lines.append(s)
    (EVID/'live-spawn-transcript.txt').write_text('\n'.join(lines)+'\n')
def tm(*args, ok=True): return call([str(LAB/'bin/tmux'),*args],ok=ok)
def setup():
    call([ROOT/'bin/fm-lab-home.sh','create',LAB/'home'])
    for d in ('bin','detector-bin','operator-home','reservation','tmux','pool'):
        (LAB/d).mkdir(parents=True,exist_ok=True)
    realtm=shutil.which('tmux')
    (LAB/'bin/tmux').write_text(f'#!/bin/sh\ncd "{LAB}/tmux" || exit 1\nexec "{realtm}" -S fm-lab.sock "$@"\n')
    (LAB/'bin/tmux').chmod(0o755)
    shutil.copyfile('/Users/dalecarman/.agent-config/scripts/live-session.py', LAB/'outside-detector.py')
    (LAB/'detector.py').write_text('import os,sys,subprocess,json,time\n'
        f'root={str(LAB)!r}\n'
        'e=os.environ.copy()\ne.update(HOME=root+"/operator-home",PATH=root+"/detector-bin",MACHINE_LINE_DIR=root+"/reservation")\n'
        'r=subprocess.run([sys.executable,root+"/outside-detector.py",sys.argv[1]],env=e,text=True,capture_output=True)\n'
        'with open(root+"/detector-calls.jsonl","a") as f: f.write(json.dumps({"folder":sys.argv[1],"exit":r.returncode,"stdout":r.stdout,"time":time.time()})+"\\n")\n'
        'print(r.stdout,end="")\nsys.exit(r.returncode)\n')
    env.update(HOME=str(LAB/'operator-home'), PATH=str(LAB/'bin')+':'+env['PATH'], SHELL='/bin/bash',
        FM_HOME=str(LAB/'home'), FM_SPAWN_NO_GUARD='1', FM_BACKEND='tmux',
        TREEHOUSE_ROOT=str(LAB/'pool'), TMPDIR=str(BASE/'tmp'), FM_LIVE_SESSION_CHECK=str(LAB/'detector.py'))
    project=LAB/'.agent-config'
    project.mkdir()
    call(['git','init','-q',project])
    (project/'README.md').write_text('Disposable live-session validation project.\n')
    (project/'treehouse.toml').write_text('max_trees = 8\n')
    call(['git','-C',project,'add','README.md','treehouse.toml'])
    call(['git','-C',project,'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-qm','initial'])
    call(['git','clone','--bare','-q',project,LAB/'origin.git'])
    call(['git','-C',project,'remote','add','origin',LAB/'origin.git'])
    (LAB/'agent-config').symlink_to(project, target_is_directory=True)
    home=LAB/'home'
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',project,'/bin/bash --noprofile --norc')
    env['TMUX']='fm-lab,1,0'
    note('Isolation: marked disposable FM_HOME; real tmux on a private 120x40 fm-lab socket; real Git, Treehouse and tasks-axi. All project data inside this worktree.')
    note('Outside detector: byte-for-byte copy of installed agent-config live-session.py, invoked by Python with private HOME/PATH and a real lab reservation file. Unavailable external sources cannot access operator credentials or fleet data.')
    return project
def reserve(who):
    (LAB/'reservation/reserve').write_text(f'start: {int(time.time())-1}\nminutes: 20\nwho: {who}\n')
def add(id,kind='ship'):
    h=LAB/'home'
    call(['tasks-axi','add',id,'Live validation '+id,'--kind',kind,'--file',h/'data/backlog.md'])
    d=h/'data'/id; d.mkdir()
    (d/'brief.md').write_text("# Task\n## Captain's intent\nExercise isolated live-session admission.\n\n## Firstmate spec\nRemain idle; do not touch external services.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n")
def spawn(id,kind='ship',detector=None):
    args=[ROOT/'bin/fm-spawn.sh',id,LAB/'agent-config']
    args+=['--scout'] if kind=='scout' else ['--mode','no-mistakes','--yolo','off']
    # Raw launch is an existing public interface, using a real shell process.
    args+=['/bin/sleep 600']
    e=env.copy()
    if detector is not None: e['FM_LIVE_SESSION_CHECK']=detector
    r=call(args,ok=False,environ=e)
    note(f'$ fm-spawn.sh {id} agent-config '+(' --scout' if kind=='scout' else '--mode no-mistakes --yolo off')+f' "/bin/sleep 600"\nexit={r.returncode}\n{r.stdout}')
    return r
def state(id):
    r=call(['tasks-axi','show',id,'--file',LAB/'home/data/backlog.md'])
    return next((x.strip() for x in r.stdout.splitlines() if x.strip().startswith('state:')),r.stdout)
def assert_refused(id,r):
    assert r.returncode==75,r.stdout
    assert not (LAB/f'home/state/{id}.meta').exists(),'provisional metadata survived'
    windows=tm('list-windows','-t','primary','-F','#{window_name}').stdout
    assert f'fm-{id}' not in windows,windows
    assert state(id)=='state: queued',state(id)
    note(f'Observed {id}: {state(id)}; task metadata absent; newly prepared endpoint absent. Surviving windows: {windows.strip()}')
def run():
    setup()
    reserve('ep-agent-config')
    add('live-ship'); r=spawn('live-ship'); assert_refused('live-ship',r)
    assert 'folder .agent-config: live signal=machine-line-reservation' in r.stdout,r.stdout
    reserve('pm-other-abc')
    add('unknown-scout','scout'); r=spawn('unknown-scout','scout'); assert_refused('unknown-scout',r)
    assert 'cannot tell' in r.stdout,r.stdout
    reserve('ep-agent-config')
    add('live-scout','scout'); r=spawn('live-scout','scout'); assert_refused('live-scout',r)
    run_tail()
def run_tail():
    reserve('ep-agent-config')
    r=call([ROOT/'bin/fm-spawn.sh',f'live-batch={LAB}/agent-config','--mode','no-mistakes','--yolo','off','--harness','/bin/sleep 600'],ok=False)
    note('$ fm-spawn.sh live-batch=agent-config --mode no-mistakes --yolo off "/bin/sleep 600"\n'+f'exit={r.returncode}\n{r.stdout}')
    assert_refused('live-batch',r)
    assert 'batch: DEFERRED live-batch' in r.stdout
    # Drive the existing raw-launch interface without any detector installed.
    r=spawn('live-ship',detector=str(LAB/'missing-detector.py'))
    assert r.returncode==0,r.stdout
    assert state('live-ship')=='state: in_flight',state('live-ship')
    meta=LAB/'home/state/live-ship.meta'
    data=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
    current=tm('display-message','-p','-t',data['window'],'#{pane_current_command}').stdout.strip()
    assert current=='sleep',current
    note('Retry with no installed detector: '+state('live-ship')+'; actual private-pane foreground command='+current)
    before=meta.read_bytes()
    wt=pathlib.Path(data['worktree'])
    (wt/'in-progress.txt').write_text('Work to preserve during refused relaunch.\n')
    beforebrief=(LAB/'home/data/live-ship/brief.md').read_bytes()
    for who in ('ep-agent-config','pm-other-abc'):
        reserve(who)
        r=call([ROOT/'bin/fm-spawn.sh','live-ship','--relaunch'],ok=False)
        note(f'$ fm-spawn.sh live-ship --relaunch (reservation owner {who})\nexit={r.returncode}\n{r.stdout}')
        assert r.returncode==75,r.stdout
        assert meta.read_bytes()==before
        assert (wt/'in-progress.txt').read_text()=='Work to preserve during refused relaunch.\n'
        assert (LAB/'home/data/live-ship/brief.md').read_bytes()==beforebrief
        assert tm('display-message','-p','-t',data['window'],'#{pane_current_command}').stdout.strip()=='sleep'
        note('Refused relaunch preserved task record, instructions, uncommitted work and existing sleep process.')
    # A real filesystem observation occurs after endpoint preparation begins.
    reserve('pm-other-abc')
    realtree=shutil.which('treehouse')
    (LAB/'bin/treehouse').write_text(f'#!/bin/sh\nif [ "$1" = get ]; then\n  printf "start: %s\\nminutes: 20\\nwho: ep-agent-config\\n" "$(date +%s)" > "{LAB}/reservation/reserve"\nfi\nexec "{realtree}" "$@"\n')
    (LAB/'bin/treehouse').chmod(0o755)
    add('late-live')
    r=spawn('late-live'); assert_refused('late-live',r)
    assert 'live signal=machine-line-reservation' in r.stdout,r.stdout
    note('Late reservation was created by the real Treehouse get transport during preparation; final detector read deferred dispatch.')
    note('Detector invocations (public exit protocol):\n'+(LAB/'detector-calls.jsonl').read_text())

if __name__ != '__main__':
    raise SystemExit

try:
    if LAB.exists():
        env.update(HOME=str(LAB/'operator-home'), PATH=str(LAB/'bin')+':'+env['PATH'], SHELL='/bin/bash',
            FM_HOME=str(LAB/'home'), FM_SPAWN_NO_GUARD='1', FM_BACKEND='tmux', TMUX='fm-lab,1,0',
            TREEHOUSE_ROOT=str(LAB/'pool'), TMPDIR=str(BASE/'tmp'), FM_LIVE_SESSION_CHECK=str(LAB/'detector.py'))
        tm('new-session','-d','-s','primary','-x','120','-y','40','-c',LAB/'.agent-config','/bin/bash --noprofile --norc')
        run_tail()
    else:
        run()
except Exception as exc:
    note('DRIVER FAILURE: '+str(exc))
    raise
finally:
    if (LAB/'bin/tmux').exists():
        r=tm('kill-server',ok=False)
        note(f'Private lab server stopped: exit={r.returncode} {r.stdout.strip()}')
