import os, subprocess, time, json, signal
from pathlib import Path
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
def snap():
 return subprocess.check_output(['sysctl','vm.swapusage'],text=True)+subprocess.check_output(['vm_stat'],text=True)
(E/'round4-memory-before.txt').write_text(snap())
env=os.environ.copy();env['TMPDIR']=str(E/'round4-tmp')
for k in ['FM_LINT_ROOT_SECONDS','FM_LINT_ROOT_GRACE','FM_LINT_ROOT_MEMORY_KIB','FM_LINT_JOBS','FM_LINT_TELEMETRY']: env.pop(k,None)
p=subprocess.Popen(['bash',str(E/'fm-lint-focused-round4.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
start=time.monotonic()
with (E/'fm-lint-focused-round4.log').open('w') as log:
 for line in p.stdout:
  log.write(line);log.flush();print(line,end='',flush=True)
p.wait()
(E/'round4-memory-after.txt').write_text(snap())
result=dict(exit=p.returncode,elapsed_seconds=round(time.monotonic()-start,3))
(E/'round4-focused-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(result,flush=True)
