from pathlib import Path
import json, os, subprocess, time
root=Path.cwd()
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round2')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','TASKS_AXI_','NM_'))}
env.update(json.loads((evidence/'env.json').read_text()))
results=[]
for label,args,extra in [
    ('nm-run-default',['bash','tests/fm-nm-run-lib.test.sh'],{}),
    ('nm-run-bash',['bash','tests/fm-nm-run-lib.test.sh'],{'FM_TIMEOUT_MECHANISM_OVERRIDE':'bash'}),
    ('timeout-lib',['bash','tests/fm-timeout-lib.test.sh'],{}),
    ('review-diff',['bash','tests/fm-review-diff.test.sh'],{})]:
    start=time.monotonic()
    with (evidence/(label+'.test.log')).open('w') as log:
        p=subprocess.run(args,cwd=root,env=env|extra,stdout=log,stderr=log,timeout=180)
    row={'test':label,'command':args,'extra_env':extra,'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,4)}
    results.append(row)
    print(json.dumps(row),flush=True)
(evidence/'targeted-tests.json').write_text(json.dumps(results,indent=2))
raise SystemExit(any(r['exit'] for r in results))
