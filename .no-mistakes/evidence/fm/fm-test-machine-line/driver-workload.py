import datetime, json, os, pathlib, subprocess, sys, time
events = pathlib.Path(os.environ['LIVE_EVENTS'])
name = sys.argv[1]
tag = os.environ.get('LIVE_TAG', 'suite')
def emit(kind):
    record = dict(kind=kind, tag=tag, workload=name, pid=os.getpid(), ppid=os.getppid(),
                  at=time.time_ns(), utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  nice=os.getpriority(os.PRIO_PROCESS, 0),
                  task=os.environ.get('FM_TASK_ID'), held=os.environ.get('FM_TEST_MACHINE_LINE_HELD'),
                  holder=pathlib.Path(os.environ['MACHINE_LINE_DIR'], 'holder').read_text() if pathlib.Path(os.environ['MACHINE_LINE_DIR'], 'holder').exists() else None)
    descriptor=os.open(events, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(descriptor, (json.dumps(record)+'\n').encode()); os.close(descriptor)
    print(json.dumps(record), flush=True)
emit('enter')
if os.environ.get('LIVE_NESTED') and name == 'fm-dod-lib':
    childenv = dict(os.environ, LIVE_TAG=tag+'-nested')
    childenv.pop('LIVE_RELEASE', None); childenv.pop('LIVE_NESTED', None)
    subprocess.run(['bash', os.environ['LIVE_RUNNER'], '--json', os.environ['LIVE_NESTED_JSON'], os.environ['LIVE_NESTED']], env=childenv, check=True)
release = os.environ.get('LIVE_RELEASE')
if release:
    deadline = time.monotonic()+45
    while not pathlib.Path(release).exists():
        if time.monotonic()>deadline: raise RuntimeError('workload release deadline')
        time.sleep(.05)
time.sleep(.15)
emit('exit')
sys.exit(int(os.environ.get('LIVE_EXIT', '0')))
