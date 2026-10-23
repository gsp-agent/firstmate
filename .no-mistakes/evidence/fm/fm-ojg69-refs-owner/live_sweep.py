import os, pathlib, json, subprocess, shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5KWW866PPTDFWE4PRBJYGC7')
L=R/'.local-test-tmp/sweep'; L.mkdir()
H=L/'home'; H.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','BEADS_','BR_','GIT_CONFIG_','XDG_'))}
env.update(HOME=str(H), FM_HOME=str(L),TMPDIR=str(L),DCG_HOOK_TIMEOUT_MS='2000',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
log=open(E/'live-sweep.log','w',buffering=1)
def note(s): print(s,flush=True);print(s,file=log)
def run(args,cwd=L,check=True):
    import shlex
    p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,capture_output=True,timeout=150)
    note('$ '+shlex.join(list(map(str,args)))+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    if check: assert p.returncode==0,p.stderr
    return p
for prefix,rel in [('bd','dev/be-still'),('obs','dev/agent-observer')]:
    d=H/rel; d.mkdir(parents=True)
    run(['br','init','--prefix',prefix],d)
    b=run(['br','create','Sweep evidence','--description','[capture](proof.png)','--silent'],d).stdout.strip()
    t=L/'data'/('task-'+prefix); (t/'record').mkdir(parents=True)
    (t/'brief.md').write_text('Bead '+b+'\n')
    (t/'proof.png').write_bytes(b'evidence bytes')
    (t/'scratch.bin').write_bytes(b'X'*(4*1024*1024))
    (t/'record/data-cleanup.json').write_text(json.dumps({'version':1,'task':t.name,'complete':False,'expired':False,'sources':[{'project':str(L/'projects/missing'),'pr':'','beads':[b],'backlog':{'data':str(L/'data'),'task':None}}]}))
(L/'state').mkdir(); (L/'config').mkdir()
(L/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\n')
(L/'data/backlog.md').write_text('# Backlog\n\n## Done\n')
blocked=H/'dev/be-still/.beads'; offline=blocked.with_name('.beads-offline'); blocked.rename(offline)
def scratch(): return sum(p.stat().st_size for p in (L/'data').glob('*/scratch.bin'))
def measure(label):
    note(label+': scratch_bytes='+str(scratch()))
    run(['du','-sk',L/'data']);run(['df','-k',L])
measure('Before sweep'); assert scratch()==8*1024*1024
try:
    run(['bash',R/'bin/fm-task-data-lib.sh','sweep',L/'data',L/'state'],check=False)
    assert scratch()==4*1024*1024
    assert json.loads((L/'data/task-obs/record/data-cleanup.json').read_text())['expired']
    assert (L/'data/task-bd/proof.png').read_bytes()==b'evidence bytes'
    assert (L/'data/task-bd/scratch.bin').read_bytes()==b'X'*(4*1024*1024)
    assert not (L/'data/task-bd/.cleanup-hold').exists()
    measure('After sweep with one unreadable owner')
finally: offline.rename(blocked)
run(['bash',R/'bin/fm-task-data-lib.sh','sweep',L/'data',L/'state'])
assert scratch()==0
for prefix in ('bd','obs'):
    t=L/'data'/('task-'+prefix)
    assert (t/'proof.png').read_bytes()==b'evidence bytes'
    assert json.loads((t/'record/data-cleanup.json').read_text())['expired']
measure('After restored-owner retry')
note('PASS: real sweep freed 8 MiB of scratch in two passes, held unreadable-owner data whole, and preserved both linked evidence files')
shutil.copyfile(__file__,E/'live_sweep.py')
