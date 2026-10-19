import copy
import json
import os
from pathlib import Path
import shlex
import subprocess

root=Path.cwd()
lab=root/'.agent-state/live-validation/lab'
evidence=Path('/Users/dalecarman/.no-mistakes/evidence/01M59T4BFDPQD71P8CHEHTBVJJ')
home=lab/'grok-account-home'
(home/'config').mkdir(parents=True)
rules={'default':[{'harness':'grok','model':'grok-4.7'},{'harness':'codex','model':'gpt-6-astra'}]}
(home/'config/crew-dispatch.json').write_text(json.dumps(rules))
base=json.loads((lab/'cache-input.json').read_text())
env=dict(os.environ,FM_HOME=str(home),QUOTA_AXI_SNAPSHOT=str(home/'quota-cache.json'),
         XDG_CONFIG_HOME=str(lab/'config-cli'),XDG_CACHE_HOME=str(lab/'cache'),TMPDIR=str(lab/'cache'))
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k,None)
lines=[]
results=[]
for usable in [False,True]:
    for reversed_order in [False,True]:
        cache=copy.deepcopy(base)
        selected=next(p for p in cache['providers'] if p['provider']=='grok')
        selected['accountKey']='default'
        other=copy.deepcopy(selected)
        other['accountKey']='other'
        selected['credits']['remaining']=48082 if usable else 0
        other['credits']['remaining']=0 if usable else 48082
        cache['providers'].insert(0,other)
        if reversed_order: cache['providers'].reverse()
        name='grok-default-account-'+('prepaid' if usable else 'exhausted')+('-reversed' if reversed_order else '')
        (home/'quota-cache.json').write_text(json.dumps(cache))
        lines.append('\nCASE: '+name+'\n')
        quota=subprocess.run(['quota-axi','--json','--no-credential-refresh'],env=env,text=True,capture_output=True,timeout=45)
        quota.check_returncode()
        lines.append('$ quota-axi --json --no-credential-refresh\n'+quota.stdout)
        data=json.loads(quota.stdout)
        assert data['schemaVersion']==6
        args=['bash','bin/fm-dispatch-resolve.sh','--labels','']
        p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=60)
        expected='grok' if usable else 'codex'
        passed=p.returncode==0 and "profile: --harness '"+expected+"'" in p.stdout
        lines.append('$ '+shlex.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]\n')
        results.append({'name':name,'pass':passed,'expected':expected,'output':p.stdout})
        print(name+': '+('PASS' if passed else 'FAIL'),flush=True)
(evidence/'grok-account-live-transcript.txt').write_text('\n'.join(lines))
(evidence/'grok-account-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
