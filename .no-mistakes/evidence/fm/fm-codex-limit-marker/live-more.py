import os,subprocess as sp,pathlib as P,time,json,shlex
root=P.Path.cwd(); ev=P.Path('/Users/dalecarman/.no-mistakes/evidence/01M5JHQCG4FESCSQGZDRMVAJQS'); lab=root/'.live-limit-lab3'; home=lab/'home'; id=(ev/'live-task-id.txt').read_text(); meta=home/'state'/(id+'.meta'); log=(ev/'live-additional.log').open('w',buffering=1)
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
try:
    # A same-harness record with explicit axes, then a real omitted-axis relaunch.
    start()
    run(['bash','bin/fm-spawn.sh',id,'--relaunch','--model','sonnet','--effort','high'])
    first=dict(l.split('=',1) for l in meta.read_text().splitlines() if '=' in l); assert first['model']=='sonnet' and first['effort']=='high'
    log.write('Recorded explicit pair: '+json.dumps(first)+'\n'); time.sleep(2); tm('capture-pane','-p','-t','primary'); stop()
    start()
    run(['bash','bin/fm-spawn.sh',id,'--relaunch'])
    after=dict(l.split('=',1) for l in meta.read_text().splitlines() if '=' in l)
    assert after['harness']=='claude' and after['model']=='sonnet' and after['effort']=='high'
    assert after['spawn_gen']!=first['spawn_gen']
    log.write('After omitted-axis relaunch: '+json.dumps(after)+'\n'); time.sleep(2); tm('capture-pane','-p','-t','primary'); stop()
    # The real scanner must reject another worktree and a previous generation.
    for label,wt,epoch in [('unrelated',lab/'project',int(time.time())-300),('stale',lab/'wt',int(time.time())+300)]:
        oid=id+'-'+label; m=home/'state'/(oid+'.meta'); m.write_text('harness=codex\nworktree='+str(wt)+'\nspawn_gen=s'+str(epoch)+'.1.1\n')
        p=run(['bash','bin/fm-cursor-guard.sh','route',oid,'codex']); assert p.stdout.strip()=='codex'; assert not (home/'state'/(oid+'.codex-limit')).exists()
    oid=id+'-override'; m=home/'state'/(oid+'.meta'); m.write_text('harness=cursor-agent\n')
    p=run(['bash','bin/fm-cursor-guard.sh','route',oid,'claude --model sonnet','cursor-agent --trust']); assert p.stdout.strip()=='claude'
    text=(home/'state'/(oid+'.cursor-fallback')).read_text(); assert text.strip()=='explicit --harness claude override of a recorded cursor task'; log.write('Cursor override reason: '+text)
    # Fresh-spawn guard is also exercised before provisioning, with a real inherited marker.
    oid=id+'-fresh'; (home/'data'/oid).mkdir(); (home/'data'/oid/'brief.md').write_text('# Task\n## Captain intent\nRead-only disposable route check.\n')
    (home/'state'/(oid+'.codex-limit')).write_text((home/'state'/(id+'.codex-limit')).read_text())
    start()
    p=run(['bash','bin/fm-spawn.sh',oid,lab/'project','--scout','--harness','codex --no-alt-screen'],False)
    assert p.returncode==1 and 'route to claude' in p.stderr+p.stdout
    assert not (home/'state'/(oid+'.meta')).exists()
    log.write('Fresh raw Codex spawn selected Claude and refused before allocating a task.\n')
    (ev/'additional-results.json').write_text(json.dumps({'model':'sonnet','effort':'high','omitted_axes_preserved':True,'unrelated_and_old_sessions_ignored':True,'cursor_override_recorded':True,'fresh_spawn_marked_route':'claude'},indent=2))
finally:
    stop()
