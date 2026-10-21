import json
import os
import subprocess
from pathlib import Path

root = Path.cwd()
lab = root/'.gate-validation'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F6DBZ4BWZT50JTY1CDEKMR')
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_')):
        env.pop(key, None)
env.update(PATH=str(lab/'toolbin')+os.pathsep+env['PATH'],
           LIVE_REAL_GH='/opt/homebrew/bin/gh',
           LIVE_GH_TRACE=str(evidence/'merge-live-gh-trace.jsonl'),
           FM_HOME=str(lab/'merge-home'))
home = lab/'merge-home'
for child in ['state','data','config']:
    (home/child).mkdir(parents=True,exist_ok=True)
reports = []
for name,number in [('draft',14781),('closed',14765),('open',14727)]:
    url = f'https://github.com/cli/cli/pull/{number}'
    meta = home/'state'/f'{name}.meta'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nworktree={root}\nproject={root}\npr={url}\n')
    meta.chmod(0o600)
    trace = evidence/'merge-live-gh-trace.jsonl'
    before = len(trace.read_text().splitlines()) if trace.exists() else 0
    result = subprocess.run(['bash',str(root/'bin/fm-pr-merge.sh'),name,url],
                            env=env,capture_output=True,text=True,timeout=120)
    calls = [json.loads(line) for line in trace.read_text().splitlines()[before:]]
    report = {'scenario':name,'url':url,'exit':result.returncode,
              'stdout':result.stdout,'stderr':result.stderr,
              'commands':[call['args'] for call in calls]}
    reports.append(report)
    (evidence/'live-merge-results.json').write_text(json.dumps(reports,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)
    cheap = [c for c in calls if c['args'][:2]==['pr','view'] and 'mergeable' in ' '.join(c['args'])]
    rollup = [c for c in calls if c['args'][:2]==['pr','view'] and 'statusCheckRollup' in ' '.join(c['args'])]
    assert result.returncode == 1
    assert len(cheap)==1, 'did not reach cheap mergeability read'
    assert 'statusCheckRollup' not in ' '.join(cheap[0]['args'])
    if name in ['closed','draft']:
        assert not rollup
        assert ('not open' if name=='closed' else 'draft') in result.stderr
    else:
        assert len(rollup)==1
        assert 'headRefOid,statusCheckRollup' in rollup[0]['args']
        assert cheap[0]['time'] < rollup[0]['time']
        assert json.loads(cheap[0]['stdout'])['headRefOid'] == json.loads(rollup[0]['stdout'])['headRefOid']
    assert all(c['args'][:2]!=['pr','merge'] for c in calls)
