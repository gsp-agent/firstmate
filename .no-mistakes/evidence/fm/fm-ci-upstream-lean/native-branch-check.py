import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
lab = root / 'L'
fixture = root / '.test-phase/native-branch'
fixture.mkdir()
project = fixture / 'project'
sibling = fixture / 'sibling'
pool = fixture / 'pool'
userhome = lab / 'isolated-user'
userhome.mkdir(exist_ok=True)
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'NO_MISTAKES_GATE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'), PI_CODING_AGENT_DIR=str(lab / 'pi-agent'), PI_CODING_AGENT_SESSION_DIR=str(lab / 'sessions'), PI_OFFLINE='1', PI_TELEMETRY='0', TMPDIR=str(root / '.test-phase/tmp'), TREEHOUSE_ROOT=str(pool), HOME=str(userhome), SHELL='/bin/bash', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(fixture / 'empty-gitconfig'))
(fixture / 'empty-gitconfig').write_text('')

def git(*args):
    return subprocess.run(['git', *args], env=env, check=True, text=True, capture_output=True).stdout.strip()

git('init', '-q', '-b', 'main', str(project))
(project / 'README.md').write_text('Isolated branch-preservation fixture\n')
git('-C', str(project), 'add', 'README.md')
git('-C', str(project), '-c', 'user.name=Validation Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture base')
task = 'native-ship-sibling'
git('-C', str(project), 'worktree', 'add', '-q', '-b', 'fm/' + task, str(sibling))
(sibling / 'unlanded.txt').write_text('This sibling commit must survive.\n')
git('-C', str(sibling), 'add', 'unlanded.txt')
git('-C', str(sibling), '-c', 'user.name=Validation Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'unlanded sibling work')
(sibling / 'dirty.txt').write_text('This dirty sibling file must survive.\n')
before = {'head': git('-C', str(sibling), 'rev-parse', 'HEAD'), 'branch': git('-C', str(sibling), 'branch', '--show-current'), 'dirty': (sibling / 'dirty.txt').read_text()}
subprocess.run(['bash', str(root / '.test-phase/product/bin/fm-brief.sh'), task, 'fixture', '--mode', 'local-only'], env=env, check=True, stdout=subprocess.DEVNULL)
brief = lab / 'data' / task / 'brief.md'
brief.write_text(brief.read_text().replace('{TASK}', 'Preserve the sibling branch and its dirty file; refuse the launch.').replace('{FIRSTMATE_SPEC}', 'Isolated real tmux/treehouse verification.'))
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
with (evidence / 'native-branch-preservation.log').open('w') as log:
    def tmux(*args, timeout=15):
        p = subprocess.run(['tmux', '-L', 'fm-lab', *args], env=env, text=True, capture_output=True, timeout=timeout)
        if p.stderr:
            log.write(p.stderr)
        return p
    pi_cli = root / '.test-phase/pi-current/node_modules/.bin/pi'
    cli = shlex.join([str(pi_cli), '--no-extensions', '--no-skills', '--no-context-files', '--no-session', '--offline'])
    assert tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), '-e', f'FM_HOME={lab}', cli).returncode == 0
    try:
        tmux('set-option', '-g', 'default-shell', '/bin/bash')
        tmux('set-option', '-g', 'default-command', '/bin/bash --noprofile --norc')
        output = evidence / 'native-branch-spawn-output.log'
        command = shlex.join(['bash', str(root / '.test-phase/product/bin/fm-spawn.sh'), task, str(project), '--mode', 'local-only', '--yolo', 'off', '--harness', 'pi']) + ' > ' + shlex.quote(str(output)) + ' 2>&1; printf "spawn_exit=%s\\n" "$?" >> ' + shlex.quote(str(output))
        tmux('run-shell', '-t', 'primary', command, timeout=100)
        actual = output.read_text()
        log.write('Real fm-spawn, real tmux, real treehouse; disposable project and worktree pool.\nBefore:\n' + json.dumps(before, indent=2) + '\nPublic spawn output:\n' + actual + '\n')
        after = {'head': git('-C', str(sibling), 'rev-parse', 'HEAD'), 'branch': git('-C', str(sibling), 'branch', '--show-current'), 'dirty': (sibling / 'dirty.txt').read_text()}
        log.write('After:\n' + json.dumps(after, indent=2) + '\n')
        log.write('Task metadata exists=' + str((lab / 'state' / (task + '.meta')).exists()) + '\n')
        log.flush()
        assert before == after
        assert str(sibling) in actual and 'refusing' in actual and 'spawn_exit=1' in actual, actual
        assert not (lab / 'state' / (task + '.meta')).exists()
    finally:
        tmux('send-keys', '-t', 'primary', 'C-d')
        tmux('kill-server')
print('Native branch-preservation scenario passed.')
