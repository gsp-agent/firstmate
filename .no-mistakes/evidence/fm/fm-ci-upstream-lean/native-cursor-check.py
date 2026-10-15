import json
import os
from pathlib import Path
import shlex
import subprocess
import time

root = Path.cwd()
lab = root / 'L'
product = root / '.test-phase/product'
mate = root / '.test-phase/cursor-secondmate-recheck'
mate.mkdir()
(mate / 'data').mkdir()
(mate / 'bin').mkdir()
# Disposable seeded-home fixture, matching the public secondmate layout.
(mate / 'AGENTS.md').write_text('# Isolated validation fixture\nRemain idle; do not run tools.\n')
(mate / '.fm-secondmate-home').write_text('native-cursor-recheck\n')
(mate / 'data/charter.md').write_text('Remain idle for an isolated CLI-mode validation. Do not use tools.\n')
(mate / '.gitignore').write_text('projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n')
subprocess.run(['git', '-C', str(mate), 'init', '-q', '-b', 'main'], check=True)
pstack = lab / 'pstack/.cursor-plugin'
pstack.mkdir(parents=True, exist_ok=True)
(pstack / 'plugin.json').write_text('{"name":"validation-empty","version":"0.15.21"}')
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'NO_MISTAKES_GATE')}
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'), PI_CODING_AGENT_DIR=str(lab / 'pi-agent'), PI_CODING_AGENT_SESSION_DIR=str(lab / 'sessions'), PI_OFFLINE='1', PI_TELEMETRY='0', TMPDIR=str(root / '.test-phase/tmp'))
env.update(HOME=str(lab / 'isolated-user'), SHELL='/bin/bash')
env.update(CURSOR_CONFIG_DIR=str(lab / 'cursor-config'), CURSOR_DATA_DIR=str(lab / 'cursor-data'), CURSOR_AGENT_STORE_FILES_DIR=str(lab / 'cursor-store'), CLAUDE_CONFIG_DIR=str(lab / 'claude-empty'))
env.update(FM_PSTACK_DIR=str(pstack.parent), FM_CURSOR_CLI_CONFIG=str(lab / 'cursor-config/cli-config.json'), FM_CURSOR_MODELS_RULE=str(lab / 'cursor-config/rules/pstack-models.mdc'))
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
with (evidence / 'native-cursor-secondmate.log').open('w') as log:
    def tmux(*args, timeout=15):
        run = subprocess.run(['tmux', '-L', 'fm-lab', *args], env=env, text=True, capture_output=True, timeout=timeout)
        if run.stderr:
            log.write(run.stderr)
        return run
    pi_cli = root / '.test-phase/pi-current/node_modules/.bin/pi'
    cli = shlex.join([str(pi_cli), '--no-extensions', '--no-skills', '--no-context-files', '--no-session', '--offline'])
    assert tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), '-e', f'FM_HOME={lab}', cli).returncode == 0
    try:
        tmux('set-option', '-g', 'default-shell', '/bin/bash')
        tmux('set-option', '-g', 'default-command', '/bin/bash --noprofile --norc')
        output = evidence / 'native-cursor-spawn-output.log'
        command = shlex.join(['bash', str(product / 'bin/fm-spawn.sh'), 'native-cursor-recheck', str(mate), '--secondmate', '--harness', 'cursor']) + ' > ' + shlex.quote(str(output)) + ' 2>&1'
        spawned = tmux('run-shell', '-t', 'primary', command, timeout=60)
        log.write(f'Actual public fm-spawn, actual tmux backend, actual Cursor binary; isolated configuration/data; no credential supplied. Spawn command exit={spawned.returncode}\n')
        log.write(output.read_text() if output.exists() else 'No spawn output file.\n')
        meta = lab / 'state/native-cursor-recheck.meta'
        if meta.exists():
            metadata = meta.read_text()
            log.write('Persisted task metadata:\n' + metadata + '\n')
            target = next(line.split('=', 1)[1] for line in metadata.splitlines() if line.startswith('window='))
            pane_pid = int(tmux('display-message', '-p', '-t', target, '#{pane_pid}').stdout.strip())
            deadline = time.monotonic() + 45
            capture = ''
            native = []
            while time.monotonic() < deadline:
                capture = tmux('capture-pane', '-p', '-t', target, '-S', '-100').stdout
                process_rows = subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], text=True, capture_output=True, check=True).stdout
                rows = []
                for line in process_rows.splitlines():
                    fields = line.strip().split(None, 2)
                    if len(fields) == 3:
                        rows.append((int(fields[0]), int(fields[1]), fields[2]))
                descendants = {pane_pid}
                for _ in range(12):
                    descendants.update(pid for pid, ppid, _ in rows if ppid in descendants)
                native = [(pid, command) for pid, _, command in rows if pid in descendants and '/cursor-agent/' in command and ('index.js' in command or 'cursor-agent-sea' in command)]
                if native:
                    break
                time.sleep(0.1)
            log.write('Kernel-observed native Cursor processes below this pane:\n' + json.dumps(native, indent=2) + '\n')
            log.flush()
            assert native, 'No actual Cursor process could be observed'
            for _, command in native:
                argv = shlex.split(command)
                assert '-p' not in argv and '--print' not in argv and '--output-format' not in argv
            log.write('Real Cursor pane:\n' + capture + '\n')
            allowance = lab / 'state/cursor-dispatch.json'
            log.write(f'Worker launch allowance file exists={allowance.exists()}\n')
            assert not allowance.exists(), 'A secondmate consumed the worker allowance'
        else:
            log.write('No task metadata was published; native Cursor launch was not reached.\n')
    finally:
        tmux('send-keys', '-t', 'primary', 'C-d')
        tmux('kill-server')
print('Native Cursor attempt captured; see native-cursor-secondmate.log for actual setup/result.')
