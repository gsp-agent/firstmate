import os, pathlib, subprocess, signal, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HJWD7NWSB5DVEKH4338NFV')
# Stop only the still-running broader test process and its owned descendants.
# Its EXIT trap retains responsibility for disposable test fixture cleanup.
def descendants(pid):
    children=subprocess.run(['pgrep','-P',str(pid)],stdout=subprocess.PIPE,text=True).stdout.split()
    result=[]
    for child in children:
        result.extend(descendants(int(child))); result.append(int(child))
    return result
for child in descendants(81843):
    try: os.kill(child,signal.SIGTERM)
    except ProcessLookupError: pass
try: os.kill(81843,signal.SIGTERM)
except ProcessLookupError: pass
# Execute the existing behavior regression's fixture builders and function,
# leaving the unrelated suite invocations out of this targeted selection.
source=(root/'tests/fm-project-capacity.test.sh').read_text()
definitions=source.split('\ntest_unreadable_crew_state_holds_a_place\n',1)[0]
definitions=definitions.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"',f'. "{root}/tests/lib.sh"',1)
selected=evidence/'capacity-targeted.test.sh'
selected.write_text(definitions+'\ntest_unreadable_crew_state_holds_a_place\n')
start=time.monotonic()
with (evidence/'capacity-targeted.log').open('w') as log:
    result=subprocess.run(['/bin/bash',str(selected)],cwd=root,stdout=log,stderr=subprocess.STDOUT)
    log.write(f'Focused existing regression exit={result.returncode}; elapsed={time.monotonic()-start:.3f}s\n')
raise SystemExit(result.returncode)
