import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import traceback

ROOT = Path.cwd()
EVID = Path('/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX')
WORK = Path(tempfile.mkdtemp(prefix='.phase-live-', dir=ROOT))
(WORK / 'tmp').mkdir()
(WORK / 'xdg').mkdir()
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') and (key.endswith('_OVERRIDE') or key in ('FM_HOME', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'FM_TASK_ID')):
        ENV.pop(key, None)
for key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'BEADS_DIR', 'BEADS_DB', 'BR_DB', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'TYPESAFE_API_KEY'):
    ENV.pop(key, None)
ENV.update(TMPDIR=str(WORK / 'tmp'), XDG_CONFIG_HOME=str(WORK / 'xdg'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Lab tester', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab tester', GIT_COMMITTER_EMAIL='lab@example.invalid')
RESULTS = []
LOG = None
PROCESSES = []
SOCKETS = {}

def say(text):
    LOG.write(text + '\n')
    LOG.flush()

def env_for(lab):
    env = ENV.copy()
    env.update(FM_HOME=str(lab), TMUX=f'{lab}/absent-tmux-socket,0,0')
    if str(lab) in SOCKETS:
        directory, socket = SOCKETS[str(lab)]
        env.update(TMUX_TMPDIR=directory, TMUX=socket)
    return env

def run(args, lab=None, cwd=None, expected=0, extra=None, timeout=90):
    cmd = [str(x) for x in args]
    say('$ ' + shlex.join(cmd))
    start = time.monotonic()
    env = env_for(lab) if lab else ENV.copy()
    if extra:
        env.update(extra)
    result = subprocess.run(cmd, cwd=cwd or ROOT, env=env, text=True, capture_output=True, timeout=timeout)
    if result.stdout:
        say(result.stdout.rstrip())
    if result.stderr:
        say('stderr:\n' + result.stderr.rstrip())
    say(f'exit={result.returncode}, elapsed={time.monotonic()-start:.3f}s')
    if expected is not None:
        assert result.returncode == expected, (cmd, result.returncode, result.stderr)
    return result

def wait_for(predicate, message, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError(message)

def make_lab(name):
    lab = WORK / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', lab])
    (lab / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "history/completed.md"\ndone_keep = 10\n')
    (lab / 'history').mkdir()
    (lab / 'history/completed.md').write_text('## Archived 2026-10-19\n')
    (lab / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (lab / 'config/backend').write_text('tmux\n')
    project = lab / 'projects/demo'
    run(['git', 'init', '-q', '--initial-branch=main', project], lab)
    (lab / 'state/.last-watcher-beat').touch()
    if name in ('background', 'overlap'):
        directory=run([ROOT/'bin/fm-lab-home.sh','tmux-dir',lab],lab).stdout.strip()
        run(['tmux','-L','fm-lab','new-session','-d','-s','fm-lab','-x','120','-y','40','-c',ROOT,'/bin/sh'],lab,extra={'TMUX_TMPDIR':directory})
        socket=run(['tmux','-L','fm-lab','display-message','-p','-t','fm-lab','#{socket_path},#{pid},0'],lab,extra={'TMUX_TMPDIR':directory}).stdout.strip()
        SOCKETS[str(lab)]=(directory,socket)
    return lab

def receipt(lab, task):
    return lab / 'data' / task / 'record/data-cleanup.json'

def load(lab, task):
    return json.loads(receipt(lab, task).read_text())

def pending(lab, task, complete=True, beads=None, required=False, mark=None):
    directory = lab / 'data' / task
    (directory / 'record').mkdir(parents=True, exist_ok=True)
    target = directory / '.cleanup-hold' if complete else directory
    target.mkdir(exist_ok=True)
    row = {'version':1, 'task':task, 'complete':complete, 'expired':False, 'sources':[{'project':str(lab / 'projects/demo'), 'pr':'', 'beads':beads or [], 'backlog':{'data':str(lab / 'data'), 'task':task if required else None}}]}
    if mark:
        row['expiry'] = mark
    receipt(lab, task).write_text(json.dumps(row) + '\n')
    return target

def expire(lab, task, expected=0):
    return run(['bash', ROOT / 'bin/fm-task-data-lib.sh', 'expire', lab/'data', lab/'state', task], lab, expected=expected)

def snapshot(lab, task, label):
    directory = lab / 'data' / task
    state = {'task':task, 'receipt':load(lab, task), 'remaining_files':[str(p.relative_to(directory)) for p in sorted(directory.rglob('*')) if p.is_file()]}
    status = lab / 'state' / f'{task}.status'
    if status.is_file():
        state['status'] = status.read_text()
    say(label + ':\n' + json.dumps(state, indent=2))
    (EVID / f'{label}.json').write_text(json.dumps(state, indent=2) + '\n')

def begin_task(lab, task, payload=True):
    run(['tasks-axi', 'add', task, 'completed local lab task', '--kind', 'ship', '--file', lab/'data/backlog.md'], lab, cwd=lab)
    run(['tasks-axi', 'start', task, '--file', lab/'data/backlog.md'], lab, cwd=lab)
    if str(lab) in SOCKETS:
        run(['tmux','-L','fm-lab','new-window','-d','-t','fm-lab','-n',f'fm-{task}','-c',ROOT,'/bin/sh'],lab)
    meta = dict(window=f'fm-lab:fm-{task}', endpoint_task_id=task, worktree=str(lab/'projects'/f'gone-{task}'), project=str(lab/'projects/demo'), kind='ship', mode='local-only', spawn_gen=f'lab-{task}')
    (lab/'state'/f'{task}.meta').write_text(''.join(f'{k}={v}\n' for k,v in meta.items()))
    if payload:
        directory = lab/'data'/task
        directory.mkdir(exist_ok=True)
        (directory/'scratch.bin').write_bytes(b'fresh recovery\n' * 512)
    (lab/'state'/f'{task}.status').write_text('done: local task complete\n')

def teardown(lab, task, extra=None):
    return run([ROOT/'bin/fm-teardown.sh', task], lab, extra={'FM_TASK_DATA_SWEEP':'on', 'FM_TEARDOWN_DATA_EXPIRE_TIMEOUT':'1', 'FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT':'1', 'FM_TEARDOWN_DATA_STAGE_TIMEOUT':'120', **(extra or {})}, timeout=90)

def many_files(target, count=12000):
    sub = target/'clone-objects'
    sub.mkdir()
    for i in range(count):
        (sub/f'{i:05d}.bin').write_bytes(b'x' * 512)

def real_bead(lab, description):
    project=lab/'projects/demo'
    run(['br', 'init', '--prefix', 'proof'], lab, cwd=project)
    response=run(['br', 'create', 'linked lab evidence', '--description', description, '--json'], lab, cwd=project)
    row=json.loads(response.stdout)
    bead=row['id']
    run(['br', 'show', bead, '--json'], lab, cwd=project)
    return bead

def scenario_background():
    lab = make_lab('background')
    old = pending(lab, 'old-slow1', mark='cut-off')
    many_files(old)
    for task, complete in (('old-large1',True),('old-stage1',False)):
        target = pending(lab, task, complete=complete, mark='too-large')
        (target/'scratch.bin').write_bytes(b'old scratch\n' * 1024)
    begin_task(lab, 'task-a1')
    directory=lab/'data/task-a1'
    (directory/'brief.md').write_text('[linked image](proof.png)\n')
    (directory/'proof.png').write_bytes(b'linked evidence bytes\n')
    (directory/'review.md').write_text('reviewed successfully\n')
    (directory/'findings.txt').write_text('no unresolved findings\n')
    (directory/'status').write_text('done: local result\n')
    run(['git','clone','--quiet',lab/'projects/demo',directory/'clone'], lab, expected=0)
    (directory/'clone/build.bin').write_bytes(b'build output\n' * 4096)
    run(['du','-sk',lab/'data'],lab)
    result=teardown(lab,'task-a1')
    assert 'expiry stopped after its one full 1s attempt' in result.stderr, 'the real slow hold did not exceed the foreground deadline'
    wait_for(lambda: all(load(lab,t).get('expired') for t in ('old-slow1','old-large1','old-stage1')), 'background sweep did not drain old holds', 300)
    for task in ('old-slow1','old-large1','old-stage1'):
        assert not (lab/'data'/task/'.cleanup-hold').exists()
        assert 'expiry' not in load(lab,task)
        snapshot(lab,task,f'background-{task}')
    assert (directory/'.cleanup-hold/clone').exists(), 'fresh clone recovery not preserved'
    assert not load(lab,'task-a1').get('expired')
    snapshot(lab,'task-a1','background-fresh-a')
    begin_task(lab,'task-b1')
    teardown(lab,'task-b1')
    wait_for(lambda: load(lab,'task-a1').get('expired'), 'a subsequent completion did not expire A')
    assert not (directory/'.cleanup-hold').exists()
    assert not (directory/'clone').exists()
    for path in ('brief.md','review.md','findings.txt','status','proof.png'):
        assert (directory/path).is_file(), f'linked or small evidence lost: {path}'
    assert (lab/'data/task-b1/.cleanup-hold/scratch.bin').exists(), 'B fresh recovery lost'
    snapshot(lab,'task-a1','background-expired-a')
    snapshot(lab,'task-b1','background-fresh-b')
    run(['du','-sk',lab/'data'],lab)

def scenario_overlap():
    lab=make_lab('overlap')
    slow=pending(lab,'old-slow1')
    many_files(slow)
    (pending(lab,'task-a1')/'scratch.bin').write_text('A fresh recovery\n')
    (pending(lab,'live-c1')/'scratch.bin').write_text('live task data\n')
    (lab/'state/live-c1.meta').write_text('kind=ship\nspawn_gen=live-c1\n')
    command=['bash',str(ROOT/'bin/fm-task-data-lib.sh'),'sweep',str(lab/'data'),str(lab/'state'),'task-a1']
    out=(EVID/'overlap-first-sweep.log').open('w')
    say('$ '+shlex.join(command))
    process=subprocess.Popen(command,cwd=ROOT,env=env_for(lab),stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    PROCESSES.append(process)
    wait_for(lambda:(lab/'state/.meta-old-slow1.lock').is_dir(), 'first sweep never acquired its per-task lock')
    os.killpg(process.pid,signal.SIGSTOP)
    say(f'Paused real sweep process group {process.pid} while old-slow1 meta lock is held')
    try:
        assert (lab/'state/.task-data-sweep.lock').is_dir()
        refused=expire(lab,'old-slow1',expected=1)
        assert 'locked by another process' in refused.stderr
        assert list(slow.rglob('*.bin')), 'locked recovery was already gone'
        begin_task(lab,'task-b1')
        teardown(lab,'task-b1')
        second=run(['bash',ROOT/'bin/fm-task-data-lib.sh','sweep',lab/'data',lab/'state','task-b1'],lab)
        assert 'already running; requested another pass' in second.stderr
        assert (lab/'state/.task-data-sweep.rerun').read_text().strip()=='task-b1'
        assert (lab/'data/task-b1/.cleanup-hold/scratch.bin').exists()
        say('B teardown completed while A sweep retained only its singleton and old-slow1 task locks')
    finally:
        os.killpg(process.pid,signal.SIGCONT)
    assert process.wait(timeout=90)==0
    out.close()
    say((EVID/'overlap-first-sweep.log').read_text())
    assert load(lab,'task-a1').get('expired'), 'B rerun failed to expire A'
    assert load(lab,'old-slow1').get('expired')
    assert not load(lab,'task-b1').get('expired'), 'B fresh recovery expired'
    assert (lab/'data/task-b1/.cleanup-hold/scratch.bin').exists()
    assert (lab/'data/live-c1/.cleanup-hold/scratch.bin').exists(), 'live record data lost'
    assert (lab/'state/live-c1.meta').is_file()
    assert not (lab/'state/.task-data-sweep.lock').exists(), 'sweep singleton leaked'
    assert not (lab/'state/.meta-old-slow1.lock').exists(), 'task meta lock leaked'
    for task in ('task-a1','task-b1','live-c1'):
        snapshot(lab,task,f'overlap-{task}')

def scenario_bead_filter():
    lab=make_lab('bead-filter')
    bead=real_bead(lab,'[capture](proof.png)')
    for task,saved in (('saved-filter1',True),('new-filter1',False)):
        target=pending(lab,task,beads=['09-30','2026-09-29T21','s-workflow',bead] if saved else [])
        (target/'proof.png').write_bytes(b'bead-linked bytes\n')
        (target/'scratch.bin').write_bytes(b'discard\n')
        (lab/'data'/task/'brief.md').write_text(f'Bead 09-30\nBead 2026-09-29T21\nbeads-workflow\nBead {bead}\n')
        expire(lab,task)
        row=load(lab,task)
        assert row['sources'][0]['beads']==[bead], row
        assert row.get('expired')
        assert (lab/'data'/task/'proof.png').read_bytes()==b'bead-linked bytes\n'
        assert not (lab/'data'/task/'.cleanup-hold').exists()
        snapshot(lab,task,task)

def scenario_archive():
    lab=make_lab('archive')
    bead=real_bead(lab,'[capture](proof.png)')
    target=pending(lab,'archived-task1',complete=False,required=True)
    (lab/'history/completed.md').write_text(f'## Archived 2026-10-19\n- [x] archived-task1 - finished (repo: demo) (done 2026-10-19)\n  [row capture](row.png)\n  Bead {bead}\n')
    (target/'proof.png').write_bytes(b'bead evidence\n')
    (target/'row.png').write_bytes(b'row evidence\n')
    (target/'scratch.bin').write_bytes(b'scratch\n')
    expire(lab,'archived-task1')
    assert (target/'proof.png').is_file()
    assert (target/'row.png').is_file()
    assert not (target/'scratch.bin').exists()
    assert load(lab,'archived-task1')['sources'][0]['beads']==[bead]
    assert load(lab,'archived-task1')['expired']
    snapshot(lab,'archived-task1','archived-linked-evidence')

def scenario_collision_and_status():
    lab=make_lab('archive-unread')
    bead=real_bead(lab,'[capture](proof.png)')
    task=bead
    held=pending(lab,task,complete=True,required=True)
    (held/'proof.png').write_bytes(b'colliding bead evidence\n')
    (held/'scratch.bin').write_bytes(b'keep whole while unread\n')
    (lab/'history/completed.md').write_text(f'## Archived 2026-10-19\n- [x] {task} - finished (repo: demo) (done 2026-10-19)\n  Bead {bead}\n')
    store=lab/'projects/demo/.beads'
    good=lab/'good-bead-store'
    store.rename(good)
    store.mkdir()
    (store/'beads.db').write_bytes(b'invalid SQLite bytes for a deliberately unreadable disposable bead store\n')
    run(['br','show',bead,'--json'],lab,cwd=lab/'projects/demo',expected=None)
    status=lab/'state'/f'{task}.status'
    status.mkdir()
    first=expire(lab,task,expected=1)
    assert 'unread_named' not in load(lab,task), 'unwritten status was marked delivered'
    assert (held/'proof.png').is_file() and (held/'scratch.bin').is_file()
    status.rename(lab/'blocked-status')
    run(['bash',ROOT/'bin/fm-task-data-lib.sh','sweep',lab/'data',lab/'state'],lab)
    record=load(lab,task)
    assert record['sources'][0]['unread']==[bead], 'owning-row recovery swallowed colliding bead failure'
    assert record.get('unread_named')==[bead]
    assert len(status.read_text().splitlines())==1
    expire(lab,task,expected=1)
    run(['bash',ROOT/'bin/fm-task-data-lib.sh','sweep',lab/'data',lab/'state'],lab)
    assert len(status.read_text().splitlines())==1, 'unread status repeated'
    assert (held/'proof.png').is_file() and (held/'scratch.bin').is_file()
    snapshot(lab,task,'archive-collision-unread')
    store.rename(lab/'failed-bead-store')
    good.rename(store)
    run(['br','show',bead,'--json'],lab,cwd=lab/'projects/demo')
    expire(lab,task)
    assert (lab/'data'/task/'proof.png').read_bytes()==b'colliding bead evidence\n'
    assert not held.exists()
    assert load(lab,task).get('expired')
    assert 'unread_named' not in load(lab,task)
    snapshot(lab,task,'archive-collision-recovered')

SCENARIOS=[('background cleanup and recovery',scenario_background),('single-instance overlapping requests and live-task locks',scenario_overlap),('new and saved real-bead filtering',scenario_bead_filter),('archived owning row and bead evidence',scenario_archive),('unread archived bead collision and status delivery',scenario_collision_and_status)]
for name,func in (SCENARIOS if __name__ == '__main__' else []):
    selected=os.environ.get('LIVE_SCENARIOS','')
    if selected and name not in selected.split('|'):
        continue
    slug=name.replace(' ','-')
    with (EVID/(slug+'.log')).open('w') as stream:
        LOG=stream
        try:
            func()
            RESULTS.append({'name':name,'result':'pass','live':True,'evidence':str(EVID/(slug+'.log'))})
        except Exception as error:
            say(traceback.format_exc())
            RESULTS.append({'name':name,'result':'fail','live':True,'error':str(error),'evidence':str(EVID/(slug+'.log'))})
    print(json.dumps(RESULTS[-1]),flush=True)
if __name__ == '__main__':
    for process in PROCESSES:
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGCONT)
            os.killpg(process.pid,signal.SIGTERM)
            process.wait(timeout=10)
    for lab_path in SOCKETS:
        lab=Path(lab_path)
        with (EVID/(lab.name+'-tmux-teardown.log')).open('w') as stream:
            LOG=stream
            run(['tmux','-L','fm-lab','kill-server'],lab)
            run([ROOT/'bin/fm-lab-home.sh','teardown',lab],lab)
    (EVID/('live-results-rerun.json' if os.environ.get('LIVE_SCENARIOS') else 'live-results.json')).write_text(json.dumps({'work':str(WORK),'results':RESULTS},indent=2)+'\n')
    print('Disposable setup retained only until guarded cleanup: '+str(WORK),flush=True)
