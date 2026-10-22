import json, os, pathlib, signal, subprocess, time
R=pathlib.Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5HEFVZ2ZGARFBBBDTE72WAN')
E=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
F=E/'cap-fixtures'
base=os.environ.copy()
for k in list(base):
    if k.startswith('FM_LINT_') or k in ['CI','GITHUB_ACTIONS','SHELLCHECK_OPTS']:base.pop(k)
base.update(PATH=str(F/'bin')+os.pathsep+os.environ['PATH'],TMPDIR=str(F/'scratch'),FM_LINT_JOBS='2')
results=[]
for label,args,extra,rc in [
    ('no-telemetry-memory',['memory'],{'FM_LINT_ROOT_MEMORY_KIB':'65536','FM_LINT_REQUIRE_BOUNDS':'0'},123),
    ('fast-mode-time',['--fast','hang'],{'FM_LINT_ROOT_SECONDS':'1','FM_LINT_ROOT_GRACE':'1'},124),
    ('version-measured',['clean'],{'CAP_VERSION_BLOCK':'1','FM_LINT_ROOT_MEMORY_KIB':'65536','FM_LINT_ROOT_SECONDS':'1','FM_LINT_ROOT_GRACE':'1'},123),
]:
    env=base.copy();env.update(extra)
    attempts=E/(label+'.attempts.jsonl')
    children=E/(label+'.children.txt')
    env.update(CAP_ATTEMPTS=str(attempts),CAP_CHILDREN=str(children))
    command=[str(R/'bin/fm-lint.sh')]+[a if a.startswith('--') else str(F/(a+'.sh')) for a in args]
    started=time.monotonic()
    p=subprocess.Popen(command,cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    sample=''
    timedout=False
    if label=='version-measured':
        # Fixed wait for an observation while the controlled version workload holds memory.
        time.sleep(3)
        calls=[json.loads(x) for x in attempts.read_text().splitlines()] if attempts.exists() else []
        for c in calls:
            sample+=subprocess.run(['ps','-p',str(c['pid']),'-o','pid=,pgid=,rss=,etime=,comm='],capture_output=True,text=True).stdout
    try: output=p.communicate(timeout=3 if label=='version-measured' else 10)[0]
    except subprocess.TimeoutExpired:
        timedout=True
        os.killpg(p.pid,signal.SIGKILL)
        output=p.communicate()[0]
    calls=[json.loads(x) for x in attempts.read_text().splitlines()]
    owned=[x['pid'] for x in calls]
    if children.exists():owned.extend(int(x) for x in children.read_text().splitlines())
    alive=[]
    for pid in owned:
        state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
        if state and not state.startswith('Z'):alive.append(pid)
    result={'scenario':label,'exit':p.returncode,'expected_exit':rc,'elapsed_seconds':round(time.monotonic()-started,3),'external_timeout':timedout,'survivors':alive,'result':'pass' if p.returncode==rc and not timedout and not alive else 'fail'}
    (E/(label+'.log')).write_text('$ '+' '.join(command)+'\nEnvironment overrides: '+json.dumps(extra)+'\nControlled ShellCheck workload; real fm-lint runner.\n'+output+'\nPID PGID RSS_KiB ELAPSED COMMAND sampled at 3s:\n'+sample+'\n'+json.dumps(result,indent=2)+'\n')
    results.append(result);print(json.dumps(result),flush=True)
(E/'cap-followup-results.json').write_text(json.dumps(results,indent=2)+'\n')
