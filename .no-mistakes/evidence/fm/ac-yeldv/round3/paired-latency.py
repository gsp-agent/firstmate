from pathlib import Path
import json, os, subprocess, time

root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
f=json.loads((evidence/'fixture.json').read_text())
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
env['FM_LAB_PID_FILE']=str(root/'.nm-live-yeldv-r3/paired-remote-pids')
rows=[]
for pair in range(1,4):
    for name,args,cwd,extra in [
        ('direct-cli-no-fetch',['no-mistakes','axi','status'],f['slot'],{'GIT_NO_LAZY_FETCH':'1'}),
        ('bounded-product',['bash',str(root/'.nm-live-yeldv-r3/status-counterfactual.sh'),str(root/'bin/fm-nm-run-lib.sh'),f['slot']],root,{})]:
        start=time.monotonic()
        p=subprocess.run(args,cwd=cwd,env=env|extra,text=True,capture_output=True,timeout=25)
        row={'pair':pair,'interface':name,'elapsed_seconds':round(time.monotonic()-start,6),'exit':p.returncode,'has_gate_and_finding':'gate:' in p.stdout and 'LAB21,warning' in p.stdout}
        rows.append(row)
        (evidence/('paired-'+str(pair)+'-'+name+'.toon')).write_text(p.stdout+p.stderr)
        print(json.dumps(row),flush=True)
(evidence/'paired-latency.json').write_text(json.dumps(rows,indent=2))
