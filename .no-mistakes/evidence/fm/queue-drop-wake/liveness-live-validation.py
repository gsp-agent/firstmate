#!/usr/bin/env python3
"""Adversarial beacon aging at the production stall bound, using real checks."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode=True
out=Path('/Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS')
spec=importlib.util.spec_from_file_location('queue_live',out/'live-queue-validation.py')
live=importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
data=live.Dataset('collected-check-liveness',[[live.node(9,'sweep-final-drop')]],{n:live.node(n,'armed-final-drop' if n==8 else None,queued=n!=8) for n in range(1,9)})
observations=[]
try:
    ctx=live.setup(data,[(f'task-{n}','o/r',n) for n in range(1,9)])
    beat=ctx[0]/'state/.last-watcher-beat'
    pid_file=ctx[0]/'state/.watch.lock/pid'
    def during_poll(number):
        age=time.time()-beat.stat().st_mtime
        observations.append({'poll':number,'beacon_age_on_start_seconds':age,'watcher_pid':pid_file.read_text().strip()})
        if age>=900:
            data.errors.append(f'Completed poll left the beacon expired before poll {number}')
        if number<8:
            expired=time.time()-901
            os.utime(beat,(expired,expired))
            time.sleep(0.25)
        else:
            before=pid_file.read_text()
            stdout,stderr=live.call([live.ROOT/'bin/fm-watch.sh'],ctx[1],timeout=10)
            (ctx[2]/'rearm.txt').write_text(stdout+stderr)
            if 'watcher: already running pid ' not in stdout or pid_file.read_text()!=before:
                data.errors.append('Re-arm replaced a progressing watcher')
    data.on_poll=during_poll
    drain,state=live.cycle(data,ctx,timeout=90)
    assert [row['poll'] for row in observations]==list(range(1,9))
    live.once(drain,'o/r',8,'failed_checks')
    live.once(drain,'o/r',9,'failed_checks')
    (ctx[2]/'beacon-observations.json').write_text(json.dumps(observations,indent=2)+'\n')
    live.finish(data,'Each collected poll renews the existing beacon; re-arm preserves the progressing watcher and final armed and unarmed drops are delivered')
finally:
    live.SERVER.shutdown();live.SERVER.server_close()
    (out/'liveness-live-scenarios.json').write_text(json.dumps(live.RESULTS,indent=2)+'\n')
