import os,subprocess as sp,pathlib as P,time,json,shlex
root=P.Path.cwd(); ev=P.Path('/Users/dalecarman/.no-mistakes/evidence/01M5JHQCG4FESCSQGZDRMVAJQS'); lab=root/'.live-limit-lab3'; home=lab/'home'; id=(ev/'live-task-id.txt').read_text(); meta=home/'state'/(id+'.meta'); log=(ev/'live-cursor.log').open('w',buffering=1)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','HERDR_','CLAUDE','CODEX','TASKS_AXI')) or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE']: env.pop(k,None)
env.update(HOME=str(lab/'user'),CLAUDE_CONFIG_DIR=str(lab/'user'/'.claude'),CODEX_HOME=str(lab/'codex'),FM_HOME=str(home),FM_BACKEND='tmux',TMUX_TMPDIR=str(ev/'t'),FM_SPAWN_NO_GUARD='1',FM_LIVE_SESSION_CHECK='',DISABLE_AUTOUPDATER='1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
def run(a,check=True):
    p=sp.run(list(map(str,a)),env=env,capture_output=True,text=True,timeout=120); log.write('$ '+shlex.join(list(map(str,a)))+'\n'+p.stdout+p.stderr+'[exit '+str(p.returncode)+']\n')
    if check: assert p.returncode==0,p.stdout+p.stderr
    return p

def tm(*a,check=True): return run(['tmux','-L','fm-lab',*a],check)
def start():
    env.pop('TMUX',None); env.pop('TMUX_PANE',None)
    tm('-f','/dev/null','new-session','-d','-s','primary','-n','fm-'+id,'-x','120','-y','40','-c',lab/'wt')
    env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip(); env['TMUX_PANE']=tm('display-message','-p','-t','primary','#{pane_id}').stdout.strip()
def stop(): tm('kill-server',check=False)
id=id+'healthy'; meta=home/'state'/(id+'.meta')
base={'window':'primary:fm-'+id,'endpoint_task_id':id,'worktree':str(lab/'wt'),'project':str(lab/'project'),'harness':'cursor-agent','kind':'ship','mode':'local-only','yolo':'off','model':'default','effort':'default','backend':'tmux','spawn_gen':'s'+str(int(time.time()))+'.1.1'}
meta.write_text(''.join(k+'='+v+'\n' for k,v in base.items())); (home/'data'/id).mkdir(); (home/'data'/id/'brief.md').write_text('# Task\n## Captain intent\nReply OK only; do not edit files.\n')
(lab/'usage'/'current-spending.txt').write_text('cursor_models_pct=10\n'); env['FM_CURSOR_USAGE_DIR']=str(lab/'usage')
for k in list(env):
    if k.startswith('CURSOR_'): env.pop(k,None)
try:
    start()
    p=run(['bash','bin/fm-spawn.sh',id,'--relaunch','--harness','cursor-agent --trust'])
    assert 'harness=cursor-agent' in p.stdout and 'harness=cursor-agent\n' in meta.read_text()
    assert not (home/'state'/(id+'.cursor-fallback')).exists()
    time.sleep(2); pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    log.write('Healthy raw Cursor task record:\n'+meta.read_text()); stop()
    start()
    p=run(['bash','bin/fm-spawn.sh',id,'--relaunch','--harness','claude'])
    assert 'harness=claude' in p.stdout
    reason=(home/'state'/(id+'.cursor-fallback')).read_text(); assert reason.strip()=='explicit --harness claude override of a recorded cursor task'
    log.write('Cursor-to-Claude explicit relaunch reason: '+reason); time.sleep(2); tm('capture-pane','-p','-t','primary')
finally:
    stop()
