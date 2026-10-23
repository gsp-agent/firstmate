import os, sys, json, subprocess, pathlib, time, sqlite3, shutil, shlex
ROOT = pathlib.Path.cwd()
EVID = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5KWW866PPTDFWE4PRBJYGC7')
LAB = ROOT / '.local-test-tmp/live-confirmed'
LAB.mkdir()
HOME = LAB / 'home'
HOME.mkdir()
env = {k:v for k,v in os.environ.items() if not (k.startswith(('FM_', 'TASKS_AXI_', 'BEADS_', 'BR_', 'GIT_CONFIG_', 'XDG_')) or k in ('TMUX','HERDR_SESSION_ID'))}
env.update(HOME=str(HOME), FM_HOME=str(LAB), TMPDIR=str(LAB), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', FM_TEARDOWN_DATA_STAGE_TIMEOUT='120', DCG_HOOK_TIMEOUT_MS='2000')
log = open(EVID / 'live-task-data.log', 'w', buffering=1)
results = []
def note(s):
    print(s, flush=True); print(s, file=log)
def run(args, cwd=LAB, extra=None, check=False):
    e = env | (extra or {})
    start = time.monotonic()
    p = subprocess.run(list(map(str,args)), cwd=cwd, env=e, capture_output=True, text=True, timeout=150)
    note('$ ' + shlex.join(list(map(str,args))))
    note('exit=%s elapsed=%.2fs\n%s%s' % (p.returncode,time.monotonic()-start,p.stdout,p.stderr))
    if check and p.returncode: raise RuntimeError(p.stderr or p.stdout)
    return p

def scenario(name, func):
    try:
        func()
        results.append({'name':name,'result':'pass','live':True})
        note('PASS: '+name)
    except Exception as e:
        results.append({'name':name,'result':'fail','live':True,'error':str(e)})
        note('FAIL: '+name+': '+str(e))
    (EVID/'live-results.json').write_text(json.dumps(results, indent=2)+'\n')

def create_db(rel, prefix):
    directory = HOME / rel
    directory.mkdir(parents=True, exist_ok=True)
    run(['br','init','--prefix',prefix],directory,check=True)
    p=run(['br','create','Evidence reference','--description','[capture](proof.png)','--silent'],directory,check=True)
    return directory/'.beads/beads.db', p.stdout.strip()

D = {}
for rel,prefix in [('.agent-config-beads','.agent-config'),('dev/be-still','bd'),('dev/heru-vr-vision-sim','heru'),('dev/gj-tool','gj'),('dev/gj-gitlab-config','gj-gitlab-config'),('dev/agent-observer','obs')]:
    D[prefix] = create_db(rel,prefix)

def case(name, beads=(), row='', legacy=None, project=None, saved_pr=''):
    c=LAB/name
    for sub in ('data/task-x1/record','state','config','history'):
        (c/sub).mkdir(parents=True)
    (c/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "history/completed.md"\n')
    (c/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (c/'history/completed.md').write_text(row)
    task=c/'data/task-x1'
    (task/'brief.md').write_text('Named beads: '+' '.join(beads)+'\n')
    (task/'proof.png').write_bytes(b'linked evidence\x00\xff')
    (task/'discard.bin').write_bytes(b'scratch\x00\xfe')
    src={'project':str(project or c/'projects/missing'), 'pr':saved_pr, 'beads':list(beads), 'backlog':{'data':str(c/'data'),'task':'task-x1' if legacy is not None else None}}
    if legacy:
        src['backlog'].update(legacy=True,text=row)
    (task/'record/data-cleanup.json').write_text(json.dumps({'version':1,'task':'task-x1','complete':False,'expired':False,'sources':[src]}))
    return c,task

def record(task): return json.loads((task/'record/data-cleanup.json').read_text())
def expire(c, extra=None):
    return run(['bash',ROOT/'bin/fm-task-data-lib.sh','expire',c/'data',c/'state','task-x1'],c,extra)
def kept(task):
    assert (task/'proof.png').read_bytes()==b'linked evidence\x00\xff'
    assert (task/'discard.bin').read_bytes()==b'scratch\x00\xfe'
    assert not (task/'.cleanup-hold').exists()
def expired(task, proof=True):
    assert record(task)['expired'] is True, record(task)
    assert not (task/'discard.bin').exists()
    assert not (task/'.cleanup-hold').exists()
    assert (task/'proof.png').exists()==proof
    note('persisted cleanup state: '+json.dumps(record(task),sort_keys=True))
    note('remaining files: '+', '.join(str(p.relative_to(task)) for p in sorted(task.rglob('*')) if p.is_file()))

def owned(prefix):
    db,bead=D[prefix]
    c,task=case('owned-'+prefix.replace('.',''), [bead])
    assert not (c/'projects/missing').exists()
    p=expire(c, {'BEADS_DIR':'/intentionally-wrong','BEADS_DB':'/intentionally-wrong','BR_DB':'/intentionally-wrong'})
    assert p.returncode==0,p.stderr
    expired(task)
for prefix in D:
    scenario('Missing recorded checkout resolves '+prefix+' bead in its prefix-owned real SQLite database despite inherited database overrides',lambda prefix=prefix:owned(prefix))

def not_found():
    c,task=case('not-found',['.agent-config-zzzz9','unowned-fixture'])
    p=expire(c); assert p.returncode==0,p.stderr
    expired(task,False)
    assert not record(task)['sources'][0]['unread']
scenario('Owner answers not found and unregistered absent ID: sweep deletes all unlinked data',not_found)

def fallback():
    c,task=case('fallback',['task-y2'],row='## Archived\n- [x] task-y2 - linked evidence (done 2026-10-20)\n  [capture](proof.png)\n')
    p=expire(c); assert p.returncode==0,p.stderr
    expired(task)
scenario('A named task moved into the configured archive still protects its linked evidence',fallback)

def unreadable():
    db,bead=D['bd']
    saved=db.parent.with_name('.beads-offline')
    db.parent.rename(saved)
    try:
        c,task=case('unreadable',[bead])
        p=expire(c); assert p.returncode!=0
        kept(task)
        assert bead in record(task)['sources'][0]['unread']
        note('Unread database preserved both original payload files and recorded '+bead)
    finally: saved.rename(db.parent)
    p=expire(c); assert p.returncode==0,p.stderr
    expired(task)
scenario('Unreadable owning database preserves the whole folder, then retry after database repair expires only scratch',unreadable)

def timeout():
    db,bead=D['heru']
    c,task=case('locked-db',[bead])
    connection=sqlite3.connect(db)
    # DELETE mode and an EXCLUSIVE writer block real br reads beyond their 10-second deadline.
    connection.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    connection.execute('PRAGMA journal_mode=DELETE')
    connection.execute('BEGIN EXCLUSIVE')
    try:
        start=time.monotonic(); p=expire(c); elapsed=time.monotonic()-start
        assert p.returncode!=0,p.stdout
        kept(task)
        assert bead in record(task)['sources'][0]['unread']
        assert elapsed>=9,elapsed
        note('Real SQLite lock held for %.2fs; cleanup retained every payload and marked the bead unread'%elapsed)
    finally:
        connection.rollback(); connection.close()
    p=expire(c); assert p.returncode==0,p.stderr
    expired(task)
scenario('Timed-out real SQLite read retains all data and succeeds after the lock is released',timeout)

def identity(kind,variant):
    checkout=LAB/('checkout-'+kind+'-'+variant)/('firstmate-upstream' if variant=='alias' else 'agent-config')
    checkout.mkdir(parents=True)
    run(['git','init','-q',checkout],check=True)
    run(['git','-C',checkout,'remote','add','origin','https://github.com/gsp-agent/'+('firstmate' if variant=='alias' else 'agent-config')+'.git'],check=True)
    name='firstmate' if variant=='alias' else ('agent-observer' if variant=='changed' else 'agent-config')
    row_pr='https://github.com/gsp-agent/agent-config/pull/304' if variant=='review' else ''
    row=f'## Archived\n- [x] task-x1 - finished {row_pr} (repo: {name}) (done 2026-10-20)\n  [capture](proof.png)\n'
    c,task=case('identity-'+kind+'-'+variant,row=row,legacy=(kind=='legacy'),project=checkout)
    p=expire(c)
    if variant=='changed':
        assert p.returncode!=0
        kept(task)
        assert 'changed project or PR' in p.stderr
        note('Changed repository refused expiry; both payloads remain byte-for-byte')
    else:
        assert p.returncode==0,p.stderr
        expired(task)
for kind in ('legacy','archived'):
    for variant in ('path','alias','review','changed'):
        scenario(kind+' completed row '+variant+': same repository expires scratch; changed repository retains everything',lambda kind=kind,variant=variant:identity(kind,variant))

def tied(kind,order):
    project=LAB/'saved-checkout/agent-config'
    project.mkdir(parents=True,exist_ok=True)
    pr='https://github.com/gsp-agent/agent-config/pull/185'
    rows=[pr,''] if order=='blank-last' else ['',pr]
    row='## Archived\n'+''.join(f'- [x] task-x1 - finished {p} (repo: agent-config) (done 2026-10-20)\n  [capture](proof.png)\n' for p in rows)
    c,task=case('tied-'+kind+'-'+order,row=row,legacy=(kind=='legacy'),project=project,saved_pr='https://github.com/gsp-agent/agent-config/pull/186')
    p=expire(c)
    assert p.returncode!=0
    kept(task)
    assert 'changed project or PR' in p.stderr
    assert record(task)['sources'][0]['pr'].endswith('/186')
    note('Saved owner PR186 and tied [PR185, blank] rows: expiry refused, no files moved, saved owner unchanged')
for kind in ('legacy','archived'):
    for order in ('blank-first','blank-last'):
        scenario(kind+' '+order+': a blank tied row cannot erase PR185 and permit deletion under saved PR186',lambda kind=kind,order=order:tied(kind,order))

note('Results: '+json.dumps(results))
log.close()
shutil.copyfile(__file__, EVID/'live_refs.py')
sys.exit(any(r['result']!='pass' for r in results))
