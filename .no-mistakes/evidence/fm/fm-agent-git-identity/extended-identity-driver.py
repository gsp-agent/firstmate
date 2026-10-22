import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

root = Path.cwd()
run = root / '.identity-validation'
code = run / 'product-b'
lab = run / 'lab3'
mate = run / 'mate3'
user = run / 'user'
project = run / 'project3'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5H6HF07C13SDYMP375JZVNN')
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'GIT_', 'HERDR_', 'TASKS_AXI_')) or key in ('TMUX', 'TMUX_PANE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME'):
        env.pop(key, None)
env.update(HOME=str(user), SHELL='/bin/bash', FM_HOME=str(lab), FM_BACKEND='tmux',
           GIT_CONFIG_GLOBAL=str(user / '.gitconfig'), GIT_CONFIG_NOSYSTEM='1',
           TREEHOUSE_ROOT=str(run / 'pool3'), TMPDIR=str(run / 'tmp'))
logs = []
results = []
socket = None

def call(args, cwd=root, check=True):
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=150)
    logs.append('$ ' + shlex.join([str(x) for x in args]) + '\n' + p.stdout + f'[exit {p.returncode}]\n')
    if check and p.returncode:
        raise RuntimeError(logs[-1])
    return p.stdout.strip()

def tmux(*args, check=True):
    return call(['tmux', '-L', 'fm-lab', *args], check=check)

def brief(home, task):
    directory = home / 'data' / task
    directory.mkdir(parents=True)
    (directory / 'brief.md').write_text("# Task\n## Captain's intent\nVerify worker identity through Git commits, with no publication.\n\n## Firstmate spec\nRun the identity probe only.\n")

def command(task):
    return shlex.join(['python3', str(run / 'probe.py'), str(lab / (task + '.json'))])

def report(task, name, email):
    path = lab / (task + '.json')
    deadline = time.monotonic() + 30
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(.1)
    data = json.loads(path.read_text())
    assert data['email'] == email and data['name'] == name, data
    assert data['author'] == f'{name} <{email}>' and data['committer'] == data['author'], data
    logs.append('WORKER REPORT ' + json.dumps(data, indent=2))
    (evidence / (task + '.json')).write_text(json.dumps(data, indent=2) + '\n')
    return data

try:
    # Byte-for-byte copies of the real executable product keep the secondmate
    # outside that product's code root while all data stays in the run checkout.
    for directory in ('bin', 'docs', '.agents'):
        shutil.copytree(root / directory, code / directory, symlinks=True)
    call([code / 'bin/fm-lab-home.sh', 'create', lab])
    call([code / 'bin/fm-lab-home.sh', 'create', mate])
    (lab / 'config/backlog-backend').write_text('manual\n')
    (lab / 'config/worker-git-identity').write_text('Fleet Parent <parent-agent@example.invalid>\n')
    (lab / 'state/.last-watcher-beat').touch()
    (mate / 'bin').mkdir()
    shutil.copyfile(root / 'AGENTS.md', mate / 'AGENTS.md')
    (mate / '.fm-secondmate-home').write_text('git-live-mate\n')
    (mate / 'data/charter.md').write_text('Identity verification fixture only.\n')
    (mate / '.gitignore').write_text('config/\ndata/\nstate/\nprojects/\n')
    call(['git', 'init', '-q', '-b', 'main', mate])
    socket = call([code / 'bin/fm-lab-home.sh', 'tmux-dir', lab])
    env['TMUX_TMPDIR'] = socket
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), '/bin/bash --noprofile --norc')
    tmux('set-option', '-g', 'default-shell', '/bin/bash')
    env['TMUX'] = tmux('display-message', '-p', '#{socket_path},#{pid},0')
    brief(lab, 'git-live-mate')
    call([code / 'bin/fm-spawn.sh', 'git-live-mate', mate, command('git-live-mate'), '--secondmate'])
    report('git-live-mate', 'Fleet Parent', 'parent-agent@example.invalid')
    assert (mate / 'config/worker-git-identity').read_text() == 'Fleet Parent <parent-agent@example.invalid>\n'
    results.append({'name': 'A real secondmate launch inherits the configured worker identity and commits as that identity', 'result': 'pass'})
    project.mkdir()
    call(['git', 'init', '-q', '-b', 'main', project])
    call(['git', '-C', project, 'commit', '-q', '--allow-empty', '-m', 'fixture baseline'])
    # Spawn from the secondmate's converged home, proving its own crew receives
    # the inherited setting rather than only checking a copied config file.
    env['FM_HOME'] = str(mate)
    (mate / 'state/.last-watcher-beat').touch()
    brief(mate, 'git-live-mate-crew')
    call([code / 'bin/fm-spawn.sh', 'git-live-mate-crew', project, command('git-live-mate-crew'), '--mode', 'local-only', '--yolo', 'off'])
    crew = report('git-live-mate-crew', 'Fleet Parent', 'parent-agent@example.invalid')
    results.append({'name': 'A secondmate\'s own pooled worker makes its first commit as the inherited agent identity', 'result': 'pass'})
    (mate / 'config/worker-git-identity').write_text('Replacement Agent <replacement@example.invalid>\n')
    call([code / 'bin/fm-spawn.sh', 'git-live-mate-crew', '--relaunch', '--harness', command('git-live-relaunched')])
    replacement = report('git-live-relaunched', 'Replacement Agent', 'replacement@example.invalid')
    assert replacement['cwd'] == crew['cwd']
    results.append({'name': 'Relaunch reuses the same worker copy and applies the current identity to its next commit', 'result': 'pass'})
finally:
    if socket:
        tmux('capture-pane', '-p', '-S', '-100', '-t', 'fm-git-live-mate-crew', check=False)
        tmux('kill-server', check=False)
        call([code / 'bin/fm-lab-home.sh', 'teardown', lab], check=False)
    (evidence / 'extended-identity-transcript.log').write_text('\n'.join(logs))
    (evidence / 'extended-identity-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
