#!/usr/bin/env python3
import collections, json, os, secrets, subprocess, time
from pathlib import Path
ROOT=Path.cwd()
E=Path('/Users/dalecarman/.no-mistakes/evidence/01M5BJC9DERBCXTG4TD2TYVSB4')
TMP=ROOT/'.test-cleanup-tmp'
HELPER=ROOT/'bin/fm-herdr-lab.sh'
ENV=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME','FM_HERDR_PS_BIN','FM_GATE_REFUSE_BYPASS','HERDR_SESSION','HERDR_SOCKET_PATH','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    ENV.pop(k,None)
ENV.update(TMPDIR=str(TMP),FM_HERDR_LAB_STATE_DIR=str(TMP/'lab-records'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
TRANSCRIPT=E/'cleanup-live.log'
TRANSCRIPT.write_text('Real cleanup against guarded Herdr labs; unmodified API responses.\n')
def log(s):
    print(s,flush=True)
    with TRANSCRIPT.open('a') as f: f.write(s+'\n')
def run(args,env=None,check=True):
    p=subprocess.run([str(x) for x in args],env=env or ENV,text=True,capture_output=True)
    if check and p.returncode: raise RuntimeError(str(args)+'\n'+p.stdout+p.stderr)
    return p
class Lab:
    def __init__(self,label):
        self.label=label
        self.name=run([HELPER,'name',label]).stdout.strip()
        self.work=TMP/self.name
        self.work.mkdir()
        self.home=self.work/'home'
        run([ROOT/'bin/fm-lab-home.sh','create',self.home])
        (self.home/'config/backend').write_text('herdr\n')
        (self.home/'config/herdr-presentation-spaces').touch()
        self.trace=E/(label+'-cli.jsonl'); self.trace.write_text('')
        self.counts=E/(label+'-journal-reads.log'); self.counts.write_text('')
        self.mutation=self.work/'mutation.json'
        self.shim=self.work/'transport'; self.shim.mkdir()
        (self.shim/'herdr').write_text(TRANSPORT)
        (self.shim/'herdr').chmod(0o755)
        self.runner=self.work/'run-cleanup.sh'; self.runner.write_text(RUNNER)
        self.ready=False
    def cli(self,*a,check=True): return run([HELPER,'run',self.name,*a],check=check)
    def api(self,*a): return json.loads(self.cli(*a).stdout)
    def provision(self):
        run([HELPER,'provision',self.name]); self.ready=True
        tripwire=TMP/'lab-records'/(self.name+'.fleet-state.json')
        (E/(self.label+'-tripwire-before.json')).write_text(tripwire.read_text())
        status=self.api('status','--json')
        log(f'{self.label}: {self.name}, Herdr {status["client"]["version"]}, protocol {status["server"]["protocol"]}')
    def teardown(self):
        if self.ready:
            run([HELPER,'teardown',self.name]); self.ready=False
            sessions=self.api('session','list','--json')['sessions']
            assert not any(s['name']==self.name for s in sessions)
            default=[{k:s[k] for k in ['name','default','running','socket_path']} for s in sessions if s['default']][0]
            (E/(self.label+'-tripwire-after.json')).write_text(json.dumps(default,indent=2)+'\n')
            log(self.label+': teardown confirmed absent; default-session tripwire unchanged')
    def anchor_create(self):
        d=self.api('workspace','create','--cwd',str(ROOT),'--label','test-anchor','--focus')['result']
        self.anchor={'workspace':d['workspace']['workspace_id'],'tab':d['tab']['tab_id'],'pane':d['root_pane']['pane_id']}
    def create(self,id,token=None,journal=True,version=1,home=None,pane=None):
        token=token or secrets.token_urlsafe(16)
        title='└ '+id.removeprefix('fm-')+' · p:'+token
        d=self.api('workspace','create','--cwd',str(ROOT),'--label',title,'--no-focus')['result']
        f={'id':id,'token':token,'title':title,'workspace':d['workspace']['workspace_id'],'tab':d['tab']['tab_id'],'pane':d['root_pane']['pane_id']}
        if journal: self.write_journal(f,version,home,pane)
        return f
    def content(self,f,version=1,home=None,pane=None,id=None,token=None):
        fields={'version':version,'task_id':id or f['id'],'projection_id':token or f['token']}
        if version==2:
            fields.update(home=str(home or self.home),session=self.name,workspace_id=f['workspace'],tab_id=f['tab'],pane_id=pane or f['pane'],parent_workspace_id=self.anchor['workspace'],parent_label='test-anchor',workspace_label=f['title'],task_label='fm-'+(id or f['id']))
        return ''.join(str(k)+'='+str(v)+'\n' for k,v in fields.items())
    def journal_path(self,id): return self.home/'state'/(id+'.herdr-presentation')
    def write_journal(self,f,version=1,home=None,pane=None,id=None,token=None):
        self.journal_path(id or f['id']).write_text(self.content(f,version,home,pane,id,token))
    def snapshot(self,label):
        d=self.api('api','snapshot')
        (E/(self.label+'-'+label+'.json')).write_text(json.dumps(d,indent=2)+'\n')
        return d['result']['snapshot']
    def cleanup(self,label,source=None):
        env=ENV.copy()
        env.update(FM_HOME=str(self.home),FM_BACKEND='herdr',HERDR_SESSION=self.name,PATH=str(self.shim)+os.pathsep+ENV['PATH'],TEST_ORIGINAL_PATH=ENV['PATH'],TEST_LAB_HELPER=str(HELPER),TEST_LAB_SESSION=self.name,TEST_CLI_TRACE=str(self.trace),TEST_MUTATION=str(self.mutation),TEST_JOURNAL_COUNTS=str(self.counts),TEST_CLEANUP_SOURCE=str(source or ROOT/'bin/fm-herdr-session-cleanup.sh'))
        lock=run([ROOT/'bin/fm-lock.sh'],env=env)
        start=time.monotonic(); p=run(['bash',self.runner],env=env); elapsed=round(time.monotonic()-start,3)
        (E/(self.label+'-'+label+'-output.log')).write_text(lock.stdout+lock.stderr+p.stdout+p.stderr)
        log(f'{self.label}/{label}: cleanup exit={p.returncode}, elapsed={elapsed}s; '+p.stderr.strip())
        return elapsed
    def present(self,f): return self.cli('pane','get',f['pane'],check=False).returncode==0
    def retained(self,f): return self.journal_path(f['id']).exists()
TRANSPORT='''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]
session=os.environ['TEST_LAB_SESSION']
if args[-2:]==['--session',session]: args=args[:-2]
if any(x=='--session' or x.startswith('--session=') for x in args):
    raise SystemExit('refusing caller session override')
with open(os.environ['TEST_CLI_TRACE'],'a') as f:
    f.write(json.dumps({'session':session,'args':args})+'\\n')
env=os.environ.copy(); env['PATH']=env['TEST_ORIGINAL_PATH']
p=subprocess.run([env['TEST_LAB_HELPER'],'run',session,*args],env=env,capture_output=True)
mutation=pathlib.Path(env['TEST_MUTATION'])
if args[:2]==['api','snapshot'] and mutation.exists() and p.returncode==0:
    changes=json.loads(mutation.read_text())
    for change in changes:
        target=pathlib.Path(change['path']); temp=target.with_name(target.name+'.next')
        temp.write_text(change['content']); temp.replace(target)
    mutation.rename(mutation.with_suffix('.applied'))
    with open(env['TEST_CLI_TRACE'],'a') as f:
        f.write(json.dumps({'mutation_after_real_snapshot':changes})+'\\n')
sys.stdout.buffer.write(p.stdout); sys.stderr.buffer.write(p.stderr)
raise SystemExit(p.returncode)
'''
RUNNER='''#!/usr/bin/env bash
set -u
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
. "$TEST_CLEANUP_SOURCE"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY
eval "$(declare -f fm_backend_herdr_projection_journal_snapshot | sed '1s/^[^ ]*/fm_live_original_journal_snapshot/')"
fm_backend_herdr_projection_journal_snapshot() {
  printf '%s\\n' "$2" >> "$TEST_JOURNAL_COUNTS"
  fm_live_original_journal_snapshot "$@"
}
fm_herdr_session_cleanup
'''
results=[]
lab=Lab('batch-70x55')
try:
    lab.provision(); lab.anchor_create()
    v1=lab.create('stale-v1'); v2=lab.create('stale-v2',version=2)
    unused=[lab.create('unmatched-'+str(i),journal=False) for i in range(53)]
    for i in range(68): lab.write_journal({'id':'journal-only-'+str(i),'token':secrets.token_urlsafe(16)})
    before=lab.snapshot('before')
    assert len(before['workspaces'])==56
    assert len(list((lab.home/'state').glob('*.herdr-presentation')))==70
    elapsed=lab.cleanup('batch')
    after=lab.snapshot('after')
    assert after['focused_workspace_id']==lab.anchor['workspace']
    assert after['focused_tab_id']==lab.anchor['tab']
    assert after['focused_pane_id']==lab.anchor['pane']
    assert not lab.present(v1) and not lab.present(v2)
    assert not lab.retained(v1) and not lab.retained(v2)
    assert all(lab.present(x) for x in unused)
    reads=collections.Counter(lab.counts.read_text().splitlines())
    assert sum(reads.values())==76,dict(reads)
    assert reads['stale-v1']==4 and reads['stale-v2']==4,dict(reads)
    assert all(v==1 for k,v in reads.items() if k.startswith('journal-only-'))
    metrics={'initial_journals':70,'title_matching_workspaces':55,'journal_snapshot_calls':sum(reads.values()),'calls_by_task':dict(reads),'closed_exact_panes':[v1['pane'],v2['pane']],'elapsed_seconds':elapsed}
    (E/'cleanup-batch-metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
    results.append({'name':'70 journals and 55 candidates use one batch; exact v1/v2 orphans close','result':'pass','metrics':metrics})
    log('batch-70x55: 70 initial reads + 3 exact-journal rechecks per closure = 76; 53 unmatched panes and exact focus preserved')
finally:
    lab.teardown()
lab=Lab('guards-and-races')
try:
    lab.provision(); lab.anchor_create()
    ambiguous=lab.create('ambiguous'); lab.write_journal(ambiguous,id='fm-ambiguous')
    duplicate=lab.create('duplicate'); copy=lab.create('token-copy',token=duplicate['token'],journal=False)
    meta=lab.create('current-task'); (lab.home/'state/current-task.meta').write_text('current-task-owned\n')
    other_home=lab.work/'other-home'; other_home.mkdir()
    foreign=lab.create('foreign-home',version=2,home=other_home)
    mismatch=lab.create('mismatched-binding',version=2,pane=lab.anchor['pane'])
    active=lab.create('active-target'); changed=lab.create('changed-journal')
    lab.cli('tab','focus',active['tab'])
    lab.mutation.write_text(json.dumps([{'path':str(lab.journal_path('changed-journal')),'content':lab.content(changed,token=secrets.token_urlsafe(16))}]))
    before=lab.snapshot('before-guards')
    lab.cleanup('guards'); after=lab.snapshot('after-guards')
    assert all(lab.present(f) for f in [ambiguous,duplicate,copy,meta,foreign,mismatch,active,changed])
    assert all(lab.retained(f) for f in [ambiguous,duplicate,meta,foreign,mismatch,active,changed])
    assert before['focused_workspace_id']==after['focused_workspace_id']==active['workspace']
    assert before['focused_tab_id']==after['focused_tab_id']==active['tab']
    assert lab.mutation.with_suffix('.applied').exists()
    log('guards: duplicate journals, duplicate workspace token, metadata, cross-home/bad v2 bindings, focused target, and changed journal all preserved')
    results.append({'name':'Ambiguous ownership and changed prerequisites preserve real panes and journals','result':'pass'})
    race=lab.create('late-duplicate')
    lab.mutation.write_text(json.dumps([{'path':str(lab.journal_path('fm-late-duplicate')),'content':lab.content(race,id='fm-late-duplicate')}]))
    lab.snapshot('before-late-duplicate'); lab.cleanup('late-duplicate'); lab.snapshot('after-late-duplicate')
    preserved=lab.present(race)
    result={'name':'A second matching journal after indexing preserves the candidate','result':'pass' if preserved else 'fail','pane':race['pane'],'original_journal_retained':lab.retained(race),'duplicate_journal_retained':lab.journal_path('fm-late-duplicate').exists()}
    results.append(result); log('late-duplicate race: '+json.dumps(result))
    previous=lab.create('late-before-fix')
    baseline=run(['git','show','d3bc4c32^:bin/fm-herdr-session-cleanup.sh']).stdout
    before_bin=lab.work/'baseline-bin'; before_bin.mkdir()
    for file in (ROOT/'bin').iterdir():
        if file.name!='fm-herdr-session-cleanup.sh': (before_bin/file.name).symlink_to(file)
    source=before_bin/'fm-herdr-session-cleanup.sh'; source.write_text(baseline)
    lab.mutation.write_text(json.dumps([{'path':str(lab.journal_path('fm-late-before-fix')),'content':lab.content(previous,id='fm-late-before-fix')}]))
    lab.cleanup('late-duplicate-before-fix',source=source); lab.snapshot('after-late-duplicate-before-fix')
    assert lab.present(previous) and lab.retained(previous)
    log('late-duplicate counterfactual: parent cleanup preserves the same raced journal/pane shape')
finally:
    lab.teardown()
(E/'cleanup-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
log('Live validation complete: '+json.dumps([{'name':x['name'],'result':x['result']} for x in results]))
raise SystemExit(1 if any(x['result']=='fail' for x in results) else 0)
