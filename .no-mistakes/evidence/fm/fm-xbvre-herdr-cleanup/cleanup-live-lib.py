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
# The caller owns its transcript; existing evidence is preserved.
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
