import os,subprocess,time,pathlib
pid=int(os.environ['LAB_SPAWN_PID']); deadline=time.monotonic()+60
while time.monotonic()<deadline:
 table=subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True)
 children=[]
 for line in table.splitlines():
  fields=line.split(None,2)
  if len(fields)==3 and int(fields[1])==pid and fields[2].endswith('sleep'): children.append(fields[0])
 for child in children:
  q=subprocess.run(['ps','-p',child,'-o','args='],text=True,stdout=subprocess.PIPE)
  if q.stdout.strip()=='sleep 0.1':
   print('observed cleanup waiting for project lock',flush=True)
   raise SystemExit(0)
 time.sleep(.03)
raise SystemExit('did not observe the project-lock wait')
