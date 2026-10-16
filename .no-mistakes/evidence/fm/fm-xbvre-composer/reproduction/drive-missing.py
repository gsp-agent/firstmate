import json,subprocess
from pathlib import Path
w=Path.cwd()/'.nm-composer-test'; e=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
s=(w/'session').read_text().strip(); pane=json.loads((w/'workspace.json').read_text())['result']['root_pane']['pane_id']
with (e/'missing-pane.log').open('w') as log:
    for args in [['bin/fm-herdr-lab.sh','run',s,'pane','close',pane],['bin/fm-herdr-lab.sh','run',s,'pane','get',pane],['bash',str(w/'probe.sh')]]:
        p=subprocess.run(args,capture_output=True,text=True)
        log.write('$ '+repr(args)+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n')
    assert p.stdout=='unknown',p.stdout
print('A closed lab pane returns unknown, never empty.')
