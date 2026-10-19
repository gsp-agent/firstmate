from pathlib import Path
import json, os, subprocess
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
f=json.loads((evidence/'fixture.json').read_text())
scratch=Path(f['scratch'])
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
driver=scratch/'scope-live.sh'
driver.write_text("""#!/usr/bin/env bash
if [ "$5" = on ]; then set -u; fi
before=$-
. "$1/bin/fm-nm-run-lib.sh"
[ "$-" = "$before" ] || exit 99
printf 'timeout mechanism: %s\n' "$(fm_timeout_mechanism)"
fm_nm_run_bounded "$2" 10 axi status || exit $?
printf 'parent lazy-fetch: %s\n' "${GIT_NO_LAZY_FETCH-unset}"
fm_nm_bounded "$3" 5 git cat-file -p "$4" || exit $?
printf 'parent options preserved: yes\n'
""")
blob=subprocess.check_output(['git','-C',f['seed'],'rev-parse','main:payload.txt'],env=env,text=True).strip()
rows=[]
for label,extra,nounset,want in [('unset',{},'off','unset'),('preexisting-zero',{'GIT_NO_LAZY_FETCH':'0'},'on','0')]:
 slot=scratch/('scope-'+label)
 subprocess.run(['git','clone','-q','--filter=blob:none','--no-checkout',Path(f['remote']).as_uri(),str(slot)],env=env,check=True)
 absent=subprocess.run(['git','-C',str(slot),'cat-file','-e',blob],env=env|{'GIT_NO_LAZY_FETCH':'1'},capture_output=True).returncode!=0
 trace=evidence/('scope-'+label+'-trace.jsonl')
 p=subprocess.run(['bash',str(driver),str(root),f['slot'],str(slot),blob,nounset],env=env|extra|{'GIT_TRACE2_EVENT':str(trace)},text=True,capture_output=True,timeout=25)
 calls=[v['argv'] for v in map(json.loads,trace.read_text().splitlines()) if v.get('event')=='start']
 lazy=[a for a in calls if 'fetch' in a and '--stdin' in a]
 row={'case':label,'nounset':nounset,'blob_initially_absent':absent,'exit':p.returncode,'status_gate_preserved':'gate:' in p.stdout and 'LAB21,warning' in p.stdout,'caller_environment_preserved':('parent lazy-fetch: '+want) in p.stdout,'generic_git_fetch_and_output_preserved':len(lazy)==1 and 'initial payload' in p.stdout,'shell_options_preserved':'parent options preserved: yes' in p.stdout,'generic_lazy_fetches':lazy}
 row['expected_surface']=all([absent,p.returncode==0,row['status_gate_preserved'],row['caller_environment_preserved'],row['generic_git_fetch_and_output_preserved'],row['shell_options_preserved']])
 rows.append(row)
 (evidence/('scope-'+label+'.txt')).write_text(p.stdout+p.stderr)
 print(json.dumps(row),flush=True)
(evidence/'scope-proof.json').write_text(json.dumps(rows,indent=2))
raise SystemExit(not all(v['expected_surface'] for v in rows))
