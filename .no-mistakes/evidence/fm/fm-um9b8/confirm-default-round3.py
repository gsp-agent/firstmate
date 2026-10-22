import json, os, signal, subprocess, time
from pathlib import Path
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
def snap():
 return subprocess.check_output(['sysctl','vm.swapusage'],text=True)+subprocess.check_output(['vm_stat'],text=True)
env=os.environ.copy(); env['TMPDIR']=str(E/'round3-tmp')
(E/'round3-default-memory-before.txt').write_text(snap())
cmd=['bash',str(E/'fm-lint-default-confirmation-round3.sh')]
start=time.monotonic()
p=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
external=False
try: out,_=p.communicate(timeout=350)
except subprocess.TimeoutExpired:
 external=True; os.killpg(p.pid,signal.SIGTERM)
 try: out,_=p.communicate(timeout=10)
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGKILL);out,_=p.communicate()
(E/'round3-default-memory-after.txt').write_text(snap())
result={'command':cmd,'test_selector':'test_large_production_roots_fit_default_caps','exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,3),'external_cutoff':external}
(E/'round3-default-confirmation.log').write_text('$ tests/fm-lint.test.sh :: test_large_production_roots_fit_default_caps\n'+out+'\n'+json.dumps(result,indent=2)+'\n')
(E/'round3-default-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(out,flush=True);print(json.dumps(result),flush=True)
