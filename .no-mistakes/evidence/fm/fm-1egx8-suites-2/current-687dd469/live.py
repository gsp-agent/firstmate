import os, json, shutil, subprocess as sp, signal, time
from pathlib import Path
root=Path.cwd(); scratch=root/'.test-live-687dd469/live'; scratch.mkdir()
e=Path(__file__).parent
base=dict(os.environ)
for k in list(base):
 if k.startswith(('FM_','TASKS_AXI_','GIT_CONFIG_')) or k in ('TMUX','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'): base.pop(k,None)
base.update(HOME=str(scratch/'user'),CODEX_HOME=str(scratch/'user/codex'),TMPDIR=str(scratch/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMUX=str(scratch/'absent-socket')+',1,0',TMUX_TMPDIR=str(scratch/'tmp'),XDG_CONFIG_HOME=str(scratch/'user/config'),XDG_CACHE_HOME=str(scratch/'user/cache'))
for name in ('user','user/codex','tmp'): (scratch/name).mkdir(parents=True,exist_ok=True)
log=(e/'live.log').open('w',buffering=1)
def note(x): print(x,flush=True); print(x,file=log,flush=True)
def run(args,env=base,**kwargs): return sp.run(args,env=env,check=True,text=True,**kwargs)
def wait_for(pred,message,seconds=60):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if pred(): return
  time.sleep(.03)
 raise AssertionError(message)
def home(name,count=0,secondmate=True):
 h=scratch/name
 run(['bin/fm-lab-home.sh','create',str(h)],stdout=sp.DEVNULL)
 if secondmate: (h/'.fm-secondmate-home').write_text('mate\n')
 (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n'+''.join('- [ ] queued-%d - Disposable queued task (repo: lab) (kind: scout)\n'%i for i in range(count))+'\n## Done\n')
 return h
def table():
 raw=sp.run(['ps','-axo','pid=,ppid=,pgid=,stat=,command='],capture_output=True,text=True,check=True).stdout
 result={}
 for row in raw.splitlines():
  f=row.split(None,4)
  if len(f)==5: result[int(f[0])]=(int(f[1]),int(f[2]),f[3],f[4][:260])
 return result
def children(t,p):
 found={p}
 while True:
  more={i for i,row in t.items() if row[0] in found}
  if more<=found: return found
  found|=more

def cancel(name,mechanism,trigger):
 h=home(name,3000)
 local=dict(base,FM_HOME=str(h),FM_HOME_SUMMARY_TIMEOUT='900',FM_HOME_SUMMARY_INTERVAL='1' if trigger=='poll' else '9999999',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
 tools=scratch/('tools-'+name); tools.mkdir()
 for tool in ('bash sleep dirname basename date env mkdir mktemp chmod cat rm rmdir mv jq ps awk sed tr tail wc head cut sort shasum sha256sum cksum stat find uname touch python3 git readlink id grep mkfifo od cp ln cmp xargs hostname kill perl').split():
  source=shutil.which(tool)
  if source: (tools/tool).symlink_to(source)
 if mechanism in ('timeout','gtimeout'): (tools/mechanism).symlink_to(shutil.which('timeout') or shutil.which('gtimeout'))
 if mechanism=='bash': local['FM_TIMEOUT_MECHANISM_OVERRIDE']='bash'
 local['PATH']=str(tools)
 out=(e/(name+'.out')).open('w'); err=(e/(name+'.err')).open('w')
 command=['bash','bin/fm-home-summary-refresh.sh'] if trigger=='direct' else ['bash','bin/fm-watch.sh']
 p=sp.Popen(command,env=local,stdout=out,stderr=err); seen={}; groups=set()
 try:
  if trigger=='signal':
   wait_for(lambda: (h/'state/.last-watcher-beat').exists(),'watcher did not poll')
   assert not (h/'state/home-summary.json').exists()
   (h/'state/task.meta').write_text('kind=scout\nharness=codex\n')
   (h/'state/task.status').write_text('working: disposable task progress\n')
  def producer_started():
   t=table(); owned=children(t,p.pid)
   for i in owned:
    if i in t: seen[i]=t[i]
   producers=[i for i in owned if i in t and 'bin/fm-fleet-snapshot.sh' in t[i][3]]
   assert p.poll() is None,'parent exited before observing producer'
   if producers:
    groups.update(t[i][1] for i in producers)
    return True
   return False
  wait_for(producer_started,'real producer did not start')
  note(name+' observed owned tree '+json.dumps(seen,sort_keys=True))
  start=time.monotonic(); p.terminate(); p.wait(timeout=45)
  t=table(); survivors={i:t[i] for i in seen if i in t and not t[i][2].startswith('Z')}
  grouped={i:r for i,r in t.items() if r[1] in groups and not r[2].startswith('Z')}
  note(name+' rc='+str(p.returncode)+' elapsed='+str(round(time.monotonic()-start,3))+' survivors='+json.dumps(survivors)+' group_survivors='+json.dumps(grouped))
  assert not survivors and not grouped,'owned producer survived cancellation'
  assert p.returncode in (-15,143,0)
 finally:
  if p.poll() is None: p.kill(); p.wait()
  for pg in groups:
   if pg!=os.getpgrp():
    try: os.killpg(pg,signal.SIGKILL)
    except ProcessLookupError: pass
  out.close();err.close()

h=home('publication'); local=dict(base,FM_HOME=str(h))
run(['bin/fm-home-summary-refresh.sh','--request','--wait'],env=local,timeout=60,capture_output=True)
ledger=json.loads((h/'state/home-summary.json').read_text()); assert ledger['valid'] and ledger['state']=='no_active_work'
shutil.copy2(h/'state/home-summary.json',e/'published-summary.json'); note('Real waited publication '+json.dumps(ledger,sort_keys=True))
m=home('main-noop',secondmate=False)
run(['bin/fm-home-summary-refresh.sh','--request','--wait'],env=dict(base,FM_HOME=str(m)),timeout=10,capture_output=True)
assert not list((m/'state').iterdir()); note('Main-home --request --wait returned success with no state writes')
for mechanism in ('timeout','gtimeout','perl','bash'):
 cancel('cancel-'+mechanism+'-poll',mechanism,'poll')
 cancel('cancel-'+mechanism+'-signal',mechanism,'signal')

# An external validation CLI is the slow dependency; snapshot, writer, and drain are real.
h=home('teardown-request'); wt=h/'projects/task'; wt.mkdir()
git_env=dict(base,GIT_AUTHOR_NAME='Test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Test',GIT_COMMITTER_EMAIL='test@example.invalid')
run(['git','init','-q','-b','fm/disposable'],env=git_env,cwd=wt)
run(['git','-c','commit.gpgsign=false','commit','-q','--allow-empty','-m','fixture'],env=git_env,cwd=wt)
(h/'state/task.meta').write_text('kind=ship\nharness=claude\nmode=no-mistakes\nproject=lab\nworktree='+str(wt)+'\nwindow=fm-lab:task\n')
backlog=h/'data/backlog.md'; backlog.write_text('## In flight\n- [ ] task - Disposable child (repo: lab) (kind: ship)\n\n## Queued\n\n## Done\n')
tools=h/'tools'; tools.mkdir(); dependency=tools/'no-mistakes'
dependency.write_text('#!/bin/sh\nprintf "%s\\n" "$$" >> "$FM_HOME/state/dependency-started"\nsleep 3\nexit 0\n');dependency.chmod(0o755)
local=dict(base,PATH=str(tools)+os.pathsep+base['PATH'],FM_HOME=str(h),FM_HOME_SUMMARY_TIMEOUT='30',FM_HOME_SUMMARY_INTERVAL='1')
with (e/'teardown.out').open('w') as out, (e/'teardown.err').open('w') as err:
 p=sp.Popen(['bin/fm-home-summary-refresh.sh','--request','--wait'],env=local,stdout=out,stderr=err)
 try:
  wait_for(lambda:(h/'state/dependency-started').exists(),'real snapshot did not reach validation dependency')
  # Model teardown's metadata removal by moving it within the disposable home.
  (h/'state/task.meta').rename(h/'task.retired-meta')
  backlog.write_text('## In flight\n\n## Queued\n\n## Done\n')
  run(['bin/fm-home-summary-refresh.sh','--request'],env=local,timeout=10,capture_output=True)
  assert (h/'state/.home-summary-dirty').exists(),'request did not leave a dirty mark'
  p.wait(timeout=60); assert p.returncode==0
  def removed():
   try:
    obj=json.loads((h/'state/home-summary.json').read_text())
    return not obj['active_children'] and obj['valid']
   except (FileNotFoundError,json.JSONDecodeError): return False
  wait_for(removed,'teardown publication was stranded',60)
  wait_for(lambda:not (h/'state/.home-summary-drain.lock').exists(),'detached drain did not finish')
  assert not (h/'state/.home-summary-dirty').exists()
  shutil.copy2(h/'state/home-summary.json',e/'teardown-final-summary.json')
  note('Request during the waited real snapshot: dirty mark consumed by follow-up drain; removed child absent from final valid ledger '+(h/'state/home-summary.json').read_text())
 finally:
  if p.poll() is None: p.terminate();p.wait(timeout=30)
note('All real-product publication, cancellation, and teardown handoff scenarios passed')
