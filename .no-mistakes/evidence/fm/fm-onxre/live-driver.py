import os, subprocess, pathlib, json, time, sys
R=pathlib.Path.cwd(); B=R/'.test-runtime/live'; B.mkdir(parents=True,exist_ok=True)
E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5K3X4E6P8S1F60B3JBXYBNS')
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('GIT_') or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDECODE'): env.pop(k,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',SHELL='/bin/bash',HOME=str(B/'user'),TREEHOUSE_ROOT=str(B/'pool'),TMPDIR=str(R/'.test-runtime/tmp'),FM_SPAWN_NO_GUARD='1')
pathlib.Path(env['HOME']).mkdir(exist_ok=True)
H=B/'home'; P=B/'project'; S=str(R/'.t')
def run(args,**kw):
 return subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
def must(args,**kw):
 q=run(args,**kw)
 if q.returncode: raise RuntimeError(str(args)+'\n'+q.stdout)
 return q.stdout.strip()
must([R/'bin/fm-lab-home.sh','create',H]); env['FM_HOME']=str(H)
(H/'config/backlog-backend').write_text('manual\n')
P.mkdir(); must(['git','-C',P,'init','-q','-b','main'])
(P/'README.md').write_text('Disposable deferred spawn lab\n')
(P/'treehouse.toml').write_text('max_trees = 3\nroot = "'+str(B/'pool')+'"\n')
must(['git','-C',P,'add','.']); must(['git','-C',P,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','base'])
must(['git','clone','--bare',P,B/'origin.git']); must(['git','-C',P,'remote','add','origin',str(B/'origin.git')]); must(['git','-C',P,'fetch','origin'])
id='nm-onxre-'+str(os.getpid()); env['LAB_TASK']=id
D=H/'data'/id; D.mkdir(); (D/'brief.md').write_text('# Task\n## Captain\'s intent\nVerify a late deferral and clean retry in a disposable lab.\n\n## Firstmate spec\nStart the diagnostic worker and preserve its isolated checkout.\n\n# Definition of done\nDelivery contract: mode=local-only\nShip branch: fm/'+id+'\n')
worker=B/'worker.py'; worker.write_text('import os,pathlib,subprocess,time\np=pathlib.Path(os.environ["FM_HOME"])/"worker-started.json"\np.write_text(__import__("json").dumps({"cwd":os.getcwd(),"branch":subprocess.check_output(["git","branch","--show-current"],text=True).strip()}))\nprint("DIAGNOSTIC WORKER STARTED",flush=True)\ntime.sleep(90)\n')
det=B/'detector.py'; det.write_text('import os,sys,pathlib\nh=pathlib.Path(os.environ["FM_HOME"])\nif (h/"defer").exists():\n print("live signal=person source=disposable-lab");sys.exit(75)\n')
env['FM_LIVE_SESSION_CHECK']=str(det); (H/'defer').touch()
log=[]
try:
 must(['tmux','-S',S,'-f','/dev/null','new-session','-d','-s','fm-lab-onxre','-x','120','-y','40','-c',P,'/bin/bash','--noprofile','--norc'])
 env['TMUX']=S+','+must(['tmux','-S',S,'display-message','-p','#{pid}'])+',0'
 cmd=[R/'bin/fm-spawn.sh',id,P,'--mode','local-only','--yolo','off','--backend','tmux','python3 -u '+str(worker)]
 for phase in ['defer','retry']:
  q=run(cmd,timeout=160); log.append('COMMAND: fm-spawn '+id+' --mode local-only --yolo off --backend tmux [diagnostic worker]\nPHASE: '+phase+'\n'+q.stdout+'EXIT: '+str(q.returncode))
  w=must(['git','-C',P,'worktree','list','--porcelain']); log.append(w)
  (E/'live-defer-retry.log').write_text('\n\n'.join(log))
  if phase=='defer':
   assert q.returncode==75,q.stdout
   assert not (H/'state'/f'{id}.meta').exists()
   assert 'branch refs/heads/fm/'+id not in w,w
   (H/'defer').unlink()
  else:
   assert q.returncode==0,q.stdout
   for i in range(100):
    if (H/'worker-started.json').exists(): break
    time.sleep(.1)
   result=(H/'worker-started.json').read_text(); log.append('WORKER OBSERVATION: '+result)
   assert json.loads(result)['branch']=='fm/'+id
   log.append(must(['tmux','-S',S,'capture-pane','-p','-t','fm-lab-onxre:fm-'+id]))
   (E/'live-defer-retry.log').write_text('\n\n'.join(log))
 print('Live deferral and retry passed')
finally:
 q=run(['tmux','-S',S,'kill-server']); log.append('PRIVATE SERVER CLEANUP: '+str(q.returncode))
 (E/'live-defer-retry.log').write_text('\n\n'.join(log))
