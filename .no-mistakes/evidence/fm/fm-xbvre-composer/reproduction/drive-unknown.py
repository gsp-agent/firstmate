import json,os,subprocess,time
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
session=(w/'session').read_text().strip()
pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
log=(e/'unknown-and-manual-exit.log').open('w')
def run(args,timeout=35):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    log.write('$ '+repr(args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    return p

def lab(*args): return run(['bin/fm-herdr-lab.sh','run',session,*args])
lab('pane','send-keys',pane,'enter')
exited=False
for i in range(20):
    p=lab('agent','get',pane)
    if p.returncode:
        exited=True; break
    time.sleep(.25)
assert exited,'manual /exit also failed, inspect environment'
print('Native Enter executed /exit and Claude disappeared from this same lab pane.')
lab('pane','run',pane,"printf 'CURRENT SCREEN WITHOUT AN AGENT COMPOSER\n%.0s' {1..100}")
time.sleep(.4)
p=run(['python3',str(w/'capture.py'),'no-composer'])
assert p.returncode==0
state=(e/'no-composer-state.txt').read_text()
assert state=='unknown',repr(state)
print('Historical prompts outside the live screen do not prove emptiness: '+state)
log.close()
