import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import time

root = Path.cwd()
lab = root / '.agent-state/live-validation-r2-keyexec/lab'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M59T4BFDPQD71P8CHEHTBVJJ')
task_id = 'qjzaw-r2-keyexec-01m59'
env = dict(os.environ, FM_HOME=str(lab), GROK_HOME=str(lab/'grok'),
           TREEHOUSE_ROOT=str(lab/'pool'), TMPDIR=str(lab/'cache'),
           QUOTA_AXI_SNAPSHOT=str(lab/'cache-input.json'),
           XDG_CONFIG_HOME=str(lab/'config-cli'), XDG_CACHE_HOME=str(lab/'cache'),
           XDG_DATA_HOME=str(lab/'data-cli'), FM_BACKEND='tmux',
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
for key in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
            'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'TMUX', 'TMUX_PANE',
            'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'TASKS_AXI_FILE',
            'TASKS_AXI_BACKEND', 'FM_TASK_ID']:
    env.pop(key, None)
log = []
def run(args, timeout=80, check=True):
    p = subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout)
    log.append('$ ' + shlex.join(args) + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n')
    if check and p.returncode:
        raise RuntimeError(p.stderr or p.stdout)
    return p

shell = lab / 'lab-shell'
shell.write_text('#!/bin/bash\nexec /bin/bash --noprofile --norc "$@"\n')
shell.chmod(0o700)
env['SHELL'] = str(shell)
# A credential bridge, not a substitute for Grok: exec the installed binary.
credential_bin = lab/'credential-bin'
credential_bin.mkdir()
real_grok = shutil.which('grok')
secret_tool = shutil.which('with-secret')
assert real_grok and secret_tool
wrapper = credential_bin/'grok'
wrapper.write_text('#!/bin/bash\nexec ' + shlex.quote(secret_tool) + ' XAI_API_KEY -- ' + shlex.quote(real_grok) + ' \"$@\"\n')
wrapper.chmod(0o700)
env['PATH'] = str(credential_bin)+os.pathsep+env['PATH']
run(['grok','models'])

project = lab/'project'
if not (project/'.git').exists():
    run(['git', '-C', str(project), 'init', '-q', '-b', 'main'])
    (project/'README.md').write_text('Disposable Grok routing validation project.\n')
    (project/'.gitignore').write_text('.fm-*\n')
    run(['git', '-C', str(project), 'add', 'README.md', '.gitignore'])
    run(['git', '-C', str(project), '-c', 'commit.gpgsign=false', '-c', 'user.name=Gsp Agent',
         '-c', 'user.email=tests@example.invalid', 'commit', '-qm', 'Initialize disposable lab'])
(lab/'config/supervision-host-off').touch()
report = lab/'data'/task_id/'report.md'
brief = lab/'data'/task_id/'brief.md'
if not brief.exists():
    run(['bash', 'bin/fm-brief.sh', task_id, 'project', '--scout'])
    brief.write_text(brief.read_text().replace('{TASK}', 'Verify this disposable worker starts: run pwd, then write GROK_LAB_READY followed by that exact directory into your report file. Stop after writing it.').replace('{FIRSTMATE_SPEC}', 'Run only this small validation task. Do not publish, run no-mistakes, change credentials, or access any other project.'))
socket_dir = run(['bash', 'bin/fm-lab-home.sh', 'tmux-dir', str(lab)]).stdout.strip()
env['TMUX_TMPDIR'] = socket_dir
tmux = ['tmux', '-f', '/dev/null', '-L', 'fm-lab']
started = False
try:
    run(tmux + ['new-session', '-d', '-s', 'driver', '-x', '120', '-y', '40', '-c', str(root), str(shell)])
    started = True
    run(tmux + ['set-option', '-g', 'default-shell', str(shell)])
    run(tmux + ['set-option', '-g', 'default-command', str(shell)])
    socket_path = run(tmux + ['display-message', '-p', '#{socket_path},#{pid},0']).stdout.strip()
    pane = run(tmux + ['display-message', '-p', '#{pane_id}']).stdout.strip()
    env['TMUX'] = socket_path
    env['TMUX_PANE'] = pane
    # The full default chain uses the canonical Muse mapping with no provider override.
    route = run(['bash', 'bin/fm-dispatch-resolve.sh', '--labels', ''])
    profile = next(line.split('profile:',1)[1].strip() for line in route.stdout.splitlines() if 'profile:' in line)
    axes = shlex.split(profile)
    if axes[1] != 'grok':
        raise RuntimeError('The isolated launch must resolve Grok before spawning: ' + route.stdout)
    capacity = lab/'config/project-capacity'
    capacity.write_text('project 0\n')
    blocked = run(['bash', 'bin/fm-spawn.sh', task_id, str(project), '--scout', '--backend', 'tmux', *axes], timeout=150, check=False)
    if blocked.returncode != 75:
        raise RuntimeError('Zero project capacity did not defer Grok: ' + blocked.stdout + blocked.stderr)
    capacity.write_text('project 1\n')
    spawn = run(['bash', 'bin/fm-spawn.sh', task_id, str(project), '--scout', '--backend', 'tmux', *axes], timeout=150, check=False)
    meta = lab/'state'/(task_id+'.meta')
    if meta.exists():
        (evidence/'r2-keyexec-grok-lab-worker.meta').write_text(meta.read_text())
        fields = dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
        target = fields.get('window')
        if target:
            print('Real Grok launched on owned pane '+target, flush=True)
            deadline = time.monotonic()+120
            trusted = False
            capture = ''
            while time.monotonic()<deadline:
                p = subprocess.run(tmux+['capture-pane','-p','-t',target,'-S','-120'], env=env,
                                   text=True,capture_output=True,timeout=5)
                capture = p.stdout
                if report.exists() and 'GROK_LAB_READY' in report.read_text():
                    break
                if 'Trust this folder' in capture or 'trust this folder' in capture:
                    cwd = run(tmux+['display-message','-p','-t',target,'#{pane_current_path}']).stdout.strip()
                    if cwd != fields.get('worktree'):
                        raise RuntimeError('Trust gate cwd did not match lab worker worktree')
                    if not trusted:
                        run(['bash','bin/fm-send.sh',task_id,'--key','Enter'])
                        trusted = True
                if any(token in capture for token in ['Approve in your browser', 'API key is invalid', 'Authentication failed']):
                    break
                time.sleep(.5)
            capture = re.sub(r'\b[A-Z0-9]{4}-[A-Z0-9]{4}\b', '[device approval code redacted]', capture)
            (evidence/'r2-keyexec-grok-lab-pane.txt').write_text(capture)
            log.append('Real Grok pane capture:\n'+capture)
    (evidence/'r2-keyexec-grok-lab-spawn-result.json').write_text(json.dumps({'spawn_exit':spawn.returncode,
        'model_response_verified': bool(report.exists() and 'GROK_LAB_READY' in report.read_text() and fields.get('worktree','MISSING') in report.read_text()),
        'isolation':'marked FM_HOME and GROK_HOME inside gate worktree; private fm-lab tmux socket'},indent=2)+'\n')
    if report.exists():
        (evidence/'r2-keyexec-grok-worker-report.txt').write_text(report.read_text())
finally:
    if started and (lab/'state'/(task_id+'.meta')).exists():
        run(['bash','bin/fm-control.sh',task_id,'exit'], timeout=80, check=False)
    if started:
        run(tmux+['kill-server'], check=False)
    run(['bash','bin/fm-lab-home.sh','teardown',str(lab)],check=False)
    (evidence/'r2-keyexec-grok-lab-spawn-transcript.txt').write_text('\n'.join(log))
print('Saved real isolated Grok spawn transcript and pane capture.')
