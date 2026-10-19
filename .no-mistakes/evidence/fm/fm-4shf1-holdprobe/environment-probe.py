import os
from pathlib import Path
import signal
import subprocess
import time

out = Path(__file__).with_suffix('.txt')
with out.open('w', buffering=1) as f:
    f.write('Load averages: ' + repr(os.getloadavg()) + '\n')
    for args in [['/bin/ps', '-p', str(os.getpid()), '-o', 'pid=,ppid=,comm='], ['tasks-axi', '--version']]:
        start = time.monotonic()
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = p.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            stdout, stderr = p.communicate()
            f.write('TIMEOUT ')
        f.write(repr(args) + ' seconds=' + str(round(time.monotonic()-start, 2)) + ' exit=' + str(p.returncode) + '\n' + stdout + stderr + '\n')
print(out.read_text())
