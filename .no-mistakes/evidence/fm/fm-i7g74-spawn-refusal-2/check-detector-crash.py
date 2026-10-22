import os,pathlib,subprocess
ROOT=pathlib.Path.cwd();LAB=ROOT/'.gate-live/live3'
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5H65BTPXNAE8EY0SAZPJGPX')
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_')) or k in ('TMUX','TMUX_PANE','CLAUDECODE'):env.pop(k)
bad=LAB/'invalid-detector.py';bad.write_text('def malformed_python(\n')
env.update(HOME=str(LAB/'operator-home'),PATH=str(LAB/'bin')+':'+env['PATH'],SHELL='/bin/bash',FM_HOME=str(LAB/'home'),FM_SPAWN_NO_GUARD='1',FM_BACKEND='tmux',TMUX='fm-lab,1,0',TREEHOUSE_ROOT=str(LAB/'pool'),TMPDIR=str(ROOT/'.gate-live/tmp'),FM_LIVE_SESSION_CHECK=str(bad),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(a,ok=True):
    r=subprocess.run(list(map(str,a)),env=env,text=True,capture_output=True,timeout=120)
    if ok and r.returncode:raise RuntimeError(r.stdout+r.stderr)
    return r
def tm(*a):return run([LAB/'bin/tmux',*a])
try:
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',LAB/'.agent-config','/bin/bash --noprofile --norc')
    run(['tasks-axi','add','bad-detector','Malformed configured detector','--kind','ship','--file',LAB/'home/data/backlog.md'])
    d=LAB/'home/data/bad-detector';d.mkdir()
    (d/'brief.md').write_text("# Task\n## Captain's intent\nExercise detector process failure.\n\n## Firstmate spec\nRemain idle.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n")
    r=run([ROOT/'bin/fm-spawn.sh','bad-detector',LAB/'agent-config','--mode','no-mistakes','--yolo','off','/bin/sleep 600'],False)
    transcript=f'$ FM_LIVE_SESSION_CHECK=<malformed Python file> fm-spawn.sh bad-detector agent-config --mode no-mistakes --yolo off "/bin/sleep 600"\nexit={r.returncode}\n{r.stdout}{r.stderr}'
    assert r.returncode==75,transcript
    assert 'exit 1 with no verdict line' in transcript,transcript
    assert 'SyntaxError' not in transcript and 'malformed_python' not in transcript
    assert not (LAB/'home/state/bad-detector.meta').exists()
    assert 'fm-bad-detector' not in tm('list-windows','-t','primary','-F','#{window_name}').stdout
    assert 'state: queued' in run(['tasks-axi','show','bad-detector','--file',LAB/'home/data/backlog.md']).stdout
    (EVID/'detector-crash-refusal.txt').write_text(transcript+'\nObserved: real Python interpreter failure treated as unknown; traceback suppressed; no metadata or worker endpoint; task still queued.\n')
finally:
    run([LAB/'bin/tmux','kill-server'],False)
