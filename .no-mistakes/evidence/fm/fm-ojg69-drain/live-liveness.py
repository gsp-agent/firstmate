import json, os, pathlib, shlex, subprocess, tempfile, time, traceback
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX')
WORK=pathlib.Path(tempfile.mkdtemp(prefix='.phase-liveness-', dir=ROOT))
LAB=WORK/'home'
(WORK/'tmp').mkdir()
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') and (key.endswith('_OVERRIDE') or key in ('FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID')) or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','BEADS_DIR','BEADS_DB','BR_DB','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','NO_MISTAKES_GATE'):
        env.pop(key,None)
env.update(TMPDIR=str(WORK/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=(EVID/'secondmate-revalidation-live.log').open('w')
started=False
holder=None
recover=None
result={'name':'queued recovery revalidates a real Codex replacement before killing or spawning','result':'untested','live':False,'evidence':str(EVID/'secondmate-revalidation-live.log')}

def run(args,extra=None,expected=0,timeout=30):
    log.write('$ '+shlex.join([str(x) for x in args])+'\n');log.flush()
    response=subprocess.run([str(x) for x in args],cwd=ROOT,env={**env,**(extra or {})},capture_output=True,text=True,timeout=timeout)
    log.write(response.stdout+response.stderr+f'\nexit={response.returncode}\n');log.flush()
    if expected is not None:
        assert response.returncode==expected, response.stderr
    return response

def wait_for(path,seconds=30):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if path.exists():return
        time.sleep(.025)
    raise AssertionError('timed out waiting for '+str(path))

try:
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'config/supervision-host-off').touch()
    directory=run([ROOT/'bin/fm-lab-home.sh','tmux-dir',LAB]).stdout.strip()
    env.update(FM_HOME=str(LAB),TMUX_TMPDIR=directory)
    run(['tmux','-L','fm-lab','new-session','-d','-s','fm-lab','-n','fm-sm1','-x','120','-y','40','-c',ROOT,'/bin/sh'])
    started=True
    env['TMUX']=run(['tmux','-L','fm-lab','display-message','-p','-t','fm-lab','#{socket_path},#{pid},0']).stdout.strip()
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-sm1','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'codex'])
    meta=LAB/'state/sm1.meta'
    holder_script=EVID/'liveness-holder.sh'
    holder_script.write_text('''#!/usr/bin/env bash
set -eu
. "$1/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$STATE/.secondmate-relaunch.lock"
touch "$2"
IFS= read -r release
fm_lock_release "$STATE/.secondmate-relaunch.lock"
''')
    recover_script=EVID/'liveness-recover.sh'
    recover_script.write_text('''#!/usr/bin/env bash
set -eu
. "$1/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_lock sm1
fm_secondmate_liveness_probe "$FM_HOME/state/sm1.meta" sm1 poll
printf 'before: status=%s state=%s kill=%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL"
[ "$FM_SM_LIVE_STATUS" = relaunchable ] && [ "$FM_SM_LIVE_KILL" = 1 ]
touch "$2/probed"
rc=0
fm_secondmate_liveness_relaunch "$FM_HOME/state/sm1.meta" sm1 "$3" || rc=$?
fm_secondmate_liveness_unlock sm1
printf 'after: rc=%s status=%s state=%s reason=%s\n' "$rc" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_REASON"
touch "$2/finished"
''')
    replace_script=EVID/'liveness-publish-replacement.sh'
    replace_script.write_text('''#!/usr/bin/env bash
set -eu
. "$1/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$STATE/.control-sm1.lock"
lock=$(fm_meta_lock_path "$STATE/sm1.meta")
fm_lock_try_acquire "$lock"
printf 'kind=secondmate\nharness=codex\nbackend=tmux\nwindow=primary:fm-sm1\n' > "$STATE/sm1.meta.next"
mv "$STATE/sm1.meta.next" "$STATE/sm1.meta"
fm_lock_release "$lock"
fm_lock_release "$STATE/.control-sm1.lock"
''')
    cli_capture=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']).stdout
    (EVID/'codex-replacement-terminal.txt').write_text(cli_capture)
    if 'Sign in' in cli_capture or 'sign in' in cli_capture or 'Choose an account' in cli_capture:
        raise RuntimeError('The real Codex CLI requires a login; credential mutation is outside this test phase.')
    cli_pid=run(['tmux','-L','fm-lab','display-message','-p','-t','primary:fm-sm1','#{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height}']).stdout.strip()
    for label,timeout in (('startup',''),('watcher','20')):
        case=WORK/label
        case.mkdir()
        meta.write_text('kind=secondmate\nharness=codex\nbackend=tmux\nwindow=fm-lab:fm-sm1\n')
        holder_log=(EVID/(label+'-liveness-lock-holder.log')).open('w')
        holder=subprocess.Popen(['bash',str(holder_script),str(ROOT),str(case/'holding')],cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=holder_log,stderr=subprocess.STDOUT,text=True)
        wait_for(case/'holding')
        recover_log=(EVID/(label+'-liveness-recovery.log')).open('w')
        recover=subprocess.Popen(['bash',str(recover_script),str(ROOT),str(case),timeout],cwd=ROOT,env=env,stdout=recover_log,stderr=subprocess.STDOUT,text=True)
        wait_for(case/'probed')
        run(['bash',replace_script,ROOT])
        holder.communicate('release\n',timeout=10)
        holder_log.close()
        assert holder.returncode==0
        assert recover.wait(timeout=45)==0
        recover_log.close()
        text=(EVID/(label+'-liveness-recovery.log')).read_text()
        log.write(text);log.flush()
        assert 'before: status=relaunchable state=dead kill=1' in text
        assert 'after: rc=1 status=skipped state=alive reason=endpoint revalidated as alive' in text, text
        current=run(['tmux','-L','fm-lab','display-message','-p','-t','primary:fm-sm1','#{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height}']).stdout.strip()
        assert current.split()[0]==cli_pid.split()[0], 'replacement pane process changed'
        assert not (LAB/'state/.secondmate-relaunch-sm1').exists(), 'stale recovery recorded an attempt'
        assert not (LAB/'state/.control-sm1.lock').exists()
        assert not (LAB/'state/.secondmate-relaunch.lock').exists()
    cli_capture=run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary:fm-sm1']).stdout
    (EVID/'codex-replacement-terminal.txt').write_text(cli_capture)
    result.update(result='pass',live=True)
except Exception as error:
    log.write(traceback.format_exc());log.flush()
    result.update(result='fail',live=True,error=str(error))
finally:
    if holder is not None and holder.poll() is None:
        holder.communicate('release\n',timeout=10)
    if recover is not None and recover.poll() is None:
        recover.terminate()
        recover.wait(timeout=10)
    if started:
        run(['tmux','-L','fm-lab','kill-server'],expected=None)
        run([ROOT/'bin/fm-lab-home.sh','teardown',LAB],expected=None)
    log.close()
(EVID/'liveness-live-results.json').write_text(json.dumps({'work':str(WORK),'results':[result]},indent=2)+'\n')
print(json.dumps(result),flush=True)
