import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
BASE = ROOT/'.test-phase/world-retry'
BASE.mkdir(parents=True, exist_ok=True)
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
os.environ['REVIEW_PAGE_HOME'] = str(BASE/'empty-pages')
os.environ['DALE_RECORDS_DIR'] = str(BASE/'empty-records')
RULE = Path('/Users/dalecarman/.agent-config/configs/claude/hooks/dale-asks-rule.py')
spec = importlib.util.spec_from_file_location('actual_asks_rule', RULE)
rule = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rule)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_')):
        env.pop(key)
env.update(TMPDIR=str(BASE/'tmp'), PYTHONDONTWRITEBYTECODE='1', FM_BACKLOG_ROW_TIMEOUT_SECS='60')
Path(env['TMPDIR']).mkdir(parents=True,exist_ok=True)
log = (EVIDENCE/'live-world-checks-retry-transcript.txt').open('w',buffering=1)
results = []

def run(argv, active, check=True):
    p = subprocess.run(argv, cwd=ROOT, env=active, text=True,capture_output=True,timeout=180)
    log.write('$ ' + shlex.join(str(x) for x in argv) + '\n' + p.stdout + p.stderr + 'exit=' + str(p.returncode) + '\n')
    if check and p.returncode:
        raise AssertionError(p.stdout+p.stderr)
    return p

def setup(mode, reason):
    base = BASE/mode
    run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(base)],env)
    (base/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (base/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    active = dict(env, FM_HOME=str(base), REVIEW_PAGE_HOME=str(base/'pages'), DALE_RECORDS_DIR=str(base/'records'))
    page = base/'pages/published'
    page.mkdir(parents=True)
    item = dict(id='signin',title='Disposable account access',ask=reason,recommend=reason,text=reason,if_no=reason,
                files=[],images=[],videos=[],diagrams=[])
    content = {'chapters':[{'items':[item]}]}
    renderer = rule.renderer()
    version, _ = renderer.fingerprint(item, None, {'attached':renderer.attached_files([item]), 'page':'published'})
    state = {'items':{'signin':{'hash':version,'added_at':'2026-01-01T00:00:00Z','changed_at':'2026-01-01T00:00:00Z'}}}
    (page/'content.json').write_text(json.dumps(content))
    (page/'state.json').write_text(json.dumps(state))
    (page/'index.html').write_text('<section id="i-signin"><div class="rp-ask" data-v="'+version+'"></div></section>')
    consumed = rule.asks_on(page,'published')
    assert len(consumed) == 1 and consumed[0]['_published'], 'fixture was not consumed as a real published ask'
    if mode == 'answered':
        answers = page/'answers'
        answers.mkdir()
        (answers/'answer.json').write_text(json.dumps({'item':'signin','action':'reply','text':'Already signed in','at':'2026-10-19T00:00:00Z'}))
    return active

def scenario(mode, reason, expected):
    start=time.monotonic()
    try:
        active=setup(mode,reason)
        check=run(['python3',str(RULE),'ask','--title','Disposable account access','--question',reason,'--recommend',reason,'--text',reason,'--if-no',reason],active,False)
        assert check.returncode == 3 and expected in check.stdout, 'the real rule did not emit the expected world-check action'
        for step in ('sign-in','screen'):
            cmd=[str(ROOT/'bin/fm-captain-hold.sh'),'hold',step,'--title','Disposable account access','--reason',reason,'--dale-step',step,'--probe','true']
            p=run(cmd,active,False)
            assert p.returncode != 0 and 'world check' in p.stderr
            assert run([str(ROOT/'bin/fm-tasks-axi.sh'),'show',step,'--full'],active,False).returncode != 0
        result=dict(name='Creation refuses '+mode+' world checks from the actual asks-rule CLI for matching published records',result='pass',live=True,reason='',seconds=round(time.monotonic()-start,2))
    except Exception as e:
        result=dict(name='Creation refuses '+mode+' world checks from the actual asks-rule CLI for matching published records',result='fail',live=True,reason=str(e))
    results.append(result)
    print(json.dumps(result),flush=True)

try:
    reason='[Sign in to your disposable account](https://example.invalid/login)?'
    scenario('answered',reason,'He decided it on review:published#signin.')
    scenario('duplicate',reason,'review:published#signin asks the same decision and came first')
    base=BASE/'nonblocking'
    run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(base)],env)
    (base/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (base/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    active=dict(env,FM_HOME=str(base),REVIEW_PAGE_HOME=str(base/'pages'),DALE_RECORDS_DIR=str(base/'records'))
    reason='choose the next implementation detail'
    p=run(['python3',str(RULE),'ask','--title','Implementation choice','--question',reason,'--recommend',reason,'--text',reason,'--if-no',reason],active,False)
    assert p.returncode == 3 and 'Not one of his kinds' in p.stdout and 'Not answerable in one read' in p.stdout
    run([str(ROOT/'bin/fm-captain-hold.sh'),'hold','nonblocking','--title','Implementation choice','--reason',reason,'--dale-step','screen','--probe','false'],active)
    shown=run([str(ROOT/'bin/fm-tasks-axi.sh'),'show','nonblocking','--full'],active).stdout
    assert 'held: yes' in shown
    result=dict(name='Creation ignores category and form refusals from the actual asks rule',result='pass',live=True,reason='')
    results.append(result)
    print(json.dumps(result),flush=True)
finally:
    (EVIDENCE/'live-world-checks-retry-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
