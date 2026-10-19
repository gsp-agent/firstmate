from pathlib import Path
import json, os, subprocess, time

root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round4')
f=json.loads((evidence/'fixture.json').read_text())
scratch=Path(f['scratch'])
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
child=scratch/'stdin-child.py'
child.write_text('import sys\nprint("received: "+sys.stdin.read().strip())\nprint("diagnostic stderr",file=sys.stderr)\nsys.exit(7)\n')
driver=scratch/'bounded-contract.sh'
driver.write_text('''#!/usr/bin/env bash
before_nounset=$-
. "$1/bin/fm-nm-run-lib.sh"
case "$-" in *u*) echo "unexpected nounset change" >&2; exit 99;; esac
fm_nm_bounded "$2" 5 python3 "$3"
rc=$?
printf 'child exit: %s; parent lazy-fetch: %s\n' "$rc" "${GIT_NO_LAZY_FETCH-unset}"
exit "$rc"
''')
rows=[]
for mechanism,extra in [('native',{}),('bash',{'FM_TIMEOUT_MECHANISM_OVERRIDE':'bash'})]:
    p=subprocess.run(['bash',str(driver),str(root),str(scratch),str(child)],input='payload through caller stdin\n',env=env|extra,cwd=root,text=True,capture_output=True,timeout=15)
    row={'scenario':'stdin, stdout, stderr, exit and caller settings: '+mechanism,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,
         'expected_surface':p.returncode==7 and 'received: payload through caller stdin\n' in p.stdout and 'child exit: 7; parent lazy-fetch: unset' in p.stdout and p.stderr=='diagnostic stderr\n'}
    rows.append(row)
    print(json.dumps(row),flush=True)

pid_file=scratch/'bash-remote-pids'
trace=evidence/'bash-process-trace.jsonl'
started=time.monotonic()
p=subprocess.run(['bash',str(scratch/'run-git-tree.sh'),str(root/'bin/fm-nm-run-lib.sh'),str(scratch/'timeout-slot')],env=env|{'FM_TIMEOUT_MECHANISM_OVERRIDE':'bash','FM_LAB_PID_FILE':str(pid_file),'GIT_TRACE2_EVENT':str(trace)},cwd=root,text=True,capture_output=True,timeout=20)
ids=[int(x) for x in pid_file.read_text().splitlines()]
states=[{'pid':pid,'state_after_return':subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,pgid=,stat=,comm='],text=True,capture_output=True).stdout.strip()} for pid in ids]
row={'scenario':'Bash fallback reaps a real Git fetch subtree','exit':p.returncode,'elapsed_seconds':round(time.monotonic()-started,4),'remote_descendants_started':ids,'descendants_after_return':states,'expected_surface':p.returncode==124 and bool(ids) and all(not s['state_after_return'] for s in states)}
rows.append(row)
print(json.dumps(row),flush=True)
(evidence/'bounded-contract-proof.json').write_text(json.dumps(rows,indent=2))
raise SystemExit(not all(r['expected_surface'] for r in rows))
