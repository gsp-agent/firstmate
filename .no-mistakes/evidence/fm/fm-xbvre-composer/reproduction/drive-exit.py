import json,os,subprocess,time
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
session=(w/'session').read_text().strip()
pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
log=(e/'exit-counterfactual.log').open('w')
def run(args,timeout=35):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    log.write('$ '+repr(args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    return p

def lab(*args): return run(['bin/fm-herdr-lab.sh','run',session,*args])
fd=os.open(w/'viewer-input',os.O_WRONLY|os.O_NONBLOCK)
os.write(fd,b'\x1b[<65;80;20M'*100); os.close(fd); time.sleep(.3)
lab('pane','send-keys',pane,'ctrl+u')
time.sleep(.3)
assert run(['bash',str(w/'probe.sh')]).stdout=='empty'
results={}
for name,version in [('target',[]),('base',['--base'])]:
    result=run(['bash',str(w/'probe.sh'),*version,'fm_backend_herdr_send_text_submit','/exit','3','0.4','1.2']).stdout
    registration=lab('agent','get',pane)
    results[name]={'verdict':result,'agent_present':registration.returncode==0}
lab('pane','send-text',pane,'/exit')
time.sleep(.5)
run(['python3',str(w/'capture.py'),'exit-popup'])
print(json.dumps(results))
(e/'exit-counterfactual.json').write_text(json.dumps(results,indent=2)+'\n')
log.close()
