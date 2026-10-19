from pathlib import Path
import json, os, subprocess
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round4')
f=json.loads((evidence/'fixture.json').read_text())
scratch=Path(f['scratch'])
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
driver=scratch/'spread-latency-live.sh'
driver.write_text("""#!/usr/bin/env bash
. "$1/bin/fm-nm-run-lib.sh"
TIMEFORMAT='elapsed_seconds=%R'
for sample in 1 2 3 4 5 6 7 8; do
 began=$SECONDS
 if { time fm_nm_run_bounded "$2" 10 axi status > "$3/spread-$sample.toon"; } 2> "$3/spread-$sample.time"; then rc=0; else rc=$?; fi
 printf '%s %s %s\n' "$sample" "$began" "$rc"
 [ "$sample" = 8 ] || sleep 25
done
""")
before=os.getloadavg()
p=subprocess.run(['bash',str(driver),str(root),f['slot'],str(evidence)],env=env,cwd=root,text=True,capture_output=True,timeout=330)
rows=[]
for line in p.stdout.splitlines():
 sample,began,rc=line.split()
 timing=(evidence/('spread-'+sample+'.time')).read_text()
 elapsed=float([v.split('=',1)[1] for v in timing.splitlines() if v.startswith('elapsed_seconds=')][-1])
 out=(evidence/('spread-'+sample+'.toon')).read_text()
 rows.append({'sample':int(sample),'at_seconds':int(began),'exit':int(rc),'elapsed_seconds':elapsed,'has_gate_and_finding':'gate:' in out and 'LAB21,warning' in out})
proof={'timing_scope':'Bash built-in time around fm_nm_run_bounded after sourcing the library, without Git tracing, eight samples separated by 25 seconds','load_before':before,'load_after':os.getloadavg(),'driver_exit':p.returncode,'stderr':p.stderr,'reads':rows}
(evidence/'spread-latency-proof.json').write_text(json.dumps(proof,indent=2))
print(json.dumps(proof,indent=2),flush=True)
