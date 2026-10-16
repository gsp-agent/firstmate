import json,os,subprocess,sys
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'
e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
session=(w/'session').read_text().strip()
pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
label=sys.argv[1]
def run(args):
    p=subprocess.run(args,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(str(args)+': '+p.stderr)
    return p.stdout
info=run(['bin/fm-herdr-lab.sh','run',session,'pane','get',pane])
(e/(label+'-info.json')).write_text(info)
for source in ('visible','recent'):
    for fmt in ('text','ansi'):
        args=['bin/fm-herdr-lab.sh','run',session,'pane','read',pane,'--source',source,'--format',fmt]
        if source=='recent': args+=['--lines','200']
        (e/(label+'-'+source+'-'+fmt+'.txt')).write_text(run(args))
results={}
for name,cmd in [('base-state',['--base']),('state',[]),('content',['fm_backend_herdr_composer_content']),('capture',['fm_backend_herdr_composer_capture','ansi'])]:
    p=subprocess.run(['bash',str(w/'probe.sh'),*cmd],capture_output=True,text=True)
    (e/(label+'-'+name+'.txt')).write_text(p.stdout)
    if name!='capture': results[name]={'exit':p.returncode,'out':p.stdout}
print(json.dumps({'label':label,'scroll':json.loads(info)['result']['pane']['scroll'],'results':results}))
