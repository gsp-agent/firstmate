#!/usr/bin/env python3
"""Capture the actual runner's output and process effects for external signals."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

repo = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M595RNA6700Q16CBBH8ZN9M6')
ev = Path('/Users/dalecarman/.no-mistakes/evidence/01M595RNA6700Q16CBBH8ZN9M6')
sandbox = Path(sys.argv[1]) if len(sys.argv)>1 else Path((ev/'sandbox-path.txt').read_text().strip())
assert sandbox.parent == repo and sandbox.name.startswith('.nm-focused-')
base = sandbox/'signals'
base.mkdir()
(base/'tmp').mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) or key in ('TMUX', 'TMUX_PANE', 'BASH_ENV'):
        env.pop(key)
env.update(HOME=str(sandbox/'home'), CLAUDE_CONFIG_DIR=str(sandbox/'claude'),
           TMPDIR=str(base/'tmp'), FM_HOME=str(sandbox/'lab'), FM_TEST_MACHINE_GATE='')
records = []

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

with (ev/'runner-signal-transcript.log').open('w') as transcript:
    for name, sig, group, expected in [('pid-KILL', signal.SIGKILL, False, -9),
                                        ('group-KILL', signal.SIGKILL, True, -9),
                                        ('group-INT', signal.SIGINT, True, 130)]:
        case = base/name
        case.mkdir()
        starts, cleaned, later = (case/x for x in ('starts', 'cleaned', 'later'))
        fixture = case/'wait.test.sh'
        fixture.write_text('''#!/usr/bin/env bash
trap 'echo "fixture: TERM cleanup finished"; echo "TERM" >> "$PROBE_CLEANED"; exit 143' TERM
trap 'echo "fixture: INT cleanup finished"; echo "INT" >> "$PROBE_CLEANED"; exit 130' INT
sleep 600 &
echo "$$ $!" > "$PROBE_STARTS"
echo "fixture: suite and child started"
wait
''')
        second = case/'later.test.sh'
        second.write_text('#!/usr/bin/env bash\necho started > "$PROBE_LATER"\n')
        command = ['bash', 'bin/fm-test-run.sh', '--jobs', '1', str(fixture), str(second)]
        case_env = env | {'PROBE_STARTS':str(starts), 'PROBE_CLEANED':str(cleaned), 'PROBE_LATER':str(later)}
        print('START', name, flush=True)
        with (case/'runner.out').open('w') as out:
            proc = subprocess.Popen(command, cwd=repo, env=case_env, stdout=out, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            try:
                deadline = time.monotonic()+30
                while not starts.exists() and proc.poll() is None and time.monotonic()<deadline:
                    time.sleep(0.1)
                assert starts.exists(), 'suite did not record its processes'
                pids = list(map(int, starts.read_text().split()))
                transcript.write('\nCASE '+name+'\n$ '+shlex.join(command)+'\n')
                transcript.write('suite_and_child_pids='+repr(pids)+' runner_pid='+str(proc.pid)+'\n')
                (os.killpg if group else os.kill)(proc.pid, sig)
                rc = proc.wait(timeout=30)
                deadline = time.monotonic()+20
                while any(alive(pid) for pid in pids) and time.monotonic()<deadline:
                    time.sleep(0.1)
                remaining = [pid for pid in pids if alive(pid)]
                output = (case/'runner.out').read_text()
                record = {'case':name, 'runner_exit':rc, 'surviving_pids':remaining,
                          'later_script_started':later.exists(),
                          'begin_markers':sum(x.startswith('FM_TEST_BEGIN ') for x in output.splitlines()),
                          'cleanup':cleaned.read_text().strip() if cleaned.exists() else ''}
                transcript.write(output+'\n'+json.dumps(record, sort_keys=True)+'\n')
                transcript.flush()
                assert rc == expected and not remaining and not later.exists() and record['begin_markers']==1
                assert record['cleanup'] == ('INT' if sig == signal.SIGINT else 'TERM')
                records.append(record)
                print('END', name, json.dumps(record), flush=True)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=30)
                if starts.exists():
                    for pid in map(int, starts.read_text().split()):
                        if alive(pid):
                            os.kill(pid, signal.SIGTERM)
(ev/'runner-signals.json').write_text(json.dumps(records, indent=2)+'\n')
