from pathlib import Path
import json, os, subprocess
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
f=json.loads((evidence/'fixture.json').read_text())
scratch=Path(f['scratch'])
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
driver=scratch/'function-latency-live.sh'
driver.write_text("""#!/usr/bin/env bash
. "$1/bin/fm-nm-run-lib.sh"
TIMEFORMAT='elapsed_seconds=%R'
for pair in 1 2 3 4 5; do
 for interface in direct-cli-no-fetch bounded-function; do
  out="$3/function-$pair-$interface.toon"
  timing="$3/function-$pair-$interface.time"
  if [ "$interface" = bounded-function ]; then
   if { time fm_nm_run_bounded "$2" 10 axi status > "$out"; } 2> "$timing"; then rc=0; else rc=$?; fi
  else
   if { time (cd "$2" && GIT_NO_LAZY_FETCH=1 no-mistakes axi status) > "$out"; } 2> "$timing"; then rc=0; else rc=$?; fi
  fi
  printf '%s %s %s\n' "$pair" "$interface" "$rc"
 done
done
""")
before=os.getloadavg()
p=subprocess.run(['bash',str(driver),str(root),f['slot'],str(evidence)],cwd=root,env=env,text=True,capture_output=True,timeout=120)
rows=[]
for line in p.stdout.splitlines():
 pair,interface,rc=line.split()
 timing=(evidence/('function-'+pair+'-'+interface+'.time')).read_text()
 elapsed=float([v.split('=',1)[1] for v in timing.splitlines() if v.startswith('elapsed_seconds=')][-1])
 out=(evidence/('function-'+pair+'-'+interface+'.toon')).read_text()
 rows.append({'pair':int(pair),'interface':interface,'exit':int(rc),'elapsed_seconds':elapsed,'has_gate_and_finding':'gate:' in out and 'LAB21,warning' in out})
proof={'timing_scope':'Bash built-in time around the callable function, after sourcing the library; no Git trace enabled','load_before':before,'load_after':os.getloadavg(),'driver_exit':p.returncode,'stderr':p.stderr,'reads':rows}
(evidence/'function-latency-proof.json').write_text(json.dumps(proof,indent=2))
print(json.dumps(proof,indent=2))
