import json, os, pathlib, shlex, subprocess, sys, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
SCRATCH = ROOT / '.agent-state' / 'live-cr-validation-6'
LAB = SCRATCH / 'home'
PROJ = SCRATCH / 'project'
WT = SCRATCH / 'worktree'
HELPER = ROOT / 'bin/fm-herdr-lab.sh'
SESSION = 'fm-lab-cr-' + str(os.getpid())
BASE_PATH = os.environ['PATH']
ENV = os.environ.copy()
for k in list(ENV):
    if k.startswith('HERDR_') or k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_HOME','TMUX','CLAUDECODE'):
        ENV.pop(k, None)
ENV['FM_HERDR_LAB_STATE_DIR'] = str(SCRATCH / 'herdr-control')
ENV['FM_HOME'] = str(LAB)
ENV['FM_SPAWN_NO_GUARD'] = '1'
ENV['FM_CONTROL_LAUNCH_WAIT'] = '25'
ENV['FM_CONTROL_POLL'] = '0.25'
ENV['FM_CONTROL_EXIT_WAIT'] = '15'
ENV['FM_BACKEND'] = 'herdr'
ENV['HERDR_SESSION'] = SESSION
ENV['OPENCODE_DISABLE_AUTOUPDATE'] = 'true'
ENV['OPENCODE_DISABLE_PRUNE'] = 'true'
ENV['OPENCODE_DISABLE_LSP_DOWNLOAD'] = 'true'
ENV['FM_BACKLOG_ROW_TIMEOUT_SECS'] = '45'
ENV['GIT_CONFIG_GLOBAL'] = '/dev/null'
ENV['GIT_CONFIG_SYSTEM'] = '/dev/null'
ENV['GIT_CONFIG_NOSYSTEM'] = '1'
LOG = (EVIDENCE / 'live-dispatch.log').open('w', buffering=1)
PREPARED = False
PANE = None
RESULTS = {}
def record(s):
    LOG.write(s + '\n')
    print(s, flush=True)
def run(args, *, env=None, check=True, timeout=65):
    args = [str(x) for x in args]
    record('$ ' + shlex.join(args))
    result = subprocess.run(args, cwd=ROOT, env=env or ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    record(result.stdout.rstrip())
    record('exit=' + str(result.returncode))
    if check and result.returncode:
        raise RuntimeError('Command failed: ' + shlex.join(args))
    return result
ORIGINAL = ENV.copy()
ORIGINAL['PATH'] = BASE_PATH
def lab(*args, check=True):
    return run([HELPER, 'run', SESSION, *args], env=ORIGINAL, check=check)
def snap(label):
    result = lab('pane','read',PANE,'--source','visible',check=False)
    (EVIDENCE / (label + '.txt')).write_text(result.stdout)
    return result.stdout
URL = 'https://github.com/fm-lab/cr-validation/pull/7'
HEAD = 'a' * 40
SWEEP = ROOT / 'bin/fm-pr-queue-sweep.sh'
def dispatch(action, *command, check=True):
    return run([SWEEP,'--cr-dispatch',LAB/'state',URL,HEAD,action,'--',*command],check=check,timeout=120)
try:
    if SCRATCH.exists():
        raise RuntimeError('Refusing to reuse an existing scratch directory')
    SCRATCH.mkdir(parents=True)
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'config/backend').write_text('herdr\n')
    (LAB/'config/herdr-presentation-spaces').write_text('off\n')
    (LAB/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    PREPARED = True
    run([HELPER,'provision',SESSION],env=ORIGINAL)
    PROJ.mkdir()
    run(['git','-C',PROJ,'init','-q','-b','main'])
    (PROJ/'README.md').write_text('Disposable PR review branch. Validation marker: CR_LIVE_BRANCH_READY.\n')
    (PROJ/'opencode.json').write_text('{"autoupdate":false}')
    run(['git','-C',PROJ,'add','README.md','opencode.json'])
    run(['git','-C',PROJ,'-c','user.name=Test Fixture','-c','user.email=test@example.invalid','commit','-qm','Fixture baseline'])
    HEAD = run(['git','-C',PROJ,'rev-parse','HEAD']).stdout.strip()
    run(['git','-C',PROJ,'worktree','add','-q','-b','fm/cr-owner',WT])
    ws = json.loads(lab('workspace','create','--cwd',str(WT),'--label','cr-owner','--no-focus').stdout)['result']
    record('workspace response: ' + json.dumps(ws))
    PANE = ws['root_pane']['pane_id']
    wsid = ws['workspace']['workspace_id'] if 'workspace' in ws else ws.get('workspace_id', ws.get('id',''))
    # Read IDs from the real pane record rather than inferring their shape.
    pane = json.loads(lab('pane','get',PANE).stdout)['result']
    record('pane response: ' + json.dumps(pane))
    pd = pane.get('pane',pane)
    wsid = pd.get('workspace_id',wsid)
    tabid = pd.get('tab_id',ws.get('root_tab',{}).get('tab_id',''))
    if not wsid or not tabid:
        raise RuntimeError('Could not obtain exact workspace/tab identities')
    wrapper_dir = SCRATCH/'bin'
    wrapper_dir.mkdir()
    wrapper = wrapper_dir/'herdr'
    wrapper.write_text('#!/usr/bin/env python3\nimport os, subprocess, sys\na=sys.argv[1:]\nif a == ["--version"]:\n os.execv('+repr(str(pathlib.Path(shutil_path) if False else '/Users/dalecarman/.local/bin/herdr'))+', ["herdr",*a])\ntry: i=a.index("--session")\nexcept ValueError: sys.exit("lab router requires an explicit session")\nif a[i+1] != '+repr(SESSION)+': sys.exit("lab router refused foreign session")\ndel a[i:i+2]\nenv=os.environ.copy(); env["PATH"]='+repr(BASE_PATH)+'\nos.execve('+repr(str(HELPER))+',["fm-herdr-lab.sh","run",'+repr(SESSION)+',*a],env)\n')
    wrapper.chmod(0o755)
    ENV['PATH'] = str(wrapper_dir) + ':' + BASE_PATH
    pane_env = SCRATCH/'pane-env.sh'
    pane_env.write_text('export PATH=' + shlex.quote(ENV['PATH']) + chr(10) + 'export OPENCODE_DISABLE_AUTOUPDATE=true OPENCODE_DISABLE_PRUNE=true OPENCODE_DISABLE_LSP_DOWNLOAD=true' + chr(10))
    lab('pane','run',PANE,'source ' + shlex.quote(str(pane_env)))
    run([ROOT/'bin/fm-brief.sh','cr-owner','lab-project','--mode','local-only','--project',PROJ,'--herdr-lab'])
    brief = LAB/'data/cr-owner/brief.md'
    brief.write_text(brief.read_text().replace('{TASK}','Validate a disposable existing PR branch. Read README.md and write exactly CR_LIVE_BRANCH_READY followed by a newline to $FM_HOME/data/cr-owner/live-result.txt, then report completion. Baseline: zero completed launches; success is one real worker reply. Do not edit project files, run validation pipelines, publish, or contact any external service.').replace('{FIRSTMATE_SPEC}','This is an isolated live check of stale review relaunch. Read README.md and use a shell command to write CR_LIVE_BRANCH_READY followed by a newline to $FM_HOME/data/cr-owner/live-result.txt. Do not implement changes or run tests. All task state is disposable.'))
    meta = {'window':SESSION+':'+PANE,'endpoint_task_id':'cr-owner','worktree':str(WT),'project':str(PROJ),'harness':'opencode','kind':'ship','mode':'local-only','yolo':'off','branch':'fm/cr-owner','model':'default','effort':'default','backend':'herdr','herdr_session':SESSION,'herdr_workspace_id':wsid,'herdr_tab_id':tabid,'herdr_pane_id':PANE,'pr_url':URL}
    (LAB/'state/cr-owner.meta').write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
    note = 'Review fix round for '+URL+'. Reviewer carmanchip23-dev requests: read the disposable branch README and write CR_LIVE_BRANCH_READY followed by a newline to $FM_HOME/data/cr-owner/live-result.txt. Preserve branch fm/cr-owner; no publishing.'
    failure = dispatch('round1',ROOT/'bin/fm-control.sh','missing-task','relaunch','--note',note,check=False)
    assert failure.returncode != 0
    assert not (LAB/'state/changes-requested-sweep.seen').exists()
    RESULTS['failed_launch_retains_round'] = 'pass'
    dispatch('round1',ROOT/'bin/fm-control.sh','cr-owner','relaunch','--note',note)
    RESULTS['owner_relaunched'] = 'command-completed'
    screen = snap('owner-after-launch')
    # Wait on the worker's output file, rather than mistaking echoed prompt text for a model response.
    receipt = LAB/'data/cr-owner/live-result.txt'
    deadline = time.monotonic() + 65
    while time.monotonic() < deadline and not receipt.is_file():
        time.sleep(0.25)
    screen = snap('owner-after-launch')
    if not receipt.is_file():
        raise RuntimeError('Real worker did not produce its requested output file within 65 seconds')
    assert receipt.read_text().strip() == 'CR_LIVE_BRANCH_READY'
    (EVIDENCE/'worker-result.txt').write_text(receipt.read_text())
    RESULTS['owner_relaunched'] = 'pass'
    (EVIDENCE/'round-one-record.txt').write_text((LAB/'state/changes-requested-sweep.seen').read_text())
    first_meta = (LAB/'state/cr-owner.meta').read_text()
    dispatch('round1',ROOT/'bin/fm-control.sh','cr-owner','relaunch','--note',note)
    assert first_meta == (LAB/'state/cr-owner.meta').read_text()
    RESULTS['duplicate_round_does_not_relaunch'] = 'pass'
    record('round-one persisted state: '+(LAB/'state/changes-requested-sweep.seen').read_text())
    run([ROOT/'bin/fm-control.sh','cr-owner','exit'],check=False,timeout=65)
    RESULTS['observed_marker'] = receipt.read_text().strip() == 'CR_LIVE_BRANCH_READY'
    # Run the second real launch, then use the public hold and escalation interfaces.
    dispatch('round2',ROOT/'bin/fm-control.sh','cr-owner','relaunch','--note',note)
    RESULTS['round_two_dispatched'] = 'pass'
    (EVIDENCE/'round-two-record.txt').write_text((LAB/'state/changes-requested-sweep.seen').read_text())
    run([ROOT/'bin/fm-control.sh','cr-owner','exit'],check=False,timeout=65)
    run([ROOT/'bin/fm-captain-hold.sh','hold','cr-review-hold','--title','Decide unchanged PR after two fix rounds','--repo','lab-project','--reason',URL+' has no new head after two dispatched fix rounds; requesting reviewer carmanchip23-dev.'])
    run([SWEEP,'--cr-record',LAB/'state',URL,HEAD,'escalated'])
    hold = run([ROOT/'bin/fm-captain-hold.sh','open','cr-review-hold'])
    (EVIDENCE/'captain-hold.txt').write_text(hold.stdout)
    (EVIDENCE/'escalated-record.txt').write_text((LAB/'state/changes-requested-sweep.seen').read_text())
    RESULTS['captain_hold_recorded'] = 'pass'

except Exception as exc:
    record(type(exc).__name__+': '+str(exc))
    RESULTS['blocker'] = str(exc)
    if PANE:
        try: snap('owner-blocker')
        except Exception: pass
finally:
    if PREPARED:
        try:
            run([HELPER,'teardown',SESSION],env=ORIGINAL,timeout=90)
            RESULTS['lab_teardown'] = 'pass'
        except Exception as exc:
            record('Lab teardown failed: '+str(exc))
            RESULTS['lab_teardown'] = 'fail'
    (EVIDENCE/'live-dispatch-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    LOG.close()
