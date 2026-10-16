import json,os,subprocess,time
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
session=(w/'session').read_text().strip()
pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
log=(e/'popup-submit.log').open('w')
def run(args,timeout=35):
    p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    log.write('$ '+repr(args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout
def lab(*args): return run(['bin/fm-herdr-lab.sh','run',session,*args])
def scroll(direction,count=80):
    fd=os.open(w/'viewer-input',os.O_WRONLY|os.O_NONBLOCK)
    os.write(fd,(b'\x1b[<65;80;20M' if direction=='down' else b'\x1b[<64;80;20M')*count)
    os.close(fd); time.sleep(.3)
scroll('down')
lab('pane','send-keys',pane,'ctrl+u')
lab('pane','send-text',pane,'/')
time.sleep(.5)
run(['python3',str(w/'capture.py'),'slash-popup'])
state=(e/'slash-popup-state.txt').read_text()
content=(e/'slash-popup-content.txt').read_text()
assert state=='pending',(state,content)
log.write('Observed popup extraction: '+repr(content)+'\n'); log.flush()
lab('pane','send-keys',pane,'ctrl+u')
time.sleep(.3)
assert run(['bash',str(w/'probe.sh')])=='empty'
scroll('up',40)
assert run(['bash',str(w/'probe.sh'),'--base'])=='unknown'
assert run(['bash',str(w/'probe.sh')])=='empty'
verdict=run(['bash',str(w/'probe.sh'),'fm_backend_herdr_send_text_submit','/clear','3','0.4','1.2'])
log.write('CLEAR_SUBMIT_VERDICT='+verdict+'\n'); log.flush()
print('Popup state='+state+', extracted='+repr(content)+'; /clear submit='+verdict)
run(['python3',str(w/'capture.py'),'after-clear'])
log.close()
