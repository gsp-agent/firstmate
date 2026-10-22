import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

root = Path.cwd()
run = root / '.identity-validation'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5H6HF07C13SDYMP375JZVNN')
lab = run / 'lab'
user = run / 'user'
project = run / 'project'
pool = run / 'pool'
transcript = []
results = []
env = os.environ.copy()
for key in list(env):
    if (key.startswith(('FM_', 'GIT_', 'HERDR_', 'TASKS_AXI_')) or
            key in ('TMUX', 'TMUX_PANE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')):
        env.pop(key, None)
env.update(HOME=str(user), SHELL='/bin/bash', GIT_CONFIG_NOSYSTEM='1',
           GIT_CONFIG_GLOBAL=str(user / '.gitconfig'), TREEHOUSE_ROOT=str(pool),
           FM_HOME=str(lab), FM_BACKEND='tmux', TMPDIR=str(run / 'tmp'))

def call(args, cwd=root, check=True, timeout=120):
    p = subprocess.run([str(x) for x in args], cwd=cwd, env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout)
    transcript.append('$ ' + shlex.join([str(x) for x in args]) + '\n' + p.stdout + f'[exit {p.returncode}]\n')
    if check and p.returncode:
        raise RuntimeError(transcript[-1])
    return p

def git(*args):
    return call(['git', '-C', project, *args]).stdout.strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def brief(task):
    directory = lab / 'data' / task
    directory.mkdir()
    (directory / 'brief.md').write_text("# Task\n## Captain's intent\nVerify first worker commit identity in an isolated local repository.\n\n## Firstmate spec\nRun the supplied Git identity probe. Do not publish anything.\n")

def tmux(*args, check=True):
    return call(['tmux', '-L', 'fm-lab', *args], check=check)

def spawn(task, flags, command=None, check=True):
    brief(task)
    command = command or shlex.join(['python3', str(run / 'probe.py'), str(lab / (task + '.json'))])
    return call([root / 'bin/fm-spawn.sh', task, project, command, *flags], check=check)

def wait_report(task):
    path = lab / (task + '.json')
    deadline = time.monotonic() + 30
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(.1)
    if not path.exists():
        raise RuntimeError('probe report missing: ' + task)
    report = json.loads(path.read_text())
    transcript.append('WORKER REPORT ' + json.dumps(report, indent=2) + '\n')
    assert report['name'] == expected_name, report
    assert report['email'] == expected_email, report
    assert report['author'] == f'{expected_name} <{expected_email}>', report
    assert report['committer'] == report['author'], report
    assert report['primary'] != report['cwd'], report
    assert str(pool) in report['cwd'], report
    (evidence / (task + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    return report

socket = None
try:
    user.mkdir()
    project.mkdir()
    (user / '.gitconfig').write_text('[user]\n name = Dale Carman\n email = dale.carman@gmail.com\n')
    call([root / 'bin/fm-lab-home.sh', 'create', lab])
    (lab / 'config/backlog-backend').write_text('manual\n')
    (lab / 'state/.last-watcher-beat').touch()
    git('init', '-q', '-b', 'main')
    (project / 'treehouse.toml').write_text('max_trees = 8\nwarm_pool_size = 0\n')
    git('add', 'treehouse.toml')
    git('commit', '-qm', 'fixture baseline')
    git('config', 'user.name', 'Dale Carman')
    git('config', 'user.email', 'dale.carman@gmail.com')
    baseline = {'email': git('config', 'user.email'), 'author': git('log', '-1', '--format=%an <%ae>')}
    transcript.append('BASELINE ' + json.dumps(baseline) + '\n')
    before_global = digest(user / '.gitconfig')
    before_local = digest(project / '.git/config')
    (run / 'probe.py').write_text('''import json, os, subprocess, sys
from pathlib import Path
def git(*args):
 return subprocess.check_output(['git', *args], text=True).strip()
report = {'name': git('config', 'user.name'), 'email': git('config', 'user.email'), 'hooks': git('config', 'core.hooksPath') if os.environ.get('GIT_CONFIG_COUNT') == '3' else '', 'cwd': os.getcwd(), 'primary': git('worktree', 'list', '--porcelain').splitlines()[0][9:]}
subprocess.run(['git', 'commit', '-q', '--allow-empty', '-m', 'live: first worker identity'], check=True)
report.update(author=git('log', '-1', '--format=%an <%ae>'), committer=git('log', '-1', '--format=%cn <%ce>'), commit=git('rev-parse', 'HEAD'))
Path(sys.argv[1]).write_text(json.dumps(report))
print(json.dumps(report), flush=True)
''')
    socket = call([root / 'bin/fm-lab-home.sh', 'tmux-dir', lab]).stdout.strip()
    env['TMUX_TMPDIR'] = socket
    # These are adversarial inherited identities in both the real pane shell
    # and the actual launch parent; the product must replace all four.
    env.update(GIT_AUTHOR_NAME='Dale Carman', GIT_AUTHOR_EMAIL='dale.carman@gmail.com',
               GIT_COMMITTER_NAME='Dale Carman', GIT_COMMITTER_EMAIL='dale.carman@gmail.com')
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(project), '/bin/bash --noprofile --norc')
    tmux('set-option', '-g', 'default-shell', '/bin/bash')
    env['TMUX'] = tmux('display-message', '-p', '#{socket_path},#{pid},0').stdout.strip()
    expected_name, expected_email = 'gsp-agent', 'dale+gspagent@groovejones.com'
    spawn('git-live-default', ['--mode', 'local-only', '--yolo', 'off'])
    first = wait_report('git-live-default')
    assert first['hooks'].endswith('git-live-default.git-hooks'), first
    results.append({'name': 'Fresh pooled ship uses gsp-agent for config, author, and committer despite Dale config and inherited identities', 'result': 'pass'})
    (lab / 'config/keep-ai-trailers').touch()
    spawn('git-live-scout', ['--scout'])
    wait_report('git-live-scout')
    results.append({'name': 'Scout with trailers retained still replaces inherited Dale identities', 'result': 'pass'})
    expected_name, expected_email = "Fleet O'Agent", 'fleet-agent@example.invalid'
    (lab / 'config/worker-git-identity').write_text(f'{expected_name} <{expected_email}>\n')
    spawn('git-live-custom', ['--mode', 'local-only', '--yolo', 'off'])
    wait_report('git-live-custom')
    results.append({'name': 'Configured worker identity with spaces and apostrophe reaches a real first commit', 'result': 'pass'})
    (lab / 'config/worker-git-identity').write_text('invalid identity\n')
    refusal = spawn('git-live-invalid', ['--mode', 'local-only', '--yolo', 'off'], check=False)
    assert refusal.returncode != 0 and 'config/worker-git-identity' in refusal.stdout, refusal.stdout
    assert not (lab / 'state/git-live-invalid.meta').exists()
    results.append({'name': 'Malformed identity refuses before publishing a worker record', 'result': 'pass'})
    (lab / 'config/worker-git-identity').write_text(f'{expected_name} <{expected_email}>\n')
    for n, override in enumerate(['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']):
        task = f'git-live-override-{n}'
        refusal = spawn(task, ['--mode', 'local-only', '--yolo', 'off'], command=f'env {override}=dale@example.invalid python3 {shlex.quote(str(run / "probe.py"))} {shlex.quote(str(lab / (task + ".json")))}', check=False)
        assert refusal.returncode != 0 and 'worker git identity' in refusal.stdout, refusal.stdout
        assert not (lab / 'state' / (task + '.meta')).exists()
    results.append({'name': 'Raw author and committer overrides are refused before any worker launches', 'result': 'pass'})
    assert before_global == digest(user / '.gitconfig')
    assert before_local == digest(project / '.git/config')
    assert git('config', 'user.email') == 'dale.carman@gmail.com'
    git('commit', '-q', '--allow-empty', '-m', 'live: operator retains own identity')
    assert git('log', '-1', '--format=%an <%ae>') == 'Dale Carman <dale.carman@gmail.com>'
    transcript.append('OPERATOR AFTER: ' + git('log', '-1', '--format=%an <%ae>') + '\nGlobal and repository config SHA-256 unchanged.\n')
    results.append({'name': 'Worker commits leave global and shared repo configuration unchanged and operator commits remain Dale', 'result': 'pass'})
finally:
    if socket:
        tmux('capture-pane', '-p', '-S', '-100', '-t', 'fm-git-live-default', check=False)
        tmux('kill-server', check=False)
        call([root / 'bin/fm-lab-home.sh', 'teardown', lab], check=False)
    (evidence / 'live-identity-transcript.log').write_text('\n'.join(transcript))
    (evidence / 'live-identity-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
