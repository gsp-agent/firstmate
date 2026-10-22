import os,subprocess,time,pathlib,json
root=pathlib.Path.cwd(); lab=root/'.test-phase-tmp/attachment-race'; evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HMEQP6WJCA325R007SZPY7')
env=os.environ.copy()
for k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_TASK_ID','FM_SUPERVISION_ACTOR','FM_WATCH_COVER','FM_WATCH_PREDECESSOR_ARM_PID']:env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_ARM_CONFIRM_TIMEOUT='20',TMPDIR=str(root/'.test-phase-tmp'),TMUX_TMPDIR=str(root/'l/tmux'),TMUX=str(root/'l/tmux'/('tmux-'+str(os.getuid()))/'fm-lab')+',0,0')
def run(*args):
 p=subprocess.run(args,env=env,text=True,capture_output=True);print('$',' '.join(args),'\n'+p.stdout+p.stderr,'exit',p.returncode,flush=True);assert p.returncode==0;return p.stdout

def pid():
 try:return int((lab/'state/.watch.lock/pid').read_text())
 except (FileNotFoundError,ValueError):return 0

def wait(pred):
 until=time.monotonic()+45
 while time.monotonic()<until:
  if pred():return
  time.sleep(.2)
 raise AssertionError('timed out')
def healthy():
 r=json.loads(subprocess.check_output(['bin/fm-inbox.sh','ready'],env=env,text=True));return r['can_receive'] is True
peer=arm=None
try:
 run('bin/fm-lab-home.sh','create',str(lab));run('bin/fm-lock.sh')
 (lab/'state/demo.meta').write_text('project=lab\nwindow=fm-demo\nharness=codex\n');(lab/'state/demo.status').touch()
 p_out=open(evidence/'live-attachment-race-peer.out','w');a_out=open(evidence/'live-attachment-race-arm.out','w')
 peer=subprocess.Popen(['bin/fm-watch.sh'],env=dict(env,FM_WATCH_HANDLING_SUCCESSOR='1'),stdout=p_out,stderr=subprocess.STDOUT)
 arm=subprocess.Popen(['bin/fm-watch-arm.sh'],env=dict(env,FM_WATCH_COVER='1',FM_WATCH_PREDECESSOR_ARM_PID=str(os.getpid())),stdout=a_out,stderr=subprocess.STDOUT)
 wait(lambda:'watcher: attached pid=' in (evidence/'live-attachment-race-arm.out').read_text())
 cover=(lab/'state/.watch-cover').read_text();assert int(cover.split('\t')[0])==arm.pid
 assert pid()==peer.pid
 print('ATTACHED_READY', (evidence/'live-attachment-race-arm.out').read_text(),'COVER_RECORD',cover,flush=True)
 run('bin/fm-watch-arm.sh','--cover-handoff',str(arm.pid))
 assert (lab/'state/.watch-cover').read_text().split('\t')[3].strip()=='handed-over'
 (lab/'state/demo.status').write_text('needs-decision: notification closes the attached peer\n')
 peer.wait(timeout=45)
 wait(lambda:pid()>0 and pid()!=peer.pid and healthy())
 replacement=pid();parent=int(subprocess.check_output(['ps','-o','ppid=','-p',str(replacement)],text=True).strip());assert parent==arm.pid
 print('REPLACEMENT_OWNERSHIP',json.dumps({'closed_peer':peer.pid,'cover_arm':arm.pid,'replacement_watcher':replacement,'replacement_parent':parent}),flush=True)
 print('READINESS',run('bin/fm-inbox.sh','ready'),flush=True)
 q=(lab/'state/.wake-queue').read_text();assert 'demo.status' in q
 print('UNCONSUMED_QUEUE',q,flush=True)
 ledger=(lab/'state/.watch-cycle-exits.log').read_text();print('CYCLE_EXITS',ledger,flush=True)
 (evidence/'live-attachment-race-cycles.tsv').write_text(ledger)
 print('LIVE_ATTACHMENT_RACE_RESULT pass',flush=True)
finally:
 if lab.exists():run('bin/fm-watch-arm.sh','--stop')
 for p in [arm,peer]:
  if p is not None:
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=15)
