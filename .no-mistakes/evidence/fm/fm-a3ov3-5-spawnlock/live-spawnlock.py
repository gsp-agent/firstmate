#!/usr/bin/env python3
"""Disposable product-level admission races; no product or backend is mocked."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import threading
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M59NQ5AD412S4SCJMT64TFN4')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M59NQ5AD412S4SCJMT64TFN4')
BASE = ROOT / '.nm-test-tmp/live'
SOCKET = '.nm-test-tmp/s'
SESSION = 'fm-lab-spawnlock'
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'TMUX', 'TMUX_PANE'):
        ENV.pop(key, None)
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='gsp-agent', GIT_AUTHOR_EMAIL='test@example.invalid',
           GIT_COMMITTER_NAME='gsp-agent', GIT_COMMITTER_EMAIL='test@example.invalid',
           SHELL='/bin/bash', TMPDIR=str(ROOT / '.nm-test-tmp'),
           TREEHOUSE_ROOT=str(BASE / 'pool'), FM_SPAWN_NO_GUARD='1')
RESULTS = []
STARTED = []
PRINT_LOCK = threading.Lock()

def log(message):
    with PRINT_LOCK:
        print(message, flush=True)

def run(args, env=None, timeout=150, check=True, name=None, cwd=ROOT):
    begin = time.monotonic()
    cp = subprocess.run([str(a) for a in args], cwd=cwd, env=env or ENV,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, timeout=timeout)
    if name:
        text = f'$ {shlex.join(str(a) for a in args)}\n{cp.stdout}\nexit={cp.returncode} elapsed={time.monotonic()-begin:.2f}s\n'
        (EVIDENCE / f'{name}.log').write_text(text)
        log(text)
    if check and cp.returncode:
        raise RuntimeError(f'{args[0]} exited {cp.returncode}: {cp.stdout}')
    return cp

def tmux(*args, **kwargs):
    return run(['tmux', '-S', SOCKET, *args], **kwargs)

def wait_file(path, timeout=25):
    end = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= end:
            raise RuntimeError(f'did not reach {path.name} in {timeout}s')
        time.sleep(0.03)

def scenario(name, fn):
    log(f'\nSCENARIO {name}')
    try:
        fn()
        RESULTS.append(dict(name=name, result='pass', live=True))
        log(f'OBSERVED PASS: {name}')
    except Exception as exc:
        RESULTS.append(dict(name=name, result='fail', live=True, error=str(exc)))
        log(f'OBSERVED FAILURE: {name}: {exc}')

def home_env(home):
    env = ENV.copy()
    env['FM_HOME'] = str(home)
    env['TMUX'] = TMUX_ID
    return env

def setup_case(label):
    home = BASE / label
    run([ROOT/'bin/fm-lab-home.sh', 'create', home])
    (home/'config/crew-harness').write_text('codex\n')
    (home/'config/project-capacity').write_text('project 1\n')
    (home/'state/.last-watcher-beat').touch()
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    origin = home/'origin.git'
    project = home/'projects/project'
    run(['git', 'init', '--bare', '-q', '-b', 'main', origin])
    run(['git', 'init', '-q', '-b', 'main', project])
    (project/'README.md').write_text('Disposable live admission lab. No model prompt is submitted.\n')
    run(['git', '-C', project, 'add', 'README.md'])
    run(['git', '-C', project, 'commit', '-qm', 'Initialize disposable lab'])
    run(['git', '-C', project, 'remote', 'add', 'origin', origin])
    run(['git', '-C', project, 'push', '-q', '-u', 'origin', 'main'])
    run(['git', '-C', project, 'remote', 'set-head', 'origin', 'main'])
    return home, project

def add_task(home, task):
    d = home/'data'/task
    d.mkdir(parents=True)
    (d/'brief.md').write_text('# Task\n## Captain\'s intent\nExercise an isolated worker launch without changing files.\n\n## Firstmate spec\nThe launch runs the installed CLI version command only.\n\n# Definition of done\nDelivery contract: mode=local-only\n')
    run(['tasks-axi', 'add', task, f'Disposable {task}', '--kind', 'ship', '--file', home/'data/backlog.md'])

def spawn(home, project, task, kind='ship', batch=False, raw=True, name=None):
    args = [ROOT/'bin/fm-spawn.sh']
    args += [f'{task}={project}'] if batch else [task, project]
    args += ['--scout'] if kind == 'scout' else ['--mode', 'local-only', '--yolo', 'off']
    args += ['--backend', 'tmux', '--harness', 'codex --version' if raw else 'codex']
    return run(args, env=home_env(home), check=False, name=name)

def seed(home, project, label):
    task = f'nms-{label}-seed'
    add_task(home, task)
    cp = spawn(home, project, task, name=f'{label}-seed')
    assert cp.returncode == 0, cp.stdout
    assert (home/f'state/{task}.meta').exists()
    STARTED.append((home, task))
    capture(home, task, f'{label}-seed-pane')
    return task

def capture(home, task, name):
    meta = dict(line.split('=',1) for line in (home/f'state/{task}.meta').read_text().splitlines() if '=' in line)
    cp = tmux('capture-pane', '-p', '-t', meta['window'], '-S', '-100', name=name)
    (EVIDENCE/f'{name}.meta').write_text((home/f'state/{task}.meta').read_text())
    return cp.stdout

def state(home, task):
    return run(['tasks-axi', 'show', task, '--file', home/'data/backlog.md']).stdout

def windows():
    return tmux('list-windows', '-t', SESSION, '-F', '#{window_name} #{pane_current_path}').stdout

def no_mutation(home, project, task, before):
    assert not (home/f'state/{task}.meta').exists(), 'deferred task published metadata'
    assert not (home/f'data/{task}/launch-brief.md').exists(), 'deferred task rendered launch brief'
    assert run(['git','-C',project,'worktree','list','--porcelain']).stdout == before['worktrees']
    assert f'fm-{task} ' not in windows(), 'deferred task created a terminal window'
    queued = state(home, task)
    assert 'state: queued' in queued, queued
    log(f'{task}: metadata absent, launch brief absent, terminal absent, worktrees unchanged; {queued.strip()}')

def snapshot(project):
    return dict(worktrees=run(['git','-C',project,'worktree','list','--porcelain']).stdout)

def overshares(home):
    d = home/'state/project-capacity-overshare'
    return list(d.iterdir()) if d.exists() else []

def reading(home, control, failure=False):
    control.mkdir()
    os.mkfifo(control/'release')
    (home/'config/project-capacity-headroom').write_text(shlex.join([sys.executable, str(Path(__file__)), 'reading', str(control), '1' if failure else '0'])+'\n')

def release(control):
    with (control/'release').open('w') as fifo:
        fifo.write('release\n')

def lock_holder(home, project, control, taskset=False):
    control.mkdir()
    script = control/'hold.sh'
    script.write_text('#!/usr/bin/env bash\nset -eu\n. "$1/bin/fm-wake-lib.sh"\n'
        + ('lock="$FM_HOME/state/.task-set.lock"\n' if taskset else 'lock=$(fm_treehouse_project_lock_path "$2")\n')
        + 'fm_lock_try_acquire "$lock"\n'
        + ('fm_lock_set_role "$lock" task-spawn\n' if taskset else '')
        + 'trap \'fm_lock_release "$lock"\' EXIT\n: > "$3/held"\nread -r release < "$3/release"\n')
    os.mkfifo(control/'release')
    cp = subprocess.Popen(['bash',str(script),str(ROOT),str(project),str(control)], cwd=ROOT,
        env=home_env(home), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    wait_file(control/'held')
    return cp

def same_home():
    home, project = setup_case('same-home')
    seed(home, project, 'same')
    a = 'nms-same-a'
    add_task(home, a)
    items = [('nms-ship-b','ship',False),('nms-scout-b','scout',False),('nms-bship-b','ship',True),('nms-bscout-b','scout',True)]
    for task, _, _ in items:
        add_task(home,task)
    control = home/'reading'
    reading(home, control)
    before = snapshot(project)
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        first = pool.submit(spawn, home, project, a, name='same-home-reader')
        wait_file(control/'started')
        try:
            futures = [(task, pool.submit(spawn,home,project,task,kind,batch,True,f'same-home-{task}')) for task,kind,batch in items]
            for task, future in futures:
                cp = future.result(timeout=24)
                assert cp.returncode == 75, f'{task}: expected 75, got {cp.returncode}: {cp.stdout}'
                no_mutation(home,project,task,before)
            assert len(overshares(home)) == 0
        finally:
            release(control)
        cp = first.result(timeout=150)
    assert cp.returncode == 0, cp.stdout
    STARTED.append((home,a))
    assert len(overshares(home)) == 1
    capture(home,a,'same-home-admitted-pane')
    log('All four same-home variants exited 75; the original admitted exactly one extra worker.')

def failed_retake():
    home, project = setup_case('retake')
    seed(home,project,'retake')
    task='nms-retake-a'
    add_task(home,task)
    control=home/'reading'
    reading(home,control)
    before=snapshot(project)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        f=pool.submit(spawn,home,project,task,name='retake-reader')
        wait_file(control/'started')
        holder=lock_holder(home,project,home/'holder')
        try:
            release(control)
            cp=f.result(timeout=40)
        finally:
            release(home/'holder')
            holder.communicate(timeout=10)
    assert cp.returncode == 75, cp.stdout
    assert 'project lock was taken while the headroom reading ran' in cp.stdout
    no_mutation(home,project,task,before)
    assert len(overshares(home)) == 0

def teardown_race():
    home,project=setup_case('teardown')
    seed_task=seed(home,project,'teardown')
    task='nms-teardown-a'
    add_task(home,task)
    control=home/'reading'
    reading(home,control,failure=True)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        f=pool.submit(spawn,home,project,task,name='teardown-reader')
        wait_file(control/'started')
        try:
            cp=run([ROOT/'bin/fm-teardown.sh',seed_task],env=home_env(home),check=False,name='teardown-during-reading')
            assert cp.returncode == 0, cp.stdout
            assert not (home/f'state/{seed_task}.meta').exists()
        finally:
            release(control)
        cp=f.result(timeout=150)
    assert cp.returncode == 0, cp.stdout
    STARTED.append((home,task))
    assert len(overshares(home)) == 0, 'free place consumed extra-start window'
    capture(home,task,'teardown-recount-pane')
    log('Cleanup completed during the reading; recount launched inside the cap even though the reading denied room; no window consumed.')

def cross_home():
    home,project=setup_case('cross-home')
    seed(home,project,'cross')
    mate=home/'mate'
    run([ROOT/'bin/fm-lab-home.sh','create',mate])
    (mate/'config/crew-harness').write_text('codex\n')
    (mate/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (mate/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (mate/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={home}\n')
    (home/'data/secondmates.md').write_text(f'- mate - local lab mate (home: {mate}; scope: project work; projects: project; added 2026-10-19)\n')
    mp=mate/'projects/project'
    run(['git','clone','-q',home/'origin.git',mp])
    a,b='nms-cross-a','nms-cross-b'
    add_task(home,a)
    add_task(mate,b)
    control=home/'reading'
    reading(home,control)
    # The first reading waits, subsequent readings report room immediately.
    (control/'second-immediate').touch()
    before=snapshot(project)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        f=pool.submit(spawn,home,project,a,name='cross-home-first')
        wait_file(control/'started')
        try:
            cp=spawn(mate,mp,b,name='cross-home-second')
            assert cp.returncode == 0, cp.stdout
            STARTED.append((mate,b))
        finally:
            release(control)
        cp=f.result(timeout=40)
    assert cp.returncode == 75, cp.stdout
    assert 'already started one worker past that count' in cp.stdout
    no_mutation(home,project,a,before)
    assert len(overshares(home)) == 1
    assert len(overshares(mate)) == 0
    capture(mate,b,'cross-home-winner-pane')
    log('The other local home launched the one extra worker; the original rechecked the spent window and deferred 75.')

def publication_guard():
    home,project=setup_case('publication')
    task='nms-publication-b'
    add_task(home,task)
    before=snapshot(project)
    holder=lock_holder(home,project,home/'holder',taskset=True)
    try:
        cp=spawn(home,project,task,name='publication-contention')
    finally:
        release(home/'holder')
        holder.communicate(timeout=10)
    assert cp.returncode == 1, cp.stdout
    no_mutation(home,project,task,before)

def reading_main():
    control=Path(sys.argv[2])
    first=True
    try:
        fd=os.open(control/'first',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        os.close(fd)
    except FileExistsError:
        first=False
    with (control/'calls').open('a') as logf:
        logf.write('reading\n')
    if first or not (control/'second-immediate').exists():
        (control/'started').touch()
        with (control/'release').open() as fifo:
            fifo.readline()
    print('cpu_idle_pct=90 load1=0.10 disk_free_gb=80',flush=True)
    raise SystemExit(int(sys.argv[3]))

if __name__=='__main__' and len(sys.argv)>1 and sys.argv[1]=='reading':
    reading_main()

if __name__=='__main__':
    BASE.mkdir(parents=True)
    TMUX_ID=tmux('display-message','-p','-t',SESSION,'#{socket_path},#{pid},0').stdout.strip()
    for k,v in [('default-shell','/bin/bash'),('default-command','/bin/bash --noprofile --norc')]:
        tmux('set-option','-g',k,v)
    for k in ['TREEHOUSE_ROOT','SHELL','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','TMPDIR','PATH']:
        tmux('set-environment','-g',k,ENV[k])
    log('Real tools: '+run(['tmux','-V']).stdout.strip()+'; '+run(['treehouse','--version']).stdout.strip()+'; '+run(['codex','--version']).stdout.strip())
    log('No harness prompt or credential/configuration mutation is used. Version commands run through the real documented raw-launch interface.')
    try:
        scenario('Same-home fresh ships, scouts and batch entries defer 75 during a reading without side effects',same_home)
        scenario('Failed project-lock retake defers 75 without launching or consuming a window',failed_retake)
        scenario('Same-project cleanup during reading succeeds and recount admits the freed place without spending a window',teardown_race)
        scenario('Other local home takes exactly one extra start; original recount sees spent window and defers 75',cross_home)
        scenario('Ordinary task publication contention still refuses 1 and creates nothing',publication_guard)
    finally:
        # Stop only this run's private socket. The lab data is inspected and
        # removed separately through dcg after evidence has been collected.
        tmux('kill-server',check=False)
        (EVIDENCE/'live-spawnlock-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
        log('Private tmux server stopped; results saved.')
    raise SystemExit(0 if all(r['result']=='pass' for r in RESULTS) else 1)
