import json
import os
import socket
import subprocess
import threading
from pathlib import Path

root=Path.cwd()
lab=root/'.gate-validation'
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5F6DBZ4BWZT50JTY1CDEKMR')
home=lab/'timeout-home-2'
for child in ['state','data','config']:
    (home/child).mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_')):
        env.pop(key,None)
env.update(PATH=str(lab/'toolbin')+os.pathsep+env['PATH'],LIVE_REAL_GH='/opt/homebrew/bin/gh',
           LIVE_GH_TRACE=str(evidence/'timeout-gh-trace.jsonl'),
           LIVE_GH_START_TRACE=str(evidence/'timeout-gh-start.jsonl'),
           FM_HOME=str(home),TMUX=str(lab/'unused-private-socket')+',0,0',FM_CHECK_TIMEOUT='3')
subprocess.run(['bash',str(lab/'arm.sh'),str(home/'state'),'timeout','14781',str(root/'bin/fm-pr-poll.sh')],env=env,check=True)
check=home/'state'/'z-stop.check.sh'
check.write_text('#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n')
check.chmod(0o700)
subprocess.run(['bash',str(root/'bin/fm-check-register.sh'),'z-stop'],env=env,check=True,capture_output=True)
listener=socket.socket()
listener.bind(('127.0.0.1',0))
listener.listen()
listener.settimeout(40)
accepted=threading.Event()
finish=threading.Event()
def blackhole():
    connection,_=listener.accept()
    accepted.set()
    finish.wait(55)
    connection.close()
thread=threading.Thread(target=blackhole,daemon=True)
thread.start()
proxy='http://127.0.0.1:'+str(listener.getsockname()[1])
env.update(HTTPS_PROXY=proxy,HTTP_PROXY=proxy,ALL_PROXY=proxy,NO_PROXY='')
trace=evidence/'timeout-gh-start.jsonl'
before=len(trace.read_text().splitlines()) if trace.exists() else 0
try:
    result=subprocess.run(['bash',str(root/'bin/fm-watch.sh')],env=env,capture_output=True,text=True,timeout=55)
    transcript={'scenario':'real GitHub request stalls beyond the batch timeout',
                'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
                'proxy_connection_accepted':accepted.is_set()}
    starts=[json.loads(line) for line in trace.read_text().splitlines()[before:]]
    transcript['attempted_commands']=[c['args'] for c in starts]
    (evidence/'live-timeout.json').write_text(json.dumps(transcript,indent=2)+'\n')
    print(json.dumps(transcript,indent=2))
    assert result.returncode==0
    assert accepted.is_set()
    assert 'stop-cycle' in result.stdout
    assert 'timeout.check.sh:' not in result.stdout
    assert sum(any('FmPollBatch' in a for a in c['args']) for c in starts)==1
    assert not any('number=' in a for c in starts for a in c['args'])
    assert (home/'state'/'timeout.pr-poll-registration').exists()
finally:
    finish.set()
    listener.close()
