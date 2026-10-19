from pathlib import Path
import json, os, signal, subprocess, threading, time
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round4')
f=json.loads((evidence/'fixture.json').read_text())
scratch=Path(f['scratch'])
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
rows=[]
for label,extra in [('perl',{'PATH':str(scratch/'perl-only-bin')})]:
 pidfile=scratch/('fulltree-'+label+'-pids')
 started=time.monotonic()
 proc=subprocess.Popen(['bash',str(scratch/'run-git-tree.sh'),str(root/'bin/fm-nm-run-lib.sh'),str(scratch/'timeout-slot')],env=env|extra|{'FM_LAB_PID_FILE':str(pidfile)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 tracked={}
 try:
  end=time.monotonic()+5
  event=threading.Event()
  while time.monotonic()<end:
   if pidfile.exists() and len(pidfile.read_text().splitlines())>=2: break
   if proc.poll() is not None: break
   event.wait(0.025)
  snapshot=subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,comm='],text=True)
  table={}
  for line in snapshot.splitlines():
   v=line.split(None,4)
   if len(v)==5: table[int(v[0])]={'pid':int(v[0]),'ppid':int(v[1]),'pgid':int(v[2]),'stat':v[3],'command':v[4]}
  pending={proc.pid}
  while pending:
   pid=pending.pop()
   if pid in tracked: continue
   if pid in table: tracked[pid]=table[pid]
   pending.update(p for p,r in table.items() if r['ppid']==pid and p not in tracked)
  stdout,stderr=proc.communicate(timeout=15)
  exited=time.monotonic()
  git=[r for r in tracked.values() if r['command'].split('/')[-1]=='git']
  states=subprocess.run(['ps','-p',','.join(map(str,tracked)),'-o','pid=,ppid=,pgid=,stat=,comm='],text=True,capture_output=True).stdout.strip() if tracked else 'no process tree captured'
  row={'mechanism':label,'command':'fm_nm_bounded <partial-clone> 2 git cat-file -e <absent>^{commit}','exit':proc.returncode,'elapsed_seconds':round(exited-started,4),'process_tree_before_timeout':list(tracked.values()),'git_processes_observed':len(git),'process_tree_after_return':states,'stderr':stderr}
  row['expected_surface']=proc.returncode==124 and len(git)>=2 and not states
  rows.append(row)
  print(json.dumps(row),flush=True)
 finally:
  groups={r['pgid'] for r in tracked.values() if r['pgid']!=os.getpgrp()}
  for group in groups:
   try: os.killpg(group,signal.SIGKILL)
   except ProcessLookupError: pass
  if proc.poll() is None:
   proc.kill()
   proc.wait()
(evidence/'perl-descendants-proof.json').write_text(json.dumps(rows,indent=2))
raise SystemExit(not all(r['expected_surface'] for r in rows))
