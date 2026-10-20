import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

ROOT = Path.cwd()
OUT = Path('/Users/dalecarman/.no-mistakes/evidence/01M5C3XYXFM7NBK7ZVCGA9DWM2')
LOCAL_CONFIG = '--local-config' in sys.argv
LAB = ROOT / ('.nm-live-test/herdr-home-local-config-2' if LOCAL_CONFIG else '.nm-live-test/herdr-home-retry')
HELPER = ROOT / 'bin/fm-herdr-lab.sh'
SESSION = 'fm-lab-nm-drain-05m5' if LOCAL_CONFIG else 'fm-lab-nm-drain-03m5'
ENV = os.environ.copy()
for key in list(ENV):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key.startswith('HERDR_') or key in ('FM_GATE_REFUSE_BYPASS', 'TMUX', 'CLAUDECODE'):
        ENV.pop(key, None)
ENV.update(FM_HOME=str(LAB), FM_HERDR_LAB_STATE_DIR=str(ROOT / '.nm-live-test/herdr-state'),
           TMPDIR=str(ROOT / '.nm-live-test/tmp'), SHELL='/bin/bash',
           ZDOTDIR=str(LAB / 'config/empty-zdot'), BASH_ENV='/dev/null')

def run(args, check=True):
    args = [str(x) for x in args]
    print('$ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=100)
    print(p.stdout, end='', flush=True)
    print(p.stderr, end='', flush=True)
    print('exit: ' + str(p.returncode), flush=True)
    if check:
        assert p.returncode == 0
    return p

def lab(*args, check=True):
    return run([HELPER, 'run', SESSION, *args], check=check)

def snapshot(name, pane):
    ansi = lab('pane', 'read', pane, '--source', 'visible', '--format', 'ansi').stdout
    text = lab('pane', 'read', pane, '--source', 'visible').stdout
    (OUT / (name + '.ansi')).write_text(ansi)
    (OUT / (name + '.txt')).write_text(text)
    return text

started = False
try:
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    (LAB / 'config/empty-zdot').mkdir()
    if LOCAL_CONFIG:
        local_config = LAB / 'claude-config'
        local_config.mkdir()
        (local_config / '.claude.json').write_text(json.dumps({'theme': 'dark', 'hasCompletedOnboarding': True,
            'projects': {str(ROOT): {'hasTrustDialogAccepted': True}}}))
        ENV['CLAUDE_CONFIG_DIR'] = str(local_config)
    settings = LAB / 'config/claude-test.json'
    settings.write_text(json.dumps({'disableAllHooks': True, 'feedbackDrafts': 'off'}))
    run([HELPER, 'provision', SESSION])
    started = True
    run([HELPER, 'viewer', 'start', SESSION])
    response = lab('workspace', 'create', '--cwd', ROOT, '--label', 'nm-composer', '--no-focus')
    pane = json.loads(response.stdout)['result']['root_pane']['pane_id']
    lab('pane', 'get', pane)
    command = shlex.join(['env', '-u', 'NO_MISTAKES_GATE', '-u', 'FM_GATE_REFUSE_BYPASS',
        '-u', 'FM_ROOT_OVERRIDE', '-u', 'FM_STATE_OVERRIDE', '-u', 'FM_DATA_OVERRIDE',
        '-u', 'FM_CONFIG_OVERRIDE', '-u', 'FM_PROJECTS_OVERRIDE',
        'FM_HOME=' + str(LAB), 'CLAUDE_CODE_DISABLE_AUTO_MEMORY=1',
        'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false', 'CLAUDE_CODE_SEND_FEEDBACK=0',
        'claude', '--permission-mode', 'auto', '--setting-sources', 'project,local',
        '--settings', str(settings)])
    if LOCAL_CONFIG:
        command = 'env CLAUDE_CONFIG_DIR=' + shlex.quote(str(local_config)) + ' ' + command
    launch = LAB / 'start-claude.sh'
    launch.write_text('#!/usr/bin/env bash\nexec ' + command + '\n')
    lab('pane', 'run', pane, 'bash', launch)
    deadline = time.monotonic() + 45
    screen = ''
    while time.monotonic() < deadline:
        screen = lab('pane', 'read', pane, '--source', 'visible').stdout
        if any(s in screen for s in ('trust this folder', 'Quick safety check', 'Sign in', 'Select login', 'Select login method', 'Select a login', 'external CLAUDE.md', 'auto mode on')):
            break
        time.sleep(1)
    screen = snapshot('claude-local-config-initial' if LOCAL_CONFIG else 'claude-live-initial', pane)
    lab('pane', 'process-info', '--pane', pane, check=False)
    lab('agent', 'get', pane, check=False)
    if any(s in screen for s in ('trust this folder', 'Quick safety check', 'external CLAUDE.md')):
        print('LIVE_HERDR_RESULT: untested: Claude reached a folder/import trust dialog. Answering would persist user-level configuration outside the worktree; this run cannot grant that trust. Re-run with this worktree trusted by the operator or permission to save its trust entry.', flush=True)
    elif any(s in screen for s in ('Sign in', 'Select login', 'Select a login')):
        print('LIVE_HERDR_RESULT: untested: the disposable Claude configuration does not inherit the normal login. The normal configuration separately stopped at a worktree-trust dialog. No credentials were copied or changed. Re-run after the operator trusts this worktree in the normal configuration, or supplies an authenticated disposable configuration.', flush=True)
    elif 'auto mode on' not in screen:
        print('LIVE_HERDR_RESULT: untested: real Claude did not reach a recognizable idle composer within 45 seconds; initial pane capture records the blocker.', flush=True)
    else:
        # A real idle composer is available. Route the classifier through a
        # forwarding function: every actual Herdr operation still uses the lab helper.
        adapter = LAB / 'classify.sh'
        adapter.write_text('''#!/usr/bin/env bash
set -u
root=$1 helper=$2 session=$3 target=$4
herdr() {
  local -a args=("$@")
  local n=${#args[@]}
  [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$session" ] || return 97
  "$helper" run "$session" "${args[@]:0:n-2}"
}
. "$root/bin/backends/herdr.sh"
fm_backend_herdr_composer_state "$target"
printf '\\n'
fm_backend_herdr_composer_content "$target"
''')
        empty = run(['bash', adapter, ROOT, HELPER, SESSION, SESSION + ':' + pane])
        assert empty.stdout.splitlines()[0] == 'empty'
        lab('pane', 'send-text', pane, '/exit')
        time.sleep(1)
        snapshot('claude-live-slash-popup', pane)
        pending = run(['bash', adapter, ROOT, HELPER, SESSION, SESSION + ':' + pane])
        assert pending.stdout.splitlines()[0] == 'pending' and '/exit' in pending.stdout
        print('LIVE_HERDR_RESULT: pass: real Claude idle composer was empty and its slash popup preserved the typed /exit as pending.', flush=True)
finally:
    if started:
        run([HELPER, 'teardown', SESSION])
