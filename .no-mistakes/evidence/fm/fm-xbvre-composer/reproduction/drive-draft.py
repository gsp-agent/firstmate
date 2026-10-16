import json,os,subprocess,time
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
session=(w/'session').read_text().strip()
pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
log=(e/'draft-guard.log').open('w')
def run(args):
    p=subprocess.run(args,capture_output=True,text=True,timeout=30)
    log.write('$ '+repr(args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout
def lab(*args): return run(['bin/fm-herdr-lab.sh','run',session,*args])
def scroll(direction,count=80):
    fd=os.open(w/'viewer-input',os.O_WRONLY|os.O_NONBLOCK)
    os.write(fd,(b'\x1b[<65;80;20M' if direction=='down' else b'\x1b[<64;80;20M')*count)
    os.close(fd)
    time.sleep(.3)
scroll('down')
draft='UNSENT COMPOSER SAFETY DRAFT 16OCT'
lab('pane','send-text',pane,draft)
lab('pane','wait-output',pane,'--match',draft,'--source','recent','--lines','200','--timeout','5000')
scroll('up',40)
run(['python3',str(w/'capture.py'),'draft-scrolled'])
state=(e/'draft-scrolled-state.txt').read_text()
content=(e/'draft-scrolled-content.txt').read_text()
assert state=='pending',(state,content)
assert content==draft,repr(content)
verdict=run(['bash',str(w/'probe.sh'),'fm_backend_herdr_send_text_submit','/clear','1','0.1','0.1'])
assert verdict=='send-failed',verdict
retained=run(['bash',str(w/'probe.sh'),'fm_backend_herdr_composer_content'])
assert retained==draft,repr(retained)
log.write('Draft remains byte-for-byte unchanged after reset attempt; no reset text or Enter was sent.\n')
log.close()
print('Draft scroll check: pending; guarded reset: send-failed; original draft preserved.')
