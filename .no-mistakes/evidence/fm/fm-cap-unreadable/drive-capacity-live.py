import os, pathlib, subprocess, tempfile, time, json, sys
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HJWD7NWSB5DVEKH4338NFV')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.capacity-live-',dir=ROOT))
home=lab/'home'; project=lab/'project'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TMUX','TASKS_AXI','GIT_'))}
env.update(HOME=str(lab/'user'), FM_HOME=str(home), FM_BACKEND='tmux', FM_LIVE_SESSION_CHECK='', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid', SHELL='/bin/bash', TREEHOUSE_ROOT=str(lab/'pool'))
(lab/'user').mkdir()
log=open(EVID/'capacity-live.log','w',buffering=1)
def run(args,extra=None,check=True,timeout=90):
    e=env.copy(); e.update(extra or {})
    start=time.monotonic(); p=subprocess.run(list(map(str,args)),cwd=ROOT,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+f'[exit={p.returncode}; elapsed={time.monotonic()-start:.3f}s]\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
sock=None
try:
    run(['bin/fm-lab-home.sh','create',home])
    sock=run(['bin/fm-lab-home.sh','tmux-dir',home]).stdout.strip()
    env['TMUX_TMPDIR']=sock
    run(['git','init','-q','-b','main',project])
    (project/'README.md').write_text('Disposable capacity verification project.\n')
    run(['git','-C',project,'add','README.md'])
    run(['git','-C',project,'commit','-qm','Fixture seed'])
    run(['git','clone','-q','--bare',project,lab/'origin.git'])
    run(['git','-C',project,'remote','add','origin',lab/'origin.git'])
    run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'/bin/bash --noprofile --norc'])
    run(['tmux','-L','fm-lab','set-option','-g','default-shell','/bin/bash'])
    run(['tmux','-L','fm-lab','set-option','-g','default-command','/bin/bash --noprofile --norc'])
    env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{socket_path},#{pid},0']).stdout.strip()
    (home/'config/backlog-backend').write_text('manual\n')
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    (home/'state/.last-watcher-beat').touch()
    # A resident record is real persisted input, not a replacement state reader.
    (home/'state/resident.meta').write_text(f'window=primary:0\nproject={project}\nworktree={project}\nkind=scout\nharness=claude\nspawn_gen=resident-live\n')
    (home/'state/resident.status').write_text('working: disposable resident\n')
    run(['bin/fm-busy-event.sh','arm',home/'state','resident'])
    run(['bin/fm-crew-state.sh','resident'], {'FM_CREW_STATE_NO_FORGE':'1'})
    counter=lab/'count.sh'
    counter.write_text('''#!/usr/bin/env bash
. "$PWD/bin/fm-wake-lib.sh"
. "$PWD/bin/fm-backend.sh"
. "$PWD/bin/fm-project-capacity-lib.sh"
lock=$(fm_treehouse_project_lock_path "$1") || exit
fm_project_capacity_occupants "$lock" "$1" "$FM_HOME/state" candidate
rc=$?
printf 'count exit: %s\\noccupants: %s\\nholders: %s\\nerror: %s\\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
exit "$rc"
''')
    def count(extra=None): return run(['/bin/bash',counter,project],extra)
    out=count().stdout
    assert 'occupants: 1\n' in out and 'state unreadable' not in out, out
    run(['bin/fm-busy-event.sh','apply',home/'state','resident','idle','--current-gen','--source','fm-recovery','--event','live-verification'])
    (home/'state/resident.status').write_text('paused: waiting for disposable input\n')
    assert 'state: paused' in run(['bin/fm-crew-state.sh','resident'], {'FM_CREW_STATE_NO_FORGE':'1'}).stdout
    assert 'occupants: 0\n' in count().stdout
    # Force the actual, unchanged crew-state CLI to exceed a deliberately short
    # configured deadline. No fake backend, timeout runner or reader is installed.
    timed={'FM_PROJECT_CAPACITY_CREW_TIMEOUT':'0.001'}
    out=count(timed).stdout
    assert 'occupants: 1\n' in out and 'resident (state unreadable)' in out, out
    out=count({'FM_PROJECT_CAPACITY_CREW_STATE':str(lab/'absent-reader')}).stdout
    assert 'occupants: 1\n' in out and 'resident (state unreadable)' in out, out
    # Lifecycle boundary is exercised through the normal spawn entrypoint.
    for task in ('blocked','admitted','second-blocked'):
        d=home/'data'/task; d.mkdir()
        (d/'brief.md').write_text(f'# Task\n## Captain\'s intent\nVerify capacity admission for {task}.\n\n## Firstmate spec\nRun the disposable marker command.\n\n# Definition of done\nDelivery contract: mode=local-only\n')
    marker=lab/'worker-started'
    worker=lab/'worker.sh'
    worker.write_text(f'#!/usr/bin/env bash\nprintf "capacity-live-worker-started\\n"\nprintf "started\\n" > "{marker}"\nexec sleep 300\n')
    def spawn(task,extra):
        return run(['bin/fm-spawn.sh',task,project,'--mode','local-only','--yolo','off',f'/bin/bash {worker}'],extra,check=False,timeout=100)
    (home/'config/project-capacity').write_text('project 1\n')
    before=run(['tmux','-L','fm-lab','list-windows','-t','primary','-F','#{window_id}']).stdout
    out=spawn('blocked',timed)
    assert out.returncode==75 and 'resident (state unreadable)' in out.stdout, out.stdout
    assert not (home/'state/blocked.meta').exists()
    assert not (home/'data/blocked/launch-brief.md').exists()
    assert not marker.exists()
    assert run(['tmux','-L','fm-lab','list-windows','-t','primary','-F','#{window_id}']).stdout==before
    # Increasing only the declaration must turn the same read failure into
    # a real allocated worktree and running marker process.
    (home/'config/project-capacity').write_text('project 2\n')
    out=spawn('admitted',timed)
    assert out.returncode==0 and 'spawned admitted' in out.stdout, out.stdout
    deadline=time.monotonic()+10
    while not marker.exists() and time.monotonic()<deadline: time.sleep(.1)
    assert marker.read_text()=='started\n'
    meta=(home/'state/admitted.meta').read_text()
    log.write('Persisted admitted task metadata:\n'+meta)
    fields=dict(line.split('=',1) for line in meta.splitlines() if '=' in line)
    assert pathlib.Path(fields['worktree']).is_relative_to(lab)
    assert pathlib.Path(fields['worktree'])!=project
    run(['tmux','-L','fm-lab','capture-pane','-p','-t',fields['window']])
    out=spawn('second-blocked',timed)
    assert out.returncode==75 and '2 already hold a place' in out.stdout and 'state unreadable' in out.stdout, out.stdout
    assert not (home/'state/second-blocked.meta').exists()
    log.write('All live capacity checks completed. Real tmux, treehouse, crew-state and spawn were used.\n')
finally:
    if sock:
        run(['tmux','-L','fm-lab','kill-server'],check=False)
        run(['bin/fm-lab-home.sh','teardown',home],check=False)
    (EVID/'capacity-lab-path.txt').write_text(str(lab)+'\n')
    log.close()
