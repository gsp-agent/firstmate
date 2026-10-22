import os, pathlib, subprocess, tempfile, time, signal
ROOT=pathlib.Path.cwd(); EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HJWD7NWSB5DVEKH4338NFV')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.capacity-faults-',dir=ROOT)); home=lab/'home'; project=lab/'project'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TMUX','TASKS_AXI','GIT_'))}
env.update(FM_HOME=str(home),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=open(EVID/'capacity-faults.log','w',buffering=1)
def run(args, extra=None, check=True):
    e=env.copy(); e.update(extra or {}); t=time.monotonic()
    p=subprocess.run(list(map(str,args)),env=e,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=40)
    log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit={p.returncode}; elapsed={time.monotonic()-t:.3f}s]\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p
try:
    run(['bin/fm-lab-home.sh','create',home]); run(['git','init','-q',project])
    record=home/'state/resident.meta'
    record.write_text(f'project={project}\nworktree={project}\nkind=scout\nharness=claude\n')
    before=subprocess.run(['git','show','f11d8853:bin/fm-project-capacity-lib.sh'],stdout=subprocess.PIPE,check=True).stdout
    (lab/'capacity-before-fix.sh').write_bytes(before)
    counter=lab/'count.sh'
    counter.write_text('''#!/usr/bin/env bash
. "$PWD/bin/fm-wake-lib.sh"
. "$PWD/bin/fm-backend.sh"
. "$PWD/bin/fm-timeout-lib.sh"
. "$1"
lock=$(fm_treehouse_project_lock_path "$2") || exit
fm_project_capacity_occupants "$lock" "$2" "$FM_HOME/state" candidate
rc=$?
printf 'count exit: %s\\noccupants: %s\\nholders: %s\\nerror: %s\\n' "$rc" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
exit "$rc"
''')
    # Transparent launcher only publishes the PID, then replaces itself with
    # the actual unmodified CLI; it never synthesizes state or an exit code.
    reader=lab/'observed-reader.sh'; pidfile=lab/'reader.pid'
    reader.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$$" > "{pidfile}"\nexec "{ROOT}/bin/fm-crew-state.sh" "$@"\n'); reader.chmod(0o755)
    env['FM_PROJECT_CAPACITY_CREW_STATE']=str(reader)
    current=['/bin/bash',counter,ROOT/'bin/fm-project-capacity-lib.sh',project]
    def inject(lib, sig):
        # Preserve the previous PID file as evidence inside the disposable lab.
        if pidfile.exists(): pidfile.rename(lab/f'reader-prior-{time.time_ns()}.pid')
        args=['/bin/bash',counter,lib,project]; t=time.monotonic()
        proc=subprocess.Popen(list(map(str,args)),env=env,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        victim=None; command=''
        while time.monotonic()-t<7 and proc.poll() is None:
            if pidfile.exists():
                data=pidfile.read_text().strip()
                if data:
                    pid=int(data)
                    cmd=subprocess.run(['ps','-p',str(pid),'-o','command='],stdout=subprocess.PIPE,text=True).stdout.strip()
                    # Match the actual executable after exec, not the launcher.
                    if str(ROOT/'bin/fm-crew-state.sh') in cmd and cmd.endswith(' resident'):
                        victim=pid; command=cmd; os.kill(pid,sig); break
            time.sleep(.005)
        if victim is None:
            proc.terminate(); output=proc.communicate(timeout=20)[0]
            raise AssertionError('No owned real crew reader was observed: '+output)
        output=proc.communicate(timeout=25)[0]
        log.write(f'$ /bin/bash {counter} {lib} {project}\nFAULT: {signal.Signals(sig).name} to actual crew-state pid={victim}: {command}\n'+output+f'[exit={proc.returncode}; elapsed={time.monotonic()-t:.3f}s]\n')
        return proc.returncode,output
    log.write('A real crew-state process is suspended before it can answer. Production deadline remains 10 seconds.\n')
    rc,output=inject(lab/'capacity-before-fix.sh',signal.SIGSTOP)
    assert rc==1 and 'crew state for task record' in output and 'cannot be read' in output
    rc,output=inject(ROOT/'bin/fm-project-capacity-lib.sh',signal.SIGSTOP)
    assert rc==0 and 'occupants: 1\n' in output and 'resident (state unreadable)' in output
    rc,output=inject(ROOT/'bin/fm-project-capacity-lib.sh',signal.SIGKILL)
    assert rc==0 and 'occupants: 1\n' in output and 'resident (state unreadable)' in output
    record.chmod(0)
    meta=run(current,check=False)
    assert meta.returncode==1 and 'task record' in meta.stdout and 'cannot be read' in meta.stdout
    record.chmod(0o644)
    log.write('Production-bound timeout reproduced before the fix; timeout and killed-reader fallbacks passed after it. Unreadable task metadata still refuses.\n')
finally:
    if (home/'state/resident.meta').exists(): (home/'state/resident.meta').chmod(0o644)
    (EVID/'capacity-fault-lab-path-2.txt').write_text(str(lab)+'\n')
    log.close()
