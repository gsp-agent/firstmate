import os,pathlib,subprocess,time,json
root=pathlib.Path.cwd(); scratch=root/'.gate-live-tmux'; scratch.mkdir()
home=scratch/'home'
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ['TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(key,None)
env['FM_HOME']=str(home)
def run(args,check=True):return subprocess.run([str(x) for x in args],cwd=scratch,env=env,text=True,capture_output=True,check=check)
run(['bash',root/'bin/fm-lab-home.sh','create',home])
(home/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
proj=home/'projects/plain';proj.mkdir()
meta=home/'state/plain.meta';status=home/'state/plain.status';turn=home/'state/plain.turn-ended'
meta.write_text(f'backend=tmux\nwindow=firstmate:fm-plain\nworktree={proj}\nproject={proj}\nharness=claude\nkind=ship\nspawn_gen=lab-plain\n')
status.write_text('paused: context limit reached; awaiting a fresh session and then continue\n');turn.touch()
run(['bash',root/'bin/fm-busy-event.sh','arm',home/'state','plain','--state','idle','--source','claude-hook','--event','stop'])
for p in [meta,status,turn]:os.utime(p,(time.time()-1000,time.time()-1000))
run(['tmux','-L','fm-lab','-S','socket','new-session','-d','-s','firstmate','-n','fm-plain','-c',home])
try:
 before=run(['tmux','-S','socket','list-windows','-t','firstmate','-F','#{window_name} #{pane_dead}']).stdout
 scan=run(['bash',root/'bin/fm-inactive-reconcile.sh','scan','--startup'])
 after=run(['tmux','-S','socket','list-windows','-t','firstmate','-F','#{window_name} #{pane_dead}']).stdout
 assert before==after=='fm-plain 0\n',(before,after)
 result={'before':before,'after':after,'scan_stdout':scan.stdout,'scan_stderr':scan.stderr,'result':'pass'}
 print(json.dumps(result))
 pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5G3MH318E8QVNSE345AGS9W/live-tmux-boundary.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
 cmd='tmux -L fm-lab -S socket kill-server'
 guard=run(['dcg'],check=False) if False else subprocess.run(['dcg'],input=json.dumps({'tool_name':'Bash','tool_input':{'command':cmd}}),text=True,capture_output=True,cwd=scratch)
 decision=json.loads(guard.stdout or '{}').get('hookSpecificOutput',{}).get('permissionDecision')
 if decision=='deny':raise RuntimeError('cleanup denied: '+guard.stdout)
 run(['tmux','-L','fm-lab','-S','socket','kill-server'])
