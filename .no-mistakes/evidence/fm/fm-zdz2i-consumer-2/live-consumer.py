import os,subprocess,time,json,pathlib,signal
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HMEQP6WJCA325R007SZPY7'); lab=root/'l'
assert not lab.exists()
env=os.environ.copy()
for k in list(env):
 if k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TASK_ID','FM_SUPERVISION_ACTOR','FM_WATCH_PREDECESSOR_ARM_PID']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_ARM_CONFIRM_TIMEOUT='20',FM_CODEX_WATCH_CHECKPOINT='60',TMPDIR=str(root/'.test-phase-tmp'),TMUX_TMPDIR=str(lab/'tmux'),TMUX=str(lab/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')+',0,0')
def run(*args):
 p=subprocess.run(args,env=env,text=True,capture_output=True)
 print('$', ' '.join(args), '\n',p.stdout,p.stderr, 'exit',p.returncode,flush=True)
 assert p.returncode==0
 return p.stdout

def wait_for(predicate,seconds=45):
 until=time.monotonic()+seconds
 while time.monotonic()<until:
  if predicate(): return
  time.sleep(.2)
 raise AssertionError('timed out waiting for '+predicate.__name__)
def pid():
 try:return int((lab/'state/.watch.lock/pid').read_text().strip())
 except (ValueError,FileNotFoundError):return 0

def ready():
 return json.loads(subprocess.check_output(['bin/fm-inbox.sh','ready'],env=env,text=True))
proc=None
try:
 run('bin/fm-lab-home.sh','create',str(lab))
 (lab/'tmux').mkdir(); (lab/'config/supervision-host').touch()
 run('bin/fm-lock.sh')
 (lab/'state/demo.meta').write_text('project=lab\nwindow=fm-demo\nharness=codex\n')
 (lab/'state/demo.status').touch()
 print('BASELINE',json.dumps(ready()),flush=True)
 output=open(evidence/'live-checkpoint.out','w')
 proc=subprocess.Popen(['bin/fm-watch-checkpoint.sh','--seconds','60'],env=env,stdout=output,stderr=subprocess.STDOUT)
 wait_for(lambda:pid()>0 and ready()['can_receive'] is True)
 print('FIRST_READY',json.dumps(ready()),flush=True)
 first=pid()
 (lab/'state/demo.status').write_text('needs-decision: lab first notification requiring main\n')
 proc.wait(timeout=60); output.close()
 print('CHECKPOINT_EXIT',proc.returncode,flush=True)
 print((evidence/'live-checkpoint.out').read_text(),flush=True)
 assert proc.returncode==0
 wait_for(lambda:pid()>0 and pid()!=first and ready()['can_receive'] is True)
 cover=(lab/'state/.watch-cover').read_text().strip(); print('COVERAGE_HANDOFF',cover,flush=True)
 assert cover.split('\t')[3]=='handed-over'
 for i in range(1,4):
  before=pid()
  (lab/f'state/later{i}.meta').write_text('project=lab\nwindow=fm-later'+str(i)+'\nharness=codex\n')
  (lab/f'state/later{i}.status').write_text('needs-decision: lab notification during main turn '+str(i)+'\n')
  wait_for(lambda:pid()>0 and pid()!=before and ready()['can_receive'] is True)
  print('MAIN_TURN_NOTIFICATION',i,'previous_watcher',before,'next_watcher',pid(),'READY',json.dumps(ready()),flush=True)
  q=(lab/'state/.wake-queue').read_text()
  assert 'demo.status' in q
  for j in range(1,i+1): assert 'later'+str(j)+'.status' in q
  assert (lab/'state/.watch-cover').read_text().split('\t')[0]==cover.split('\t')[0]
  print('DURABLE_QUEUE',q,flush=True)
 for i in range(5):
  r=ready(); assert r['can_receive'] is True
  print('SETTLED_TICK',i,json.dumps(r),flush=True); time.sleep(1)
 (evidence/'live-wake-queue.tsv').write_text((lab/'state/.wake-queue').read_text())
 (evidence/'live-cycle-exits.tsv').write_text((lab/'state/.watch-cycle-exits.log').read_text())
 print('LIVE_CONSUMER_RESULT pass',flush=True)
finally:
 if proc is not None and proc.poll() is None:proc.terminate();proc.wait(timeout=20)
 if lab.exists():
  run('bin/fm-watch-arm.sh','--stop')
  print('CLEANUP stopped isolated consumer; lab files retained for bounded cleanup',flush=True)
