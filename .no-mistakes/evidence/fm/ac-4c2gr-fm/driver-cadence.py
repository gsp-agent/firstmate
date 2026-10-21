import json
import os
import selectors
import signal
import subprocess
import time
from pathlib import Path

root = Path.cwd()
lab = root/'.gate-validation'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F6DBZ4BWZT50JTY1CDEKMR')
home = lab/'cadence-home'
for child in ['state','data','config']:
    (home/child).mkdir(parents=True,exist_ok=True)
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_')):
        env.pop(key, None)
env.update(PATH=str(lab/'toolbin')+os.pathsep+env['PATH'],LIVE_REAL_GH='/opt/homebrew/bin/gh',
           LIVE_GH_TRACE=str(evidence/'cadence-gh-trace.jsonl'),FM_HOME=str(home),
           TMUX=str(lab/'unused-private-socket')+',0,0')
subprocess.run(['bash',str(lab/'arm.sh'),str(home/'state'),'cadence','14781',str(root/'bin/fm-pr-poll.sh')],
               env=env,check=True)
fifo = lab/'batch-notify'
os.mkfifo(fifo,0o600)
env['LIVE_BATCH_NOTIFY'] = str(fifo)
fd = os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
selector = selectors.DefaultSelector()
selector.register(fd,selectors.EVENT_READ)
times = []
deadline = time.monotonic()+380
with (evidence/'cadence-watcher.log').open('w') as log:
    proc = subprocess.Popen(['bash',str(root/'bin/fm-watch.sh')],env=env,
                            stdout=log,stderr=log,start_new_session=True)
    try:
        pending = b''
        while len(times)<2:
            assert selector.select(max(0,deadline-time.monotonic())), 'watcher did not perform two default-interval sweeps'
            pending += os.read(fd,4096)
            while b'\n' in pending:
                line,pending = pending.split(b'\n',1)
                times.append(float(line))
        delta = times[1]-times[0]
        assert 300 <= delta < 345, delta
        result={'scenario':'real watcher retains its default 300-second PR cadence',
                'query_times_unix':times,'seconds_between_batch_reads':delta,
                'FM_CHECK_INTERVAL':'unset','status':'pass'}
        (evidence/'live-cadence.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result),flush=True)
    finally:
        os.killpg(proc.pid,signal.SIGTERM)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL)
            proc.wait()
        os.close(fd)
