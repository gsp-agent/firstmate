import json
import os
from pathlib import Path
import shlex
import subprocess
import time

root = Path.cwd()
lab = root / 'L'
product = root / '.test-phase/product'
project = root / '.test-phase/native-branch/project'
task = 'native-cursor-worker'
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'NO_MISTAKES_GATE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'), PI_CODING_AGENT_DIR=str(lab / 'pi-agent'), PI_CODING_AGENT_SESSION_DIR=str(lab / 'sessions'), PI_OFFLINE='1', PI_TELEMETRY='0', TMPDIR=str(root / '.test-phase/tmp'), TREEHOUSE_ROOT=str(root / '.test-phase/native-branch/pool'), HOME=str(lab / 'isolated-user'), SHELL='/bin/bash', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(root / '.test-phase/native-branch/empty-gitconfig'))
env.update(CURSOR_CONFIG_DIR=str(lab / 'cursor-config'), CURSOR_DATA_DIR=str(lab / 'cursor-data'), CURSOR_AGENT_STORE_FILES_DIR=str(lab / 'cursor-store'), CLAUDE_CONFIG_DIR=str(lab / 'claude-empty'))
env.update(FM_PSTACK_DIR=str(lab / 'pstack'), FM_CURSOR_CLI_CONFIG=str(lab / 'cursor-config/cli-config.json'), FM_CURSOR_MODELS_RULE=str(lab / 'cursor-config/rules/pstack-models.mdc'), FM_CURSOR_USAGE_DIR=str(lab / 'cursor-usage'))
(lab / 'cursor-usage').mkdir()
(lab / 'cursor-usage/fresh-spending.txt').write_text('cursor_models_pct=10\n')
(lab / 'config/launch-env-allowlist').write_text('')
subprocess.run(['bash', str(product / 'bin/fm-brief.sh'), task, 'fixture', '--mode', 'local-only'], env=env, check=True, stdout=subprocess.DEVNULL)
brief = lab / 'data' / task / 'brief.md'
brief.write_text(brief.read_text().replace('{TASK}', 'Reply with one short acknowledgement. Do not use tools.').replace('{FIRSTMATE_SPEC}', 'Isolated native CLI launch verification; no source changes.'))
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
with (evidence / 'native-cursor-allowlist.log').open('w') as log:
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
        output = evidence / 'native-cursor-worker-spawn.log'
        command = shlex.join(['bash', str(product / 'bin/fm-spawn.sh'), task, str(project), '--mode', 'local-only', '--yolo', 'off', '--harness', 'cursor']) + ' > ' + shlex.quote(str(output)) + ' 2>&1'
        result = tmux('run-shell', '-t', 'primary', command, timeout=100)
        log.write('Real public spawn with launch-env-allowlist enabled; actual tmux/treehouse/Cursor.\n' + output.read_text() + '\n')
        meta = lab / 'state' / (task + '.meta')
        assert meta.exists(), output.read_text()
        metadata = meta.read_text()
        log.write('Persisted task metadata:\n' + metadata + '\n')
        target = next(line.split('=', 1)[1] for line in metadata.splitlines() if line.startswith('window='))
        pane_pid = int(tmux('display-message', '-p', '-t', target, '#{pane_pid}').stdout.strip())
        observed_native = False
        native = []
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            rows = []
            for line in subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], text=True, capture_output=True, check=True).stdout.splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3:
                    rows.append((int(fields[0]), int(fields[1]), fields[2]))
            descendants = {pane_pid}
            for _ in range(12):
                descendants.update(pid for pid, ppid, _ in rows if ppid in descendants)
            native = [(pid, command) for pid, _, command in rows if pid in descendants and '/cursor-agent/' in command and ('index.js' in command or 'cursor-agent-sea' in command)]
            if native and not observed_native:
                log.write('Kernel-observed native Cursor:\n' + json.dumps(native, indent=2) + '\n')
                observed_native = True
            if observed_native and not native:
                break
            time.sleep(0.1)
        capture = tmux('capture-pane', '-p', '-t', target, '-S', '-150').stdout
        stream = lab / 'state' / (task + '.cursor-stream.jsonl')
        log.write('Native worker pane:\n' + capture + '\nCaptured stream:\n' + (stream.read_text() if stream.exists() else '(no stream)') + '\n')
        log.write(f'observed_native={observed_native}; native_still_running={bool(native)}\n')
        log.flush()
        assert observed_native, 'The allowlisted launch did not reach native Cursor'
        assert 'syntax error' not in capture.lower(), capture
        if not native:
            status_file = evidence / 'native-cursor-worker-exit.log'
            tmux('send-keys', '-t', target, '-l', 'printf "native_launch_exit=%s\\n" "$?" > ' + shlex.quote(str(status_file)))
            tmux('send-keys', '-t', target, 'Enter')
            deadline = time.monotonic() + 5
            while not status_file.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            if status_file.exists():
                log.write(status_file.read_text())
    finally:
        tmux('send-keys', '-t', 'primary', 'C-d')
        tmux('kill-server')
print('Native allowlisted Cursor launch attempt complete; actual output and completion state retained.')
