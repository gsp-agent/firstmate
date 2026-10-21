import json
import os
import shutil
import subprocess
import time
from pathlib import Path

root = Path.cwd()
lab = root / '.gate-validation'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5F6DBZ4BWZT50JTY1CDEKMR')
tool = lab / 'toolbin'
tool.mkdir(exist_ok=True)
real = shutil.which('gh')
wrapper = tool / 'gh'
wrapper.write_text('''#!/usr/bin/env python3
import os,sys,json,subprocess,time
args=sys.argv[1:]; real=os.environ['LIVE_REAL_GH']
allowed=(args[:2]==['pr','view']) or (args[:1]==['api'] and not any(x in args for x in ['POST','PUT','PATCH','DELETE']) and not any('mutation' in x for x in args))
if not allowed:
 print('live validation refuses remote mutation',file=sys.stderr); sys.exit(95)
auth=subprocess.run([real,'auth','token','--user','gsp-agent'],capture_output=True,text=True)
if auth.returncode: print('gsp-agent login unavailable',file=sys.stderr); sys.exit(96)
env=os.environ.copy(); env['GH_TOKEN']=auth.stdout.strip()
r=subprocess.run([real]+args,env=env,capture_output=True,text=True)
with open(os.environ['LIVE_GH_TRACE'],'a') as f: f.write(json.dumps({'time':time.time(),'args':args,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\\n')
sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
''')
wrapper.chmod(0o700)
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_')):
        env.pop(key, None)
env.update(PATH=str(tool)+os.pathsep+env['PATH'], LIVE_REAL_GH=real,
           LIVE_GH_TRACE=str(evidence/'github-live-trace.jsonl'), FM_HOME=str(lab/'home'))
for directory in ['state', 'config', 'data']:
    (lab/'home'/directory).mkdir(parents=True, exist_ok=True)
report = []

def run(args, extra=None, check=True):
    current = env.copy()
    current.update(extra or {})
    result = subprocess.run([str(x) for x in args], env=current, capture_output=True,
                            text=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(f'{args}: exit {result.returncode}: {result.stderr}')
    return result

def calls():
    return [json.loads(line) for line in (evidence/'github-live-trace.jsonl').read_text().splitlines()]

pulls = json.loads(run(['gh','api','repos/cli/cli/pulls','-X','GET','-f','state=all','-f','per_page=51']).stdout)
assert len(pulls) == 51
(evidence/'public-pr-sample.json').write_text(json.dumps([
    {'number':p['number'],'state':p['state'],'merged':bool(p['merged_at']),'draft':p['draft']}
    for p in pulls], indent=2)+'\n')
old = lab/'predecessor.sh'
old.write_text(run(['git','show','21da0930^:bin/fm-pr-poll.sh']).stdout)
arm = lab/'arm.sh'
arm.write_text('''#!/usr/bin/env bash
set -eu
. "$PWD/bin/fm-pr-lib.sh"
state=$1; id=$2; number=$3; template=$4
url="https://github.com/cli/cli/pull/$number"
mkdir -p "$state"
printf 'kind=ship\\nmode=no-mistakes\\npr=%s\\n' "$url" > "$state/$id.meta"
chmod 600 "$state/$id.meta"
fm_pr_poll_prepare "$state" "$id" github "$url" github.com cli/cli "$number" "$template"
fm_pr_poll_publish_prepared
''')
state = lab/'home'/'state'
for i,pull in enumerate(pulls):
    run(['bash',arm,state,f'pr-{i:02}',pull['number'],root/'bin/fm-pr-poll.sh'])
sample = [next(p for p in pulls if p['state']=='open'),
          next(p for p in pulls if p['merged_at']),
          next(p for p in pulls if p['state']=='closed' and not p['merged_at'])]
before = len(calls())
old_state = lab/'old-state'
baseline = []
for i,pull in enumerate(sample):
    run(['bash',arm,old_state,f'old-{i}',pull['number'],old])
    out = run(['bash',old_state/f'old-{i}.check.sh']).stdout.strip()
    baseline.append({'url':pull['html_url'],'result':out})
assert len(calls())-before == 3
report.append({'scenario':'predecessor baseline: three public PRs','graphql_calls':3,'outputs':baseline})
cache = lab/'batch-cache'
cache.touch(mode=0o600)
before = len(calls())
batch_env = {'FM_PR_POLL_BATCH_CACHE':str(cache)}
prefetch = run(['bash',root/'bin/fm-pr-poll.sh','--batch-prefetch',state],batch_env)
assert not prefetch.stdout and not prefetch.stderr
outputs = []
for i,pull in enumerate(pulls):
    result = run(['bash',state/f'pr-{i:02}.check.sh'],batch_env)
    expected = 'merged' if pull['merged_at'] else 'closed' if pull['state']=='closed' else ''
    assert result.stdout.strip() == expected, (pull['number'],result.stdout,expected)
    assert not result.stderr
    outputs.append({'url':pull['html_url'],'output':result.stdout.strip()})
batch_calls = calls()[before:]
assert len(batch_calls) == 1
assert batch_calls[0]['exit'] == 0
report.append({'scenario':'51 registered public PRs share one real GraphQL request','graphql_calls':len(batch_calls),'outputs':outputs})
cache.write_text('')
before = len(calls())
failure_env = dict(batch_env, HTTPS_PROXY='http://127.0.0.1:9', HTTP_PROXY='http://127.0.0.1:9', ALL_PROXY='http://127.0.0.1:9', NO_PROXY='')
prefetch = run(['bash',root/'bin/fm-pr-poll.sh','--batch-prefetch',state],failure_env)
assert not prefetch.stdout and not prefetch.stderr
for i,pull in enumerate(pulls):
    result = run(['bash',state/f'pr-{i:02}.check.sh'],failure_env)
    assert not result.stdout and not result.stderr
failure_calls = calls()[before:]
assert len(failure_calls) == 1 and failure_calls[0]['exit'] != 0
report.append({'scenario':'real network failure stays silent for all 51 PRs without individual retries','graphql_calls':1,'gh_exit':failure_calls[0]['exit'],'poll_stdout':'','poll_stderr':''})
(evidence/'live-poll-results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
