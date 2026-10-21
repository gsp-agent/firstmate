import os,pathlib,subprocess,shlex,time,json
root=pathlib.Path.cwd(); lab=root/'.identity-validation'; code=lab/'runtime'; home=lab/'secondmate-primary'; mate=lab/'secondmate-home'
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5FWNE5V6ESXE85390HX5H69')
env=os.environ.copy()
for key in list(env):
 if key.startswith(('FM_','GIT_','TASKS_AXI')) or key in ('TMUX','TMUX_PANE','CODEX_HOME','CLAUDE_CONFIG_DIR'):env.pop(key)
env.update(HOME=str(lab/'live/user'),SHELL='/bin/bash',GIT_CONFIG_NOSYSTEM='1',TREEHOUSE_ROOT=str(lab/'secondmate-pool'))
logs=[]
def run(args,cwd=root,check=True):
 p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 logs.append('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
 if check and p.returncode:raise RuntimeError(p.stdout)
 return p
run([code/'bin/fm-lab-home.sh','create',home]);run([code/'bin/fm-lab-home.sh','create',mate])
# Use an unchanged source export so secondmate homes can be siblings of the
# executable code root while all fixture files remain inside the run worktree.
a=subprocess.run(['git','archive','HEAD'],stdout=subprocess.PIPE,check=True)
subprocess.run(['tar','-x','-C',str(mate)],input=a.stdout,check=True)
(mate/'.fm-secondmate-home').write_text('ident-live-mate\n'); (mate/'data/charter.md').write_text('Isolated identity verification only.\n')
run(['git','init','-q','-b','main',mate]);run(['git','commit','-q','--allow-empty','-m','mate baseline'],mate)
(home/'config/worker-git-identity').write_text('gsp-agent <dale+gspagent@groovejones.com>\n')
(home/'data/ident-live-mate').mkdir();(home/'data/ident-live-mate/brief.md').write_text("# Task\n## Captain's intent\nCheck inherited git identity.\n\n## Firstmate spec\nRun only the probe.\n")
(home/'state/.last-watcher-beat').touch();env['FM_HOME']=str(home)
socket=run([code/'bin/fm-lab-home.sh','tmux-dir',home]).stdout.strip();env['TMUX_TMPDIR']=socket
sock=['tmux','-L','fm-lab']; results={}
try:
 run(sock+['new-session','-d','-s','primary','-x','120','-y','40','-c',root,'/bin/bash --noprofile --norc'])
 env['TMUX']=run(sock+['display-message','-p','-t','primary','#{socket_path},#{pid},0']).stdout.strip()
 out=evidence/'secondmate.txt';probe=lab/'live/probe.sh'
 command='/bin/bash '+shlex.quote(str(probe))+' '+shlex.quote(str(out))
 p=run([code/'bin/fm-spawn.sh','ident-live-mate',mate,command,'--secondmate'],check=False)
 deadline=time.monotonic()+15
 while p.returncode==0 and time.monotonic()<deadline:
  if out.exists() and 'committer=' in out.read_text():break
  time.sleep(.1)
 results={'spawn_exit':p.returncode,'identity_inherited':(mate/'config/worker-git-identity').read_text() if (mate/'config/worker-git-identity').exists() else None,'commit':out.read_text() if out.exists() else None}
 # The secondmate's own crew is a normal real spawn through its inherited config.
 if p.returncode==0:
  env['FM_HOME']=str(mate);(mate/'data/ident-live-mate-crew').mkdir();(mate/'data/ident-live-mate-crew/brief.md').write_text("# Task\n## Captain's intent\nCheck crew identity inherited through secondmate.\n\n## Firstmate spec\nRun only the probe.\n")
  (mate/'state/.last-watcher-beat').touch();out=evidence/'secondmate-crew.txt'
  command='/bin/bash '+shlex.quote(str(probe))+' '+shlex.quote(str(out))
  p=run([code/'bin/fm-spawn.sh','ident-live-mate-crew',lab/'live/project',command,'--mode','local-only','--yolo','off'],check=False)
  deadline=time.monotonic()+15
  while p.returncode==0 and time.monotonic()<deadline:
   if out.exists() and 'committer=' in out.read_text():break
   time.sleep(.1)
  results['crew_spawn_exit']=p.returncode;results['crew_commit']=out.read_text() if out.exists() else None
finally:
 run(sock+['kill-server'],check=False);run([code/'bin/fm-lab-home.sh','teardown',home],check=False)
 (evidence/'secondmate-transcript.txt').write_text('\n\n'.join(logs));(evidence/'secondmate-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
