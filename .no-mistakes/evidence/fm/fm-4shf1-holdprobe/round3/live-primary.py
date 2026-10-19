import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path.cwd()
LAB_NAME = os.environ.get('PRIMARY_LAB', 'p')
LAB = ROOT / LAB_NAME
EVIDENCE = Path(__file__).parent
SUFFIX = '' if LAB_NAME == 'p' else '-' + LAB_NAME
LOG = (EVIDENCE/('live-primary'+SUFFIX+'-transcript.txt')).open('w', buffering=1)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'CLAUDE')) or key in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE'):
        env.pop(key)
env.update(FM_HOME=str(LAB), TMPDIR=str(ROOT/'.test-phase/primary-tmp'),
           PYTHONDONTWRITEBYTECODE='1', FM_BACKLOG_ROW_TIMEOUT_SECS='60',
           FM_POLL='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
           FM_CHECK_TIMEOUT='120', FM_ARM_CONFIRM_TIMEOUT='90',
           REVIEW_PAGE_HOME=str(LAB/'review-pages'), DALE_RECORDS_DIR=str(LAB/'dale-records'),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
Path(env['TMPDIR']).mkdir(parents=True, exist_ok=True)

def run(args, check=True, tmux=False, timeout=180):
    active = dict(env)
    if tmux:
        active['TMUX_TMPDIR'] = str(LAB/'tmux')
        args = ['tmux', '-L', 'fm-lab', *args]
    p = subprocess.run(args, cwd=ROOT, env=active, text=True, capture_output=True, timeout=timeout)
    LOG.write('$ ' + shlex.join(args) + '\n' + p.stdout + p.stderr + 'exit=' + str(p.returncode) + '\n')
    if check and p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return p

def wait_for(fn, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if fn():
            return True
        time.sleep(0.2)
    return False

started = False
result = {'name': 'A real Claude primary enters automatic monitoring and receives a release notification'+(' while a second probe hold remains' if os.environ.get('PRIMARY_REMAINING_HOLD') == 'yes' else ' for its only probe hold'), 'result':'untested', 'live':False}
try:
    run([str(ROOT/'bin/fm-lab-home.sh'), 'create', str(LAB)])
    (LAB/'tmux').mkdir()
    shutil.copytree(ROOT/'bin', LAB/'bin')
    shutil.copyfile(ROOT/'AGENTS.md', LAB/'AGENTS.md')
    run(['git','init','--quiet',str(LAB)])
    (LAB/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'config/supervision-host-off').touch()
    run([str(ROOT/'bin/fm-captain-hold.sh'), 'hold', 'signin', '--title', 'Complete the disposable sign-in',
         '--reason', 'sign in to the disposable service', '--dale-step', 'sign-in', '--probe', 'test -f "$FM_HOME/signed-in"'])
    if os.environ.get('PRIMARY_REMAINING_HOLD') == 'yes':
        (LAB/'second-hold').touch()
        run([str(ROOT/'bin/fm-captain-hold.sh'), 'hold', 'remaining', '--title', 'Complete the disposable screen',
             '--reason', 'open the disposable screen', '--dale-step', 'screen', '--probe', 'false'])
    # Execute the exact Stop-hook interface inside the real primary's process
    # lineage. No fake harness, process probes, task CLI, arm or watcher.
    script = LAB/'exercise.sh'
    script.write_text('''#!/usr/bin/env bash
set -u
"$FM_HOME/bin/fm-lock.sh" || exit 1
. "$FM_HOME/bin/fm-supervision-lib.sh"
fm_supervision_status "$FM_HOME/state"
printf 'needed=%s in-flight=%s checks=%s\\n' "$FM_SUP_NEEDED" "$FM_SUP_IN_FLIGHT" "$FM_SUP_CHECKS" > "$FM_HOME/predicate.txt"
printf 'stop-hook-started\\n' > "$FM_HOME/hook-started"
printf '{}\\n' | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/hook.stdout" 2> "$FM_HOME/hook.stderr"
rc=$?
printf '%s\\n' "$rc" > "$FM_HOME/hook.rc"
cat "$FM_HOME/predicate.txt" "$FM_HOME/hook.stdout" "$FM_HOME/hook.stderr"
printf 'hook-exit=%s\\n' "$rc"
if [ ! -f "$FM_HOME/second-hold" ]; then
  printf '{}\\n' | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/hook2.stdout" 2> "$FM_HOME/hook2.stderr"
  printf '%s\\n' "$?" > "$FM_HOME/hook2.rc"
fi
exit 0
''')
    run(['claude', '--version'])
    for copied in (LAB/'bin').iterdir():
        original = ROOT/'bin'/copied.name
        if copied.is_file() and original.is_file():
            assert copied.read_bytes() == original.read_bytes(), 'copied product code differs: ' + copied.name
    prompt = 'Run exactly this Bash command once: bash ' + shlex.quote(str(script)) + '. Return its complete output. This is a disposable product verification; do not inspect or change other files, delegate, or start any other process.'
    cli = ['claude','-p',prompt,'--setting-sources','', '--settings','{"hooks":{}}',
           '--strict-mcp-config','--tools','Bash','--allowedTools','Bash',
           '--system-prompt','Execute only the requested disposable verification command. Do not load skills, project instructions or other records. Do not delegate.',
           '--effort','low','--no-session-persistence']
    run(['new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e','FM_HOME='+str(LAB),*cli], tmux=True)
    started = True
    ready = wait_for(lambda:(LAB/'state/.last-check').exists() or (LAB/'hook.rc').exists(), 240)
    capture = run(['capture-pane','-p','-S','-','-t','primary'], check=False, tmux=True).stdout
    (EVIDENCE/('live-primary'+SUFFIX+'-pane.txt')).write_text(capture)
    if not ready:
        result['reason'] = 'The installed Claude CLI was launched on the lab private tmux socket with the normal login, but never reached the executable probe check within 240 seconds. See the captured pane for the specific CLI result.'
    else:
        result['live'] = True
        predicate = (LAB/'predicate.txt').read_text()
        LOG.write('Shared predicate: ' + predicate)
        assert predicate.strip() == 'needed=true in-flight=0 checks=0'
        assert (LAB/'state/.last-check').exists(), 'the real automatic arm did not complete a watcher sweep'
        assert not (LAB/'hook.rc').exists(), 'the automatic hook ended instead of monitoring the kept hold'
        queue = LAB/'state/.wake-queue'
        assert not queue.exists() or queue.stat().st_size == 0
        (LAB/'signed-in').touch()
        os.utime(LAB/'state/.last-check', (1,1))
        assert wait_for(lambda:(LAB/'hook.rc').exists(),240), 'automatic arm did not finish after sign-in'
        rc = (LAB/'hook.rc').read_text().strip()
        stderr = (LAB/'hook.stderr').read_text()
        stdout = (LAB/'hook.stdout').read_text()
        LOG.write('Hook stdout:\n' + stdout + '\nHook stderr:\n' + stderr + '\nHook exit=' + rc + '\n')
        (EVIDENCE/('live-primary'+SUFFIX+'-hook.stderr.txt')).write_text(stderr)
        (EVIDENCE/('live-primary'+SUFFIX+'-state-queue.txt')).write_text(queue.read_text() if queue.exists() else '')
        run([str(ROOT/'bin/fm-tasks-axi.sh'),'show','signin','--full'])
        assert rc == '2' and 'released after a passing probe' in stderr, 'the only probe hold released but the primary received no hook notification (hook exit=' + rc + ')'
        if os.environ.get('PRIMARY_REMAINING_HOLD') != 'yes':
            assert wait_for(lambda:(LAB/'hook2.rc').exists(),20), 'post-release hook never completed'
            assert (LAB/'hook2.rc').read_text().strip() == '0', 'post-release hook did not stand down'
            assert (LAB/'hook2.stderr').read_text() == '', 'release notification repeated'
            LOG.write('Next Stop hook exit=0, stderr empty: release notification delivered once.\n')
        result.update(result='pass', reason='')
except Exception as e:
    result.update(result='fail' if result['live'] else 'untested', reason=str(e))
finally:
    if started:
        capture = run(['capture-pane','-p','-S','-','-t','primary'], check=False, tmux=True).stdout
        (EVIDENCE/('live-primary'+SUFFIX+'-final-pane.txt')).write_text(capture)
        # The lab's copied code owns any watcher stop; the only tmux server
        # stopped here is the lab's private socket.
        run([str(LAB/'bin/fm-watch-arm.sh'),'--stop'], check=False)
        run(['kill-server'], check=False, tmux=True)
    (EVIDENCE/('live-primary'+SUFFIX+'-results.json')).write_text(json.dumps(result,indent=2)+'\n')
    LOG.close()
    print(json.dumps(result),flush=True)
