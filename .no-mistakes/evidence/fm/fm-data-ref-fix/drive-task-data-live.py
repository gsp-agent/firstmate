#!/usr/bin/env python3
"""Drive real teardown and Beads readers in workspace-local disposable homes."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT=Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M52RE89MCRBDJ3XPJ4P07HTS')
EVIDENCE=Path('/Users/dalecarman/.no-mistakes/evidence/01M52RE89MCRBDJ3XPJ4P07HTS')
SCRATCH=ROOT/'.test-task-data-live'/'validated'
SCRATCH.mkdir(parents=True)
(SCRATCH/'tmp').mkdir()
TRANSCRIPT=(EVIDENCE/'task-data-live-transcript.txt').open('w',buffering=1)
RESULTS=[]
BASE_ENV=os.environ.copy()
for key in list(BASE_ENV):
    if key.startswith(('FM_', 'GIT_', 'BEADS_', 'BR_', 'TASKS_AXI_', 'DCG_')) or key in ('TMUX','TMUX_PANE'):
        BASE_ENV.pop(key)
BASE_ENV.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(SCRATCH/'tmp'),NO_COLOR='1')

def run(args, *, cwd=ROOT, env=None, check=True):
    args=[str(a) for a in args]
    TRANSCRIPT.write('\n$ '+shlex.join(args)+'\ncwd: '+str(cwd)+'\n')
    p=subprocess.run(args,cwd=cwd,env=env or BASE_ENV,text=True,capture_output=True,timeout=150)
    TRANSCRIPT.write('[production source extraction omitted]\n' if args[:2]==['git','show'] else p.stdout)
    if p.stderr:
        TRANSCRIPT.write('stderr:\n'+p.stderr)
    TRANSCRIPT.write('exit: '+str(p.returncode)+'\n')
    if check and p.returncode:
        raise RuntimeError('command failed: '+shlex.join(args)+'\n'+p.stderr)
    return p

def require(condition,message):
    if not condition:
        raise AssertionError(message)

def make_case(name):
    case=SCRATCH/('live-'+name)
    case.mkdir()
    instance=case/'instance'
    run([ROOT/'bin/fm-lab-home.sh','create',instance])
    user=case/'user'
    user.mkdir()
    env=BASE_ENV.copy()
    env.update(HOME=str(user),FM_HOME=str(instance),XDG_CONFIG_HOME=str(user/'config'),XDG_CACHE_HOME=str(user/'cache'),XDG_DATA_HOME=str(user/'data'))
    project=instance/'projects'/'sample'
    run(['git','init','-q',project],env=env)
    (instance/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (instance/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (instance/'state/.last-watcher-beat').touch()
    return dict(name=name,case=case,instance=instance,env=env,project=project)

def add_row(c,task,body=''):
    run(['tasks-axi','add',task,'Disposable validation '+task,'--start','--body',body or 'Disposable task for live cleanup validation','--file',c['instance']/'data/backlog.md'],env=c['env'],cwd=c['instance'])

def create_bead(c,owner,prefix):
    owner.mkdir(parents=True,exist_ok=True)
    run(['br','init','--prefix',prefix,'--actor','local-validation'],cwd=owner,env=c['env'])
    p=run(['br','create','Evidence in '+prefix,'--description','[capture](proof.png)','--actor','local-validation','--json'],cwd=owner,env=c['env'])
    return json.loads(p.stdout)['id']

def seed_task(c,task,beads):
    add_row(c,task)
    root=c['instance']/'data'/task
    root.mkdir()
    (root/'brief.md').write_text(''.join('Bead '+b+'\n' for b in beads))
    (root/'proof.png').write_bytes(b'real owner evidence\x00\x01')
    (root/'discard.bin').write_bytes(b'unlinked scratch\x00\x02')
    (root/'nested').mkdir()
    (root/'nested/extra.bin').write_bytes(b'nested scratch\x00\x03')
    (c['instance']/'state'/f'{task}.meta').write_text(f'worktree={c["instance"]}/projects/gone-{task}\nproject={c["project"]}\nkind=ship\nmode=local-only\nbackend=tmux\nendpoint_task_id={task}\n')
    return root

def snapshot(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file() and str(p.relative_to(root))!='record/data-cleanup.json'}

def record(root):
    return json.loads((root/'record/data-cleanup.json').read_text())

def close_task(c,task,poison=False):
    env=c['env'].copy()
    if poison:
        env.update(BEADS_DIR=str(c['case']/'wrong-owner'),BEADS_DB=str(c['case']/'wrong-owner.db'),BR_DB=str(c['case']/'wrong-owner.db'))
        TRANSCRIPT.write('\nIsolation challenge: BEADS_DIR, BEADS_DB, BR_DB point at nonexistent paths inside this disposable case.\n')
    p=run([ROOT/'bin/fm-teardown.sh',task],env=env)
    row=run(['tasks-axi','show',task,'--file',c['instance']/'data/backlog.md'],cwd=c['instance'],env=c['env'])
    require('state: done' in row.stdout,'backlog did not reach done')
    require(not (c['instance']/'state'/f'{task}.meta').exists(),'task metadata still live')
    require(not (c['instance']/'state'/f'{task}.backlog-close').exists(),'backlog close remains pending')
    return p,row.stdout

def capture(name,c,task,extra=None):
    root=c['instance']/'data'/task
    result=dict(name=name,result='pass',live=True,task=task,files=snapshot(root),cleanup_record=record(root),extra=extra or {})
    RESULTS.append(result)
    TRANSCRIPT.write('\nObserved persisted state:\n'+json.dumps(result,indent=2)+'\n')
    (EVIDENCE/'task-data-live-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    print('PASS '+name,flush=True)

# Extract only the two changed production files from the immediate pre-fix head.
# Sibling dependencies use the checked-out code; no other checkout or live home is read.
old_bin=SCRATCH/'pre-fix-bin'
old_bin.mkdir()
for path in (ROOT/'bin').iterdir():
    if path.name not in ('fm-task-data.py','fm-task-data-lib.sh'):
        (old_bin/path.name).symlink_to(path,target_is_directory=path.is_dir())
for name in ('fm-task-data.py','fm-task-data-lib.sh'):
    result=run(['git','show','8ca0dc62:bin/'+name])
    (old_bin/name).write_text(result.stdout)

baseline=[]
for variant,prefix in [('dotted','.agent-config'),('gsp','gsp'),('project','proof'),('fallback','proof'),('unread','proof'),('reserved-unread','gsp')]:
    c=make_case(variant)
    if variant=='dotted':
        owner=Path(c['env']['HOME'])/'.agent-config'
    elif variant in ('gsp','reserved-unread'):
        owner=Path(c['env']['HOME'])/'dev/gsp-beads'
    else:
        owner=c['project']
    bead=create_bead(c,owner,prefix)
    if variant in ('fallback','unread'):
        bead='missing-q9'
    if variant=='reserved-unread':
        bead='gsp-missing-q9'
    if variant in ('fallback','reserved-unread'):
        add_row(c,bead,'[capture](proof.png)')
    if variant=='project':
        add_row(c,bead,'[wrong database](decoy.png)')
    task='lab-'+variant+'-a1'
    beads=[bead]
    if variant=='unread':
        readable=create_bead(c,Path(c['env']['HOME'])/'.agent-config','.agent-config')
        beads=[readable,bead]
    root=seed_task(c,task,beads)
    if variant=='project':
        (root/'decoy.png').write_bytes(b'decoy database evidence')
    before=snapshot(root)
    if variant in ('dotted','gsp','unread'):
        p=run(['python3',old_bin/'fm-task-data.py','prepare',c['instance']/'data',c['instance']/'state',task],env=c['env'],check=False)
        require(p.returncode!=0,'reported pre-fix failure did not reproduce')
        baseline.append(dict(case=variant,exit=p.returncode,stderr=p.stderr))
    p,row=close_task(c,task,poison=True)
    receipt=record(root)
    if variant in ('unread','reserved-unread'):
        require(before==snapshot(root),'unread reference changed original bytes or locations')
        require(not (root/'.cleanup-hold').exists(),'unread reference staged files')
        require(receipt['complete'] is False,'unread reference marked cleanup complete')
        require(receipt['sources'][0]['unread']==[bead],'unread identifier not persisted precisely')
        require(bead in p.stderr,'unread identifier not printed')
        capture(variant+' keeps all bytes and closes backlog',c,task,dict(before_sha256=before,backlog=row,unread_warning=p.stderr))
        if variant=='unread':
            # A real subsequent teardown must retry the unread receipt and leave it intact.
            next_task='lab-retry-still-unread-a1'
            seed_task(c,next_task,[])
            close_task(c,next_task)
            require(before==snapshot(root),'still-unread retry changed original data')
            require(record(root)['sources'][0]['unread']==[bead],'retry forgot unread id')
            capture('next teardown retries still-unread reference safely',c,task)
            # Make the same id readable in the fallback backlog, then complete another task.
            add_row(c,bead,'[capture](proof.png)')
            final_task='lab-retry-readable-a1'
            seed_task(c,final_task,[])
            close_task(c,final_task)
            require(record(root)['sources'][0]['unread']==[],'resolved retry retained stale unread id')
            require((root/'proof.png').read_bytes()==b'real owner evidence\x00\x01','retry lost evidence')
            require((root/'.cleanup-hold/discard.bin').read_bytes()==b'unlinked scratch\x00\x02','retry did not stage scratch')
            require((root/'.cleanup-hold/nested/extra.bin').read_bytes()==b'nested scratch\x00\x03','retry did not stage nested scratch')
            capture('next teardown resolves reference and starts a full recovery cycle',c,task)
    else:
        require((root/'proof.png').read_bytes()==b'real owner evidence\x00\x01','named bead evidence was moved or changed')
        require((root/'.cleanup-hold/discard.bin').read_bytes()==b'unlinked scratch\x00\x02','unlinked scratch was not staged')
        require(receipt['sources'][0]['unread']==[],'resolved bead recorded as unread')
        if variant=='project':
            require((root/'.cleanup-hold/decoy.png').exists(),'backlog decoy overrode project owner')
        capture(variant+' routes evidence and closes backlog',c,task,dict(bead=bead,owner=str(owner),backlog=row))

(EVIDENCE/'task-data-pre-fix-results.json').write_text(json.dumps(baseline,indent=2)+'\n')
print('Completed real CLI checks; pre-fix prepare failed in all three required cases.',flush=True)
