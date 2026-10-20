import json, os, pathlib, shlex, subprocess, tempfile, time, traceback
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX')
WORK=pathlib.Path(tempfile.mkdtemp(prefix='.phase-runtime-', dir=ROOT))
(WORK/'tmp').mkdir()
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and (key.endswith('_OVERRIDE') or key in ('FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID')) or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','BEADS_DIR','BEADS_DB','BR_DB','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','TYPESAFE_API_KEY'):
        env.pop(key,None)
env.update(TMPDIR=str(WORK/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
rows=[]
log=None

def run(args,cwd=ROOT,extra=None,expected=0,timeout=120):
    log.write('$ '+shlex.join([str(x) for x in args])+'\n');log.flush()
    result=subprocess.run([str(x) for x in args],cwd=cwd,env={**env,**(extra or {})},text=True,capture_output=True,timeout=timeout)
    log.write(result.stdout+result.stderr+f'\nexit={result.returncode}\n');log.flush()
    if expected is not None:
        assert result.returncode==expected, result.stderr
    return result

with (EVID/'dispatch-label-live.log').open('w') as log:
    try:
        lab=WORK/'dispatch'
        run([ROOT/'bin/fm-lab-home.sh','create',lab])
        (lab/'config/crew-dispatch.json').write_text(json.dumps({'default':{'harness':'codex','model':'gpt-6.1-sol','effort':'high'},'rules':[],'label_routes':{'ep-opus':{'harness':'claude','model':'opus','effort':'high'}}}))
        result=run(['bash','-x',ROOT/'bin/fm-dispatch-resolve.sh','--labels','priority,ep-opus'],extra={'FM_HOME':str(lab)})
        assert 'source: label (ep-opus)' in result.stdout and "--harness 'claude'" in result.stdout
        assert not any(line.lstrip('+ ').startswith('quota-axi ') for line in result.stderr.splitlines()), 'matched route invoked quota-axi'
        result=run([ROOT/'bin/fm-dispatch-resolve.sh','--labels','docs-only,ep-opus'],extra={'FM_HOME':str(lab)},expected=1)
        assert 'status: refused' in result.stdout
        rows.append({'name':'matching label routes without quota and conflicts refuse','result':'pass','live':True,'evidence':str(EVID/'dispatch-label-live.log')})
    except Exception as error:
        log.write(traceback.format_exc())
        rows.append({'name':'matching label routes without quota and conflicts refuse','result':'fail','live':True,'error':str(error),'evidence':str(EVID/'dispatch-label-live.log')})
print(json.dumps(rows[-1]),flush=True)
with (EVID/'drift-check-live.log').open('w') as log:
    try:
        repo=WORK/'drift-repo'
        run(['git','clone','--quiet','--no-hardlinks',ROOT,repo],timeout=120)
        result=run([ROOT/'bin/fm-drift-nightly.sh','check','--repo',repo,'--fork','1b1d3fda315a233ed06ce399aa7cdbdbac68e477','--upstream','20dcbf91520b1816663b81873ad67d0b93b3e4d6','--no-fetch'],expected=None,timeout=300)
        assert result.returncode in (0,1), 'committed manifest failed before drift evaluation: '+result.stderr
        assert 'ahead:' in result.stdout and ('path-drift:' in result.stdout or 'path-ok:' in result.stdout), 'drift evaluation did not produce a path verdict'
        result=run([ROOT/'bin/fm-drift-nightly.sh','install','--dry-run','--repo','.','--log',WORK/'nightly.log'],cwd=repo,extra={'FM_DRIFT_AGENT_DIR':str(WORK/'LaunchAgents')})
        repo_line=next(line[len('repo: '):] for line in result.stdout.splitlines() if line.startswith('repo: '))
        assert pathlib.Path(repo_line).is_absolute() and pathlib.Path(repo_line).samefile(repo)
        rows.append({'name':'committed drift manifest evaluates and relative install resolves absolute','result':'pass','live':True,'evidence':str(EVID/'drift-check-live.log')})
    except Exception as error:
        log.write(traceback.format_exc())
        rows.append({'name':'committed drift manifest evaluates and relative install resolves absolute','result':'fail','live':True,'error':str(error),'evidence':str(EVID/'drift-check-live.log')})
print(json.dumps(rows[-1]),flush=True)
(EVID/'runtime-live-results.json').write_text(json.dumps({'work':str(WORK),'results':rows},indent=2)+'\n')
