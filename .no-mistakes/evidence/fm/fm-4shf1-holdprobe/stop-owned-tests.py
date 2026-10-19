import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

roots = [int(x) for x in sys.argv[1:]]
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
def children(pid):
    buf = (ctypes.c_int * 8192)()
    count = lib.proc_listchildpids(pid, buf, ctypes.sizeof(buf))
    return [int(x) for x in list(buf)[:max(0, count // ctypes.sizeof(ctypes.c_int))] if x]
seen = set()
order = []
def walk(pid):
    if pid in seen:
        return
    seen.add(pid)
    for child in children(pid):
        walk(child)
    order.append(pid)
for root in roots:
    walk(root)
cmd = 'kill -TERM ' + ' '.join(str(pid) for pid in order)
guard = subprocess.run(['dcg'], input=json.dumps({'tool_name':'Bash','tool_input':{'command':cmd}}), text=True, capture_output=True)
print('Owned test process ids:', order)
print('dcg:', guard.stdout or 'allowed')
if 'deny' in guard.stdout.lower() or guard.returncode:
    raise SystemExit('Cleanup refused by dcg')
for pid in order:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
