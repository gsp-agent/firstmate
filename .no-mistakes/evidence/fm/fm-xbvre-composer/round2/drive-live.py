import errno
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import traceback

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
WORK = ROOT / '.nm-composer-round2-live'
assert not WORK.exists(), 'refusing to overwrite a prior fixture'
WORK.mkdir()
env = dict(os.environ)
for key in list(env):
    if key.startswith('HERDR_') or key in ('TMUX', 'TMUX_PANE') or (key.startswith('FM_') and key.endswith('_OVERRIDE')):
        env.pop(key, None)
env['FM_HOME'] = str(WORK / 'home')
env['FM_HERDR_LAB_STATE_DIR'] = str(WORK / 'lab-state')
log = (EVIDENCE / 'live-transcript.log').open('w')
results = {}
helper = str(ROOT / 'bin/fm-herdr-lab.sh')
session = ''
pane = ''
provisioned = False


def run(args, *, check=True, timeout=45, extra_env=None):
    actual_env = dict(env)
    actual_env.update(extra_env or {})
    process = subprocess.run(args, cwd=ROOT, env=actual_env, capture_output=True,
                             text=True, timeout=timeout)
    log.write('$ ' + shlex.join(map(str, args)) + '\n' + process.stdout + process.stderr +
              '\nexit=' + str(process.returncode) + '\n')
    log.flush()
    if check and process.returncode:
        raise RuntimeError(f'{args}: {process.stderr or process.stdout}')
    return process


def lab(*args, **kwargs):
    return run([helper, 'run', session, *args], **kwargs)


def probe(method='fm_backend_herdr_composer_state', *args, base=False, target=None, check=True):
    return run(['bash', str(WORK / 'probe.sh'), 'base' if base else 'target',
                method, target or f'{session}:{pane}', *args], check=check)


def scroll(direction, count=60):
    fd = os.open(WORK / 'viewer-input', os.O_WRONLY | os.O_NONBLOCK)
    try:
        os.write(fd, (b'\x1b[<64;80;20M' if direction == 'up' else b'\x1b[<65;80;20M') * count)
    finally:
        os.close(fd)
    time.sleep(.3)


def capture(label):
    info = lab('pane', 'get', pane).stdout
    (EVIDENCE / (label + '-info.json')).write_text(info)
    for source in ('visible', 'recent'):
        cmd = ['pane', 'read', pane, '--source', source, '--format', 'ansi']
        if source == 'recent':
            cmd.extend(['--lines', '300'])
        (EVIDENCE / (label + '-' + source + '.ansi')).write_text(lab(*cmd).stdout)
    observed = {}
    for name, method in (('state', 'fm_backend_herdr_composer_state'),
                         ('content', 'fm_backend_herdr_composer_content'),
                         ('screen', 'fm_backend_herdr_composer_capture')):
        p = probe(method, *(['ansi'] if name == 'screen' else []), check=False)
        (EVIDENCE / (label + '-' + name + '.txt')).write_text(p.stdout)
        observed[name] = {'exit': p.returncode, 'out': p.stdout}
    observed['scroll'] = json.loads(info)['result']['pane']['scroll']
    print(label, json.dumps({k: v for k, v in observed.items() if k != 'screen'}), flush=True)
    return observed


def empty_ready():
    for _ in range(35):
        state = probe().stdout
        if state == 'empty':
            return
        time.sleep(.2)
    capture('startup-not-ready')
    raise RuntimeError('Claude did not reach an empty composer')


try:
    run(['bin/fm-lab-home.sh', 'create', str(WORK / 'home')])
    (WORK / 'claude-config').mkdir()
    (WORK / 'claude-config/.claude.json').write_text(json.dumps({
        'hasCompletedOnboarding': True,
        'projects': {str(ROOT): {'hasTrustDialogAccepted': True,
                                'hasClaudeMdExternalIncludesApproved': True,
                                'hasClaudeMdExternalIncludesWarningShown': True}},
    }))
    (WORK / 'base/bin/backends').mkdir(parents=True)
    for name in ('bin/backends/herdr.sh', 'bin/fm-composer-lib.sh',
                 'bin/fm-transition-lib.sh', 'bin/fm-agent-process-lib.sh'):
        p = run(['git', 'show', '20dcbf91520b1816663b81873ad67d0b93b3e4d6:' + name])
        (WORK / 'base' / name).write_text(p.stdout)
    session = run([helper, 'name', 'xbvre-round2']).stdout.strip()
    (WORK / 'session').write_text(session)
    (WORK / 'probe.sh').write_text('''#!/usr/bin/env bash
set -u
variant=$1
method=$2
target=$3
shift 3
if [ "$variant" = base ]; then
  . "$PWD/.nm-composer-round2-live/base/bin/backends/herdr.sh"
else
  . "$PWD/bin/backends/herdr.sh"
fi
session=$(cat .nm-composer-round2-live/session)
fm_backend_herdr_cli() {
  local requested=$1
  shift
  [ "$requested" = "$session" ] || return 97
  "$PWD/bin/fm-herdr-lab.sh" run "$requested" "$@"
}
"$method" "$target" "$@"
''')
    # This proxy only transports real viewer I/O, with a nonzero grid before
    # process creation. CLI responses and the product under test are not faked.
    real_herdr = shutil.which('herdr')
    viewer = '''import errno,fcntl,os,select,signal,struct,subprocess,sys,termios
from pathlib import Path
root=Path(%r)
session=(root/'session').read_text().strip()
real=%r
if sys.argv[1:]!=['--session',session]:
    os.execv(real,[real,*sys.argv[1:]])
master,slave=os.openpty()
fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',60,140,0,0))
def setup():
    os.setsid()
    fcntl.ioctl(slave,termios.TIOCSCTTY,0)
p=subprocess.Popen([real,'--session',session],stdin=slave,stdout=slave,stderr=slave,preexec_fn=setup,env={**os.environ,'TERM':'xterm-256color'})
os.close(slave)
fd=os.open(root/'viewer-input',os.O_RDWR|os.O_NONBLOCK)
log=Path(%r).open('wb')
def stop(sig,frame):
    p.send_signal(sig)
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
try:
    while p.poll() is None:
        ready,_,_=select.select([master,fd],[],[],0.5)
        if fd in ready:
            data=os.read(fd,65536)
            if data: os.write(master,data)
        if master in ready:
            try: data=os.read(master,65536)
            except OSError as exc:
                if exc.errno==errno.EIO: break
                raise
            if not data: break
            log.write(data);log.flush();os.write(1,data)
finally:
    if p.poll() is None: p.terminate()
    p.wait(timeout=5)
    os.close(master);os.close(fd);log.close()
''' % (str(WORK), real_herdr, str(EVIDENCE / 'live-viewer.ansi'))
    (WORK / 'viewer-proxy.py').write_text(viewer)
    (EVIDENCE / 'viewer-proxy.py').write_text(viewer)
    os.mkfifo(WORK / 'viewer-input')
    (WORK / 'viewer-bin').mkdir()
    proxy = WORK / 'viewer-bin/herdr'
    proxy.write_text('#!/usr/bin/env bash\nexec python3 ' + shlex.quote(str(WORK / 'viewer-proxy.py')) + ' "$@"\n')
    proxy.chmod(0o700)
    run([helper, 'provision', session])
    provisioned = True
    created = lab('workspace', 'create', '--cwd', str(ROOT), '--label', 'composer-round2', '--no-focus').stdout
    (WORK / 'workspace.json').write_text(created)
    pane = json.loads(created)['result']['root_pane']['pane_id']
    lab('tab', 'focus', json.loads(created)['result']['tab']['tab_id'])
    run([helper, 'viewer', 'start', session], extra_env={'PATH': str(WORK / 'viewer-bin') + ':' + env['PATH']})
    launch = WORK / 'launch.sh'
    launch.write_text('''#!/usr/bin/env bash
set -u
for ((i=1; i<=180; i++)); do printf 'COMPOSER-LAB HISTORY ROW %03d: earlier chat, no live composer here.\\n' "$i"; done
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
export CLAUDE_CONFIG_DIR="$PWD/.nm-composer-round2-live/claude-config"
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
export CLAUDE_CODE_DISABLE_FEEDBACK=1
exec claude --safe-mode --setting-sources '' --settings '{"disableAllHooks":true,"autoMemoryEnabled":false}' --strict-mcp-config --mcp-config '{"mcpServers":{}}'
''')
    lab('pane', 'run', pane, 'FM_HOME=' + shlex.quote(env['FM_HOME']) + ' bash ' + shlex.quote(str(launch)))
    empty_ready()
    results['versions'] = {'herdr': run(['herdr', '--version']).stdout.strip(),
                           'claude': run(['claude', '--version']).stdout.strip(),
                           'session': session, 'pane': pane, 'grid': '60x140, continuously drained'}
    capture('initial')
    scroll('up', 40)
    empty = capture('empty-scrolled')
    baseline = probe(base=True).stdout
    assert empty['scroll']['offset_from_bottom'] > 0
    assert '❯' not in (EVIDENCE / 'empty-scrolled-visible.ansi').read_text()
    assert empty['state']['out'] == 'empty', empty
    assert baseline == 'unknown', baseline
    results['empty_scrolled'] = {'base': baseline, 'target': empty['state']['out'], 'scroll': empty['scroll']}
    print('PASS: scrolled empty composer reproduces base unknown -> target empty', flush=True)

    scroll('down')
    draft = 'UNSENT COMPOSER SAFETY DRAFT ROUND TWO'
    lab('pane', 'send-text', pane, draft)
    lab('pane', 'wait-output', pane, '--match', draft, '--source', 'recent', '--lines', '200', '--timeout', '5000')
    scroll('up', 40)
    d = capture('draft-scrolled')
    assert d['state']['out'] == 'pending' and d['content']['out'] == draft, d
    refusal = probe('fm_backend_herdr_send_text_submit', '/clear', '1', '0.1', '0.1').stdout
    retained = probe('fm_backend_herdr_composer_content').stdout
    assert refusal == 'send-failed' and retained == draft, (refusal, retained)
    results['draft_guard'] = {'state': d['state']['out'], 'verdict': refusal, 'retained': retained}
    print('PASS: reset attempt refuses and preserves original draft', flush=True)

    scroll('down')
    lab('pane', 'send-keys', pane, 'ctrl+u')
    empty_ready()
    lab('pane', 'send-text', pane, '/')
    time.sleep(.4)
    popup = capture('slash-popup')
    assert popup['state']['out'] == 'pending' and popup['content']['out'] == '/', popup
    screen = (EVIDENCE / 'slash-popup-screen.txt').read_text()
    assert screen.count('\n') > 20 and '/exit' in screen and '/context' in screen
    results['full_overlay'] = {'state': popup['state']['out'], 'content': popup['content']['out'],
                               'rows': screen.count('\n') + 1}
    print('PASS: full popup retains composer and excludes selected menu payload', flush=True)
    lab('pane', 'send-keys', pane, 'ctrl+u')
    empty_ready()
    scroll('up', 40)
    clear = probe('fm_backend_herdr_send_text_submit', '/clear', '3', '0.4', '1.2').stdout
    after_clear = capture('after-clear')
    assert clear == 'empty' and after_clear['state']['out'] == 'empty', (clear, after_clear)
    assert lab('agent', 'get', pane, check=False).returncode == 0
    results['clear_submit'] = {'verdict': clear, 'composer': after_clear['state']['out'], 'claude_present': True}
    print('PASS: /clear submitted through popup from a scrolled pane', flush=True)

    scroll('down')
    lab('pane', 'send-text', pane, '/exit')
    time.sleep(.4)
    popup = capture('exit-popup')
    assert popup['state']['out'] == 'pending' and popup['content']['out'] == '/exit', popup
    lab('pane', 'send-keys', pane, 'ctrl+u')
    empty_ready()
    exited = probe('fm_backend_herdr_send_text_submit', '/exit', '3', '0.4', '1.2').stdout
    agent = lab('agent', 'get', pane, check=False)
    assert agent.returncode != 0, agent.stdout
    exit_screen = lab('pane', 'read', pane, '--source', 'recent', '--lines', '200').stdout
    (EVIDENCE / 'after-exit-terminal.txt').write_text(exit_screen)
    results['exit_submit'] = {'verdict': exited, 'claude_absent': True, 'agent_get_exit': agent.returncode}
    print('PASS: /exit submitted through popup and Claude process exited', flush=True)

    lab('pane', 'run', pane, "for i in {1..100}; do printf 'CURRENT SCREEN WITHOUT AGENT COMPOSER\\n'; done")
    time.sleep(.4)
    absent = capture('no-composer')
    assert absent['state']['out'] == 'unknown' and absent['content']['exit'] != 0, absent
    results['unknown_guard'] = {'state': absent['state']['out'], 'content_exit': absent['content']['exit']}
    print('PASS: historic prompt cannot prove composer emptiness', flush=True)

    missing = f'{session}:w99999:p99999'
    missing_state = probe(target=missing).stdout
    missing_submit = probe('fm_backend_herdr_send_text_submit', '/clear', '1', '0.1', '0.1', target=missing).stdout
    assert missing_state == 'unknown' and missing_submit in ('send-failed', 'unknown'), (missing_state, missing_submit)
    results['missing_guard'] = {'state': missing_state, 'submit': missing_submit}
    print('PASS: nonexistent pane stays unknown and refuses submission', flush=True)
except BaseException:
    results['exception'] = traceback.format_exc()
    print(results['exception'], flush=True)
    if pane:
        try:
            capture('failure')
        except BaseException:
            pass
finally:
    if provisioned:
        try:
            cleanup = run([helper, 'teardown', session], timeout=60)
            results['teardown'] = {'exit': cleanup.returncode, 'default_tripwire': 'verified and retired'}
        except BaseException:
            results['teardown_error'] = traceback.format_exc()
    (EVIDENCE / 'live-results.json').write_text(json.dumps(results, indent=2))
    log.close()

if 'exception' in results or 'teardown_error' in results:
    raise SystemExit(1)
