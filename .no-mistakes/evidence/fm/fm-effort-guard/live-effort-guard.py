#!/usr/bin/env python3
"""Drive real Firstmate CLI, Treehouse, Grok, and tmux in a disposable lab."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import time
import traceback

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5CFFE0SW6E27P1VQJFKWX7F')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5CFFE0SW6E27P1VQJFKWX7F')
BASE = ROOT / '.test-effort-guard' / 'live-verified'
BASE.mkdir()
TRANSCRIPT = (EVIDENCE / 'live-effort-guard-verified.log').open('w', buffering=1)
RESULTS = []
ENV = {k: os.environ[k] for k in ('PATH', 'LANG', 'LC_ALL', 'NO_MISTAKES_GATE') if k in os.environ}
ENV.update({'HOME': str(BASE / 'user'), 'SHELL': '/bin/bash', 'TERM': 'xterm-256color',
            'TMPDIR': str(BASE), 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'Lab Test', 'GIT_AUTHOR_EMAIL': 'lab@example.invalid',
            'GIT_COMMITTER_NAME': 'Lab Test', 'GIT_COMMITTER_EMAIL': 'lab@example.invalid',
            'GROK_HOME': str(BASE / 'user' / '.grok'), 'GROK_AGENT_DASHBOARD': '0',
            'XDG_CONFIG_HOME': str(BASE / 'user' / '.config'),
            'XDG_DATA_HOME': str(BASE / 'user' / '.local' / 'share'),
            'XDG_CACHE_HOME': str(BASE / 'user' / '.cache')})
Path(ENV['HOME']).mkdir()
LAB = BASE / 'home'
ENV['FM_HOME'] = str(LAB)
CURRENT = ROOT
SOCKET_DIR = None

def log(message):
    print(message, file=TRANSCRIPT, flush=True)

def run(args, *, env=None, cwd=None, check=True, timeout=95):
    args = [str(v) for v in args]
    log('$ ' + shlex.join(args))
    p = subprocess.run(args, cwd=cwd or ROOT, env=env or ENV,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    log(p.stdout.rstrip())
    log(f'[exit {p.returncode}]')
    if check and p.returncode:
        raise RuntimeError(f'command exited {p.returncode}: {shlex.join(args)}')
    return p

def archive(ref, dest):
    dest.mkdir()
    data = subprocess.check_output(['git', 'archive', ref], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(dest, filter='data')
    log(f'Extracted tracked product {ref} into disposable {dest}')

def tmux(*args, **kw):
    return run(['tmux', '-L', 'fm-lab', *args], **kw)

def windows():
    return tmux('list-windows', '-t', 'primary', '-F', '#{window_name}').stdout.splitlines()

def meta(task):
    path = LAB / 'state' / (task + '.meta')
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)

def capture(task):
    return tmux('capture-pane', '-p', '-t', 'primary:fm-' + task, '-S', '-60').stdout

def config(value):
    path = LAB / 'config' / 'crew-dispatch.json'
    path.write_text(json.dumps(value) + '\n')
    log('Dispatch configuration: ' + json.dumps(value))

def profile(effort='xhigh', model='grok-4.7', harness='grok'):
    return {'harness': harness, 'model': model, 'effort': effort}

def brief(task, kind='scout', reason=''):
    args = [CURRENT / 'bin' / 'fm-brief.sh', task, 'lab-project']
    args += ['--scout'] if kind == 'scout' else ['--mode', 'local-only', '--project', PROJECT]
    run(args)
    path = LAB / 'data' / task / 'brief.md'
    value = path.read_text().replace('{TASK}', 'Perform the isolated effort guard launch check. ' + reason)
    value = value.replace('{FIRSTMATE_SPEC}', 'Do not edit files or invoke tools. Await the test operator.')
    path.write_text(value)

def spawn(task, *args, kind='scout', product=None):
    return run([(product or CURRENT) / 'bin' / 'fm-spawn.sh', task, PROJECT,
                *(['--scout'] if kind == 'scout' else ['--mode', 'local-only', '--yolo', 'off']),
                *args], check=False)

def refuse(task, args, kind='scout', expected=('grok-4.7', 'xhigh')):
    brief(task, kind)
    before = windows()
    pool_before = sorted(str(p) for p in POOL.rglob('.git')) if POOL.exists() else []
    p = spawn(task, *args, kind=kind)
    assert p.returncode == 1, p.stdout
    assert 'config/crew-dispatch.json is active' in p.stdout, p.stdout
    assert all(s in p.stdout for s in expected), p.stdout
    assert not (LAB / 'state' / (task + '.meta')).exists()
    assert windows() == before
    assert (sorted(str(p) for p in POOL.rglob('.git')) if POOL.exists() else []) == pool_before
    log('Observed refusal with unchanged endpoint inventory, worktree pool, and no task metadata.')

def record(name, fn):
    log('\nSCENARIO: ' + name)
    try:
        fn()
    except Exception as exc:
        log(traceback.format_exc())
        RESULTS.append({'name': name, 'result': 'fail', 'live': True,
                        'evidence': str(EVIDENCE / 'live-effort-guard-verified.log'), 'reason': str(exc)})
        print('FAIL ' + name, flush=True)
    else:
        RESULTS.append({'name': name, 'result': 'pass', 'live': True,
                        'evidence': str(EVIDENCE / 'live-effort-guard-verified.log'), 'reason': ''})
        print('PASS ' + name, flush=True)
    (EVIDENCE / 'live-verified-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')

def observed_launch(task, harness, model, effort):
    saved = meta(task)
    log('Persisted task profile: ' + json.dumps({k: saved.get(k) for k in
        ('kind', 'harness', 'model', 'effort', 'project', 'worktree', 'window')}))
    assert (saved['harness'], saved['model'], saved['effort']) == (harness, model, effort)
    # Inspect the real CLI process, not the staged launch file or its shell echo.
    pane_pid = tmux('display-message', '-p', '-t', 'primary:fm-' + task, '#{pane_pid}').stdout.strip()
    deadline = time.monotonic() + 10
    found = ''
    while time.monotonic() < deadline and not found:
        pending = [pane_pid]
        seen = set()
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            command = subprocess.run(['ps', '-p', pid, '-o', 'command='],
                capture_output=True, text=True).stdout.strip()
            if harness in command and '--model ' + model in command and '--reasoning-effort ' + effort in command:
                # Preserve only the CLI prefix and concrete axes; the following
                # multi-line prompt is irrelevant to launch-profile validation.
                found = command.split('FIRSTMATE_OP:', 1)[0].strip()
                log('Running CLI argv: ' + found)
                break
            children = subprocess.run(['pgrep', '-P', pid], capture_output=True, text=True).stdout.splitlines()
            pending.extend(children)
        if not found:
            time.sleep(0.1)
    assert found, 'No live Grok process with the requested model/effort was observed.'
    return saved

try:
    run([ROOT / 'bin' / 'fm-lab-home.sh', 'create', LAB])
    (LAB / 'config' / 'backend').write_text('tmux\n')
    (LAB / 'config' / 'backlog-backend').write_text('manual\n')
    (LAB / 'config' / 'supervision-host-off').touch()
    SOCKET_DIR = run([ROOT / 'bin' / 'fm-lab-home.sh', 'tmux-dir', LAB]).stdout.strip()
    ENV['TMUX_TMPDIR'] = SOCKET_DIR
    tmux('-f', '/dev/null', 'new-session', '-d', '-x', '160', '-y', '45', '-s', 'primary',
         '-c', ROOT, '-e', 'FM_HOME=' + str(LAB), '/bin/bash', '--noprofile', '--norc')
    socket_path = tmux('display-message', '-p', '-t', 'primary', '#{socket_path}').stdout.strip()
    server_pid = tmux('display-message', '-p', '-t', 'primary', '#{pid}').stdout.strip()
    ENV['TMUX'] = f'{socket_path},{server_pid},0'
    tmux('display-message', '-p', '-t', 'primary', 'terminal grid #{pane_width}x#{pane_height}')

    PROJECT = BASE / 'project'
    POOL = BASE / 'pool'
    PROJECT.mkdir()
    ENV['TREEHOUSE_ROOT'] = str(POOL)
    tmux('set-environment', '-g', 'TREEHOUSE_ROOT', POOL)
    run(['git', 'init', '-q', '-b', 'main', PROJECT])
    (PROJECT / 'README.md').write_text('Disposable Firstmate effort guard lab.\n')
    (PROJECT / '.gitignore').write_text('.fm-*\n.claude/\n.grok/\n')
    (PROJECT / 'treehouse.toml').write_text('max_trees = 24\nroot = "' + str(POOL) + '"\n')
    run(['git', '-C', PROJECT, 'add', 'README.md', '.gitignore', 'treehouse.toml'])
    run(['git', '-C', PROJECT, 'commit', '-qm', 'Seed disposable lab'])
    run(['grok', '--version'])
    config({'rules': [{'when': 'livecheck', 'use': profile()}]})

    def mismatch():
        for kind in ('ship', 'scout'):
            refuse('bad-' + kind, ['--harness', 'grok', '--model', 'grok-4.7', '--effort', 'medium'], kind)
        refuse('bad-model', ['--harness', 'grok', '--model', 'grok-4.6', '--effort', 'xhigh'])
    record('Mismatched crew/scout effort or model is refused before worktree or endpoint allocation', mismatch)

    def raw_boundary():
        for kind in ('ship', 'scout'):
            refuse('raw-' + kind, ['grok --always-approve --model grok-4.7 --reasoning-effort medium'], kind)
        refuse('raw-matching', ['grok --always-approve --model grok-4.7 --reasoning-effort xhigh'])
    record('Raw commands on a configured harness refuse and print its dispatch pair', raw_boundary)

    def sources():
        for label, value in [
            ('default-object', {'default': profile()}),
            ('default-array', {'default': [profile(), profile('high')]}),
            ('label', {'label_routes': {'livecheck': profile()}}),
            ('rule-array', {'rules': [{'when': 'livecheck', 'use': [profile(), profile('high')]}]})]:
            config(value)
            refuse('source-' + label, ['--harness', 'grok', '--model', 'grok-4.7', '--effort', 'medium'])
        config({'rules': [{'when': 'livecheck', 'use': profile()}]})
    record('Profiles in default objects/arrays, label routes, and rule arrays all enforce their pairs', sources)

    def canonical():
        brief('matching')
        p = spawn('matching', '--harness', 'grok', '--model', 'grok-4.7', '--effort', 'xhigh')
        assert p.returncode == 0, p.stdout
        observed_launch('matching', 'grok', 'grok-4.7', 'xhigh')
    record('The configured canonical Grok xhigh pair allocates and launches with the recorded profile', canonical)

    def raw_unnamed():
        brief('unnamed')
        p = spawn('unnamed', 'printf "UNNAMED_RAW_LAUNCHED\\n"')
        assert p.returncode == 0, p.stdout
        assert meta('unnamed')['harness'] == 'printf'
        assert 'UNNAMED_RAW_LAUNCHED' in capture('unnamed')
    record('A raw command on an unnamed harness still executes successfully', raw_unnamed)

    def rung_skip():
        config({'default': [profile(), profile('high')]})
        brief('rung-skip', reason='Rung skip reason: bounded manual check selects the configured second rung.')
        p = spawn('rung-skip', '--harness', 'grok', '--model', 'grok-4.7', '--effort', 'high')
        assert p.returncode == 0, p.stdout
        observed_launch('rung-skip', 'grok', 'grok-4.7', 'high')
    record('A reasoned canonical rung skip can select another configured pair', rung_skip)

    def absent_dispatch():
        path = LAB / 'config' / 'crew-dispatch.json'
        parked = LAB / 'config' / 'crew-dispatch.saved'
        path.rename(parked)
        try:
            brief('no-file')
            p = spawn('no-file', 'grok --version', '--model', 'grok-4.7', '--effort', 'medium')
            assert p.returncode == 0, p.stdout
            assert meta('no-file')['effort'] == 'medium'
            assert 'grok' in capture('no-file')
        finally:
            parked.rename(path)
    record('Without a dispatch file a raw named-harness launch keeps existing behavior', absent_dispatch)

    def baseline_and_relaunch():
        historical = BASE / 'before'
        archive('8a8b4734', historical)
        config({'rules': [{'when': 'livecheck', 'use': profile()}]})
        brief('regression')
        p = spawn('regression', '--harness', 'grok', '--model', 'grok-4.7', '--effort', 'medium', product=historical)
        assert p.returncode == 0, p.stdout
        old = observed_launch('regression', 'grok', 'grok-4.7', 'medium')
        log('Pre-fix regression reproduced: dispatch file names xhigh, but a real medium launch was accepted.')
        # Stop exactly this disposable pane's process, retaining the product endpoint.
        tmux('respawn-pane', '-k', '-t', 'primary:fm-regression', '-c', old['worktree'],
             '/bin/bash', '--noprofile', '--norc')
        run([ROOT / 'bin' / 'fm-control.sh', 'regression', 'exit'])
        p = run([ROOT / 'bin' / 'fm-spawn.sh', 'regression', '--relaunch'], check=False)
        assert p.returncode == 0, p.stdout
        assert 'adopts the dispatch file pair' in p.stdout, p.stdout
        new = observed_launch('regression', 'grok', 'grok-4.7', 'xhigh')
        assert old['worktree'] == new['worktree'] and old['window'] == new['window']
    record('Pre-fix medium launch is reproduced and an already-stopped task relaunches at the file xhigh pair', baseline_and_relaunch)

    def ambiguous_relaunch():
        old = meta('no-file')
        run([ROOT / 'bin' / 'fm-control.sh', 'no-file', 'exit'])
        config({'default': [profile(), profile('high')]})
        before = (LAB / 'state' / 'no-file.meta').read_bytes()
        p = run([ROOT / 'bin' / 'fm-spawn.sh', 'no-file', '--relaunch'], check=False)
        assert p.returncode == 1, p.stdout
        assert 'more than one pair' in p.stdout and 'xhigh' in p.stdout and 'high' in p.stdout
        assert before == (LAB / 'state' / 'no-file.meta').read_bytes()
        log('Refusal preserved the stopped task record and both identity axes: ' + old['worktree'] + ', ' + old['window'])
    record('An already-stopped relaunch refuses ambiguous configured pairs and preserves the task record', ambiguous_relaunch)

    def secondmate():
        # A disposable product copy permits sibling lab homes without crossing the workspace boundary.
        global CURRENT
        copied = BASE / 'product'
        archive('HEAD', copied)
        assert (copied / 'bin' / 'fm-spawn.sh').read_bytes() == (ROOT / 'bin' / 'fm-spawn.sh').read_bytes()
        CURRENT = copied
        sm = BASE / 'secondmate'
        run([ROOT / 'bin' / 'fm-lab-home.sh', 'create', sm])
        (sm / '.fm-secondmate-home').write_text('secondmate\n')
        (sm / 'AGENTS.md').write_bytes((ROOT / 'AGENTS.md').read_bytes())
        (sm / '.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n.no-mistakes/\n')
        (sm / 'bin').mkdir()
        (sm / 'data' / 'charter.md').write_text('Disposable launch check. Do not act.\n')
        run(['git', 'init', '-q', '-b', 'main', sm])
        run(['git', '-C', sm, 'add', 'AGENTS.md'])
        run(['git', '-C', sm, 'commit', '-qm', 'Seed disposable home'])
        config({'default': profile()})
        p = run([copied / 'bin' / 'fm-spawn.sh', 'secondmate', sm, '--secondmate',
                 'grok --version', '--model', 'grok-4.7', '--effort', 'medium'], check=False)
        assert p.returncode == 0, p.stdout
        saved = meta('secondmate')
        assert (saved['kind'], saved['harness'], saved['effort']) == ('secondmate', 'grok', 'medium')
        capture('secondmate')
        log('Secondmate named raw launch remained exempt, with its medium pair recorded.')
        CURRENT = ROOT
    record('A secondmate raw launch remains exempt even when its named harness has a different configured effort', secondmate)
finally:
    if SOCKET_DIR:
        tmux('kill-server', check=False)
        run([ROOT / 'bin' / 'fm-lab-home.sh', 'teardown', LAB], check=False)
        log('Stopped the owned lab tmux server and removed its private socket directory.')
    TRANSCRIPT.close()
