import json, os, pathlib, signal, subprocess, time, shutil

ROOT = pathlib.Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5HEFVZ2ZGARFBBBDTE72WAN')
E = pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
F = E / 'cap-fixtures'
F.mkdir(exist_ok=True)
(F / 'bin').mkdir(exist_ok=True)
(F / 'scratch').mkdir(exist_ok=True)
# This controlled external command is the workload, not the product under test.
# Real bin/fm-lint.sh, fm_exec_timed, workers and telemetry remain unmodified.
workload = F / 'bin/shellcheck'
workload.write_text('''#!/opt/homebrew/bin/python3
import json, os, pathlib, signal, subprocess, sys, time
log = pathlib.Path(os.environ['CAP_ATTEMPTS'])
with log.open('a') as f:
    f.write(json.dumps({'pid':os.getpid(), 'args':sys.argv[1:]})+'\\n')
if sys.argv[1:] == ['--version']:
    if os.environ.get('CAP_VERSION_BLOCK') == '1':
        data = bytearray(192 * 1048576)
        time.sleep(30)
    print('ShellCheck - controlled cap-test workload\\nversion: 0.11.0', flush=True)
    sys.exit(0)
name = pathlib.Path(sys.argv[-1]).name
if name.startswith('memory'):
    data = bytearray(192 * 1048576)
    time.sleep(6)
elif name.startswith('group'):
    kids = [subprocess.Popen([sys.executable, '-c', 'import time; data=bytearray(48*1048576); time.sleep(20)']) for _ in range(2)]
    pathlib.Path(os.environ['CAP_CHILDREN']).write_text('\\n'.join(str(x.pid) for x in kids))
    for p in kids: p.wait()
elif name.startswith('hang'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    kid = subprocess.Popen(['sleep','30'])
    pathlib.Path(os.environ['CAP_CHILDREN']).write_text(str(kid.pid))
    time.sleep(30)
elif name.startswith('reported') and '--external-sources' in sys.argv:
    print('shellcheck: Heap exhausted;', file=sys.stderr)
    sys.exit(int(os.environ['CAP_REPORTED_STATUS']))
print('Controlled workload completed: '+name, flush=True)
''')
workload.chmod(0o755)
for name in ['clean','memory','group','hang','reported']:
    (F / (name+'.sh')).write_text('#!/usr/bin/env bash\nexit 0\n')

base_env = os.environ.copy()
for key in list(base_env):
    if key.startswith('FM_LINT_') or key in ['CI','GITHUB_ACTIONS','SHELLCHECK_OPTS']:
        base_env.pop(key)
base_env.update(PATH=str(F/'bin')+os.pathsep+os.environ['PATH'], TMPDIR=str(F/'scratch'), FM_LINT_JOBS='1')
results=[]

def alive(pid):
    try:
        os.kill(pid, 0)
        state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
        return bool(state) and not state.startswith('Z')
    except ProcessLookupError:
        return False

def run(label, names, overrides=None, expected=0, reason=None, binary=None, timeout=12):
    env=base_env.copy()
    env.update(overrides or {})
    attempts=E/(label+'.attempts.jsonl')
    children=E/(label+'.children.txt')
    env.update(CAP_ATTEMPTS=str(attempts), CAP_CHILDREN=str(children))
    telemetry=E/(label+'.tsv')
    command=[str(binary or ROOT/'bin/fm-lint.sh'),'--telemetry',str(telemetry)]+[str(F/(n+'.sh')) for n in names]
    start=time.monotonic()
    p=subprocess.Popen(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    timed_out=False
    try:
        output=p.communicate(timeout=timeout)[0]
    except subprocess.TimeoutExpired:
        timed_out=True
        os.killpg(p.pid,signal.SIGKILL)
        output=p.communicate()[0]
    elapsed=time.monotonic()-start
    records=[json.loads(s) for s in attempts.read_text().splitlines()] if attempts.exists() else []
    rootrecords=[r for r in records if r['args']!=['--version']]
    roots=E/(label+'.roots.tsv')
    sidecar=roots.read_text() if roots.exists() else ''
    survivors=[]
    owned=[r['pid'] for r in records]
    if children.exists(): owned.extend(int(s) for s in children.read_text().splitlines())
    for pid in owned:
        if alive(pid): survivors.append(pid)
    errors=[]
    if timed_out: errors.append('Runner exceeded external safety deadline of '+str(timeout)+'s; required cap did not stop it')
    if not timed_out and p.returncode!=expected: errors.append('Expected exit '+str(expected)+', got '+str(p.returncode))
    if reason:
        if 'reason='+reason not in output: errors.append('Missing reason='+reason)
        if 'FAILED at the '+('time' if reason=='timeout' else 'memory')+' cap' not in output: errors.append('Missing named cap failure')
        if 'rerun' in output: errors.append('Capped file requested a rerun')
    if not timed_out and expected in [0,123,124,251] and len(rootrecords)!=len(names): errors.append('Root attempt count changed: '+str(len(rootrecords)))
    if survivors: errors.append('Owned workload processes survived: '+str(survivors))
    if expected in [123,251] and '\tmemory\t' not in sidecar: errors.append('Missing retained memory failure')
    result={'name':label,'result':'fail' if errors else 'pass','exit':p.returncode,'seconds':round(elapsed,3),'root_attempts':len(rootrecords),'external_timeout':timed_out,'survivors':survivors,'errors':errors,'command':command}
    (E/(label+'.log')).write_text('$ '+ ' '.join(command)+'\nEnvironment overrides: '+json.dumps(overrides or {})+'\nControlled ShellCheck workload; real fm-lint runner.\n'+output+'\n'+json.dumps(result,indent=2)+'\n')
    results.append(result)
    print(json.dumps(result),flush=True)
    return result

before=subprocess.run(['sysctl','vm.swapusage'],capture_output=True,text=True).stdout
(E/'swap-before.txt').write_text(before)
sentinel=subprocess.Popen(['sleep','90'],start_new_session=True)
try:
    run('control-default-caps',['clean','memory'])
    for jobs in ['1','2']:
        run('memory-cap-jobs-'+jobs,['memory','clean'],{'FM_LINT_JOBS':jobs,'FM_LINT_ROOT_MEMORY_KIB':'65536','FM_LINT_ROOT_SECONDS':'8'},123,'memory')
        run('time-cap-jobs-'+jobs,['hang','clean'],{'FM_LINT_JOBS':jobs,'FM_LINT_ROOT_SECONDS':'1','FM_LINT_ROOT_GRACE':'1'},124,'timeout')
        for status in ['123','251']:
            run('preserve-'+status+'-jobs-'+jobs,['reported','clean'],{'FM_LINT_JOBS':jobs,'CAP_REPORTED_STATUS':status},int(status),'memory')
    run('aggregate-process-group-memory',['group'],{'FM_LINT_ROOT_MEMORY_KIB':'81920','FM_LINT_ROOT_SECONDS':'8'},123,'memory')
    lone=F/'lone/bin'
    lone.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(ROOT/'bin/fm-lint.sh',lone/'fm-lint.sh')
    (lone/'fm-lint.sh').chmod(0o755)
    r=run('missing-watchdog-refusal',['clean'],binary=lone/'fm-lint.sh',expected=2)
    text=(E/'missing-watchdog-refusal.log').read_text()
    if 'refusing to lint uncapped' not in text or r['root_attempts']!=0:
        r['result']='fail';r['errors'].append('Failed to refuse before root invocation')
    r=run('version-invocation-cap',['clean'],{'CAP_VERSION_BLOCK':'1','FM_LINT_ROOT_MEMORY_KIB':'65536','FM_LINT_ROOT_SECONDS':'1','FM_LINT_ROOT_GRACE':'1'},expected=123,timeout=4)
    sentinel_alive=alive(sentinel.pid)
    (E/'sentinel.txt').write_text('Unrelated sentinel alive after all runner scenarios: '+str(sentinel_alive)+'\n')
finally:
    sentinel.terminate();sentinel.wait()
    after=subprocess.run(['sysctl','vm.swapusage'],capture_output=True,text=True).stdout
    (E/'swap-after.txt').write_text(after)
    (E/'cap-results.json').write_text(json.dumps(results,indent=2)+'\n')
