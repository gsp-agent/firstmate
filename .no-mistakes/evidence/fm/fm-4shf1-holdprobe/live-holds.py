import datetime
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
SCRATCH = ROOT / '.test-phase' / os.environ.get('LIVE_CASE_NAME', 'retry')
BASE = dict(os.environ)
for key in list(BASE):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'CLAUDE')) or key in ('TMUX', 'TMUX_PANE'):
        BASE.pop(key)
BASE.update(TMPDIR=str(SCRATCH / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
            FM_BACKLOG_ROW_TIMEOUT_SECS='60',
            REVIEW_PAGE_HOME=str(SCRATCH / 'review-pages-empty'),
            DALE_RECORDS_DIR=str(SCRATCH / 'dale-records-empty'))
Path(BASE['TMPDIR']).mkdir(parents=True, exist_ok=True)
RUN_NAME = os.environ.get('LIVE_CASE_NAME', 'retry')
LOG = (EVIDENCE / ('live-holds-' + RUN_NAME + '-transcript.txt')).open('w', buffering=1)
RESULTS = []
CHILDREN = []

def record(text):
    LOG.write(text + '\n')

def command(home, args, check=True, extra=None, timeout=180):
    env = dict(BASE, FM_HOME=str(home))
    env.update(extra or {})
    record('$ FM_HOME=<disposable:' + home.name + '> ' + shlex.join([str(x) for x in args]))
    child = subprocess.Popen(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    CHILDREN.append(child)
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise
    p = subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
    record(p.stdout.rstrip())
    if p.stderr:
        record('stderr: ' + p.stderr.rstrip())
    record('exit=' + str(p.returncode))
    if check and p.returncode:
        raise AssertionError(p.stderr or p.stdout or str(args))
    return p

def captain(home, *args, **kwargs):
    return command(home, [str(ROOT / 'bin/fm-captain-hold.sh'), *args], **kwargs)

def show(home, name):
    raw = command(home, [str(ROOT / 'bin/fm-tasks-axi.sh'), 'show', name, '--full']).stdout
    normalized = []
    for line in raw.splitlines():
        if line.startswith('  body: "'):
            body = json.loads(line[len('  body: '):])
            record('Decoded persisted body:\n' + body)
            normalized.append('  body:\n' + body)
        else:
            normalized.append(line)
    return '\n'.join(normalized)

def home(name):
    path = SCRATCH / name
    command(path, [str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(path)])
    (path / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (path / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return path

def hold(path, name, probe, step='sign-in', extra=()):
    return captain(path, 'hold', name, '--title', 'Complete the disposable ' + step,
                   '--reason', 'sign in to the disposable service', '--dale-step', step,
                   '--probe', probe, *extra)

def scenario(name, fn):
    record('\nSCENARIO: ' + name)
    start = time.monotonic()
    try:
        fn()
    except Exception as e:
        result = dict(name=name, result='fail', live=True, reason=str(e), seconds=round(time.monotonic()-start, 2))
    else:
        result = dict(name=name, result='pass', live=True, reason='', seconds=round(time.monotonic()-start, 2))
    RESULTS.append(result)
    record('OBSERVED: ' + json.dumps(result))
    print(json.dumps(result), flush=True)

def fields_and_release():
    p = home('manual')
    for step in ('sign-in', 'screen'):
        name = 'pending-' + step
        probe = 'test -f "$FM_HOME/' + step + '-ready"'
        hold(p, name, probe, step)
        shown = show(p, name)
        for value in ('held: yes', 'Decision owner: dale', 'Hold timeout seconds: 3600',
                      'Hold reason: sign in to the disposable service', 'Hold probe: ' + probe):
            assert value in shown, value
        assert 'Captain hold set: ' in shown
        assert 'probe-failed' in captain(p, 'reprobe', name).stdout
        assert 'held: yes' in show(p, name)
        (p / (step + '-ready')).touch()
        assert captain(p, 'reprobe', name).stdout.strip() == 'released: ' + name
        shown = show(p, name)
        assert 'held: no' in shown
        assert 'Resolution mode: probe-released' in shown
        assert 'Reconciliation evidence:' in shown
        assert 'Captain decision:' not in shown
        assert 'Captain hold set:' not in shown
        assert 'state: done' not in shown
        opened = captain(p, 'open', name, check=False)
        assert opened.returncode == 1, 'released task still has an open captain call'

def ordinary_and_deferral():
    p = SCRATCH / 'manual'
    captain(p, 'hold', 'plain', '--title', 'Choose the next action', '--reason', 'ordinary choice', '--until', '2099-01-01')
    shown = show(p, 'plain')
    assert 'held: yes' in shown and 'Hold probe:' not in shown and 'Decision owner:' not in shown
    for step in ('sign-in', 'screen'):
        result = captain(p, 'hold', 'refused-' + step, '--title', 'Complete the step', '--reason', 'complete the step',
                         '--dale-step', step, '--probe', 'true', '--until', '2099-01-01', check=False)
        assert result.returncode != 0 and '--until cannot be combined with --dale-step' in result.stderr
        assert command(p, [str(ROOT/'bin/fm-tasks-axi.sh'), 'show', 'refused-' + step, '--full'], check=False).returncode != 0
    for previous in ('held', 'released'):
        name = 'ordinary-' + previous
        probe = 'printf attempted >> "$FM_HOME/historical-attempts"'
        hold(p, name, probe)
        if previous == 'released':
            captain(p, 'reprobe', name)
        captain(p, 'hold', name, '--reason', 'choose the next action')
        before = (p/'historical-attempts').read_bytes() if (p/'historical-attempts').exists() else b''
        assert 'no-probe' in captain(p, 'reprobe', name).stdout
        shown = show(p, name)
        assert 'held: yes' in shown and 'Hold probe:' not in shown and 'Decision owner:' not in shown
        after = (p/'historical-attempts').read_bytes() if (p/'historical-attempts').exists() else b''
        assert before == after

def changed_while_probing():
    p = SCRATCH / 'manual'
    script = p / 'replace-hold.sh'
    body = p / 'replacement-body.txt'
    body.write_text('Captain hold set: 2099-01-01T00:00:00Z\nDecision owner: dale\nHold timeout seconds: 3600\nHold reason: replacement screen\nHold probe: false\n')
    script.write_text('#!/usr/bin/env bash\n"' + str(ROOT / 'bin/fm-tasks-axi.sh') + '" update changing --body-file "' + str(body) + '"\n')
    hold(p, 'changing', 'bash ' + shlex.quote(str(script)))
    assert 'stamp-changed' in captain(p, 'reprobe', 'changing').stdout
    shown = show(p, 'changing')
    assert 'held: yes' in shown and 'Resolution mode: probe-released' not in shown

def timeout_and_parent_silence():
    parent = home('quiet-parent')
    p = home('quiet-mate')
    (p/'.fm-secondmate-home').write_text('probe-mate\n')
    (p/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=' + str(parent) + '\n')
    script = p / 'hung.sh'
    script.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$$" > "$FM_HOME/hung.pid"\ntrap "" TERM\nsleep 120 &\nprintf "%s\\n" "$!" > "$FM_HOME/child.pid"\nwait\n')
    for name, probe in [('failed', 'false'), ('unknown', 'nonexistent-disposable-hold-probe'), ('hung', 'bash ' + shlex.quote(str(script)))]:
        hold(p, name, probe)
        channel = parent/'state/probe-mate.status'
        before = channel.read_bytes()
        start = time.monotonic()
        assert captain(p, 'reprobe', name).stdout.strip() == 'kept: ' + name + ' probe-failed'
        elapsed = time.monotonic() - start
        record('probe duration seconds=' + str(round(elapsed, 2)))
        assert elapsed < 35
        assert 'held: yes' in show(p, name)
        assert channel.read_bytes() == before, 'a kept probe notified the parent'
    for file in ('hung.pid', 'child.pid'):
        pid = int((p/file).read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            record('timeout descendant stopped: ' + file)
        else:
            raise AssertionError('timeout left process alive: ' + file)

def start_watcher(p, name):
    stdout = (EVIDENCE / (name + '.stdout.txt')).open('w')
    stderr = (EVIDENCE / (name + '.stderr.txt')).open('w')
    env = dict(BASE, FM_HOME=str(p), FM_POLL='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_CHECK_TIMEOUT='120', FM_SECONDMATE_LIVENESS_SECS='99999999')
    record('$ FM_HOME=<disposable:' + p.name + '> FM_POLL=1 FM_CHECK_INTERVAL=999999 bin/fm-watch.sh')
    proc = subprocess.Popen([str(ROOT / 'bin/fm-watch.sh')], cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
    CHILDREN.append(proc)
    return proc

def wait_for(fn, proc, limit=180):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        if fn():
            return
        if proc.poll() is not None:
            raise AssertionError('watcher exited before the expected state (exit ' + str(proc.returncode) + ')')
        time.sleep(0.1)
    raise AssertionError('watcher deadline exceeded')

def sweep():
    p = home('sweep')
    # An idle stock-layout home with no metadata or registered checks.
    probe = 'printf attempted >> "$FM_HOME/probe-attempts"; test -f "$FM_HOME/signed-in"'
    hold(p, 'signin', probe)
    predicate = SCRATCH / 'predicate.sh'
    predicate.write_text('#!/usr/bin/env bash\n. "' + str(ROOT/'bin/fm-supervision-lib.sh') + '"\nfm_supervision_status "$FM_HOME/state"\nprintf "needed=%s in-flight=%s checks=%s\\n" "$FM_SUP_NEEDED" "$FM_SUP_IN_FLIGHT" "$FM_SUP_CHECKS"\n')
    status = command(p, ['bash', str(predicate)]).stdout
    assert 'needed=true in-flight=0 checks=0' in status, status
    hold(p, 'unknown', 'nonexistent-disposable-hold-probe', 'screen')
    hold(p, 'hung', 'sleep 120', 'screen')
    proc = start_watcher(p, 'live-sweep')
    checked = p / 'state/.last-check'
    wait_for(checked.exists, proc)
    assert proc.poll() is None
    assert (EVIDENCE/'live-sweep.stdout.txt').read_text() == ''
    queue = p / 'state/.wake-queue'
    assert not queue.exists() or queue.stat().st_size == 0
    record('first completed sweep: all probes kept; stdout empty; durable notification queue empty')
    before = (p/'probe-attempts').read_bytes()
    # Change the dependency, then observe another completed ordinary poll.
    (p/'signed-in').touch()
    beat = p/'state/.last-watcher-beat'
    initial = beat.stat().st_mtime_ns
    wait_for(lambda: beat.exists() and beat.stat().st_mtime_ns > initial and beat.stat().st_mtime > checked.stat().st_mtime, proc)
    assert (p/'probe-attempts').read_bytes() == before, 'reprobed outside the check cadence'
    os.utime(checked, (1, 1))
    proc.wait(timeout=180)
    assert proc.returncode == 0
    lines = (EVIDENCE/'live-sweep.stdout.txt').read_text().splitlines()
    record('watcher output: ' + repr(lines))
    assert lines == ['check: captain hold signin released after a passing probe']
    record('durable notification: ' + queue.read_text())
    assert 'captain-hold-probe-signin' in queue.read_text()
    assert 'held: no' in show(p, 'signin')
    assert 'held: yes' in show(p, 'unknown')
    assert 'held: yes' in show(p, 'hung')

def interrupted_publish():
    stage = os.environ.get('LIVE_FAILURE_STAGE', 'publish')
    parent = home('recovery-parent-' + stage)
    p = home('recovery-mate-' + stage)
    (p/'.fm-secondmate-home').write_text('probe-mate\n')
    binding = p/'.fm-secondmate-parent'
    valid = 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=' + str(parent) + '\n'
    binding.write_text(valid)
    hold(p, 'signin', 'test -f "$FM_HOME/signed-in"')
    captain(p, 'bind', 'test-board')
    env = dict(BASE, FM_HOME=str(p))
    intake = subprocess.run([str(ROOT/'bin/fm-captain-hold.sh'), 'reconcile-requests', '--source-id', 'test-board', '--source', 'isolated test capture'], input='signin\n', text=True, env=env, capture_output=True, cwd=ROOT)
    record('reconcile request result: ' + intake.stdout + intake.stderr)
    assert intake.returncode == 0
    injected = threading.Event()
    data = p/'data'
    backlog = data/'backlog.md'
    request_dir = p/'state/reconcile-requests'
    def inject_filesystem_fault():
        deadline = time.monotonic()+160
        while time.monotonic() < deadline:
            raw = backlog.read_text()
            if stage == 'normalize' and 'Resolution mode: probe-released' in raw and '(hold-kind: captain)' not in raw:
                data.chmod(0o500)
                injected.set()
                return
            if stage == 'verify' and 'Resolution mode: probe-released' in raw and 'Captain hold set:' not in raw:
                backlog.chmod(0o000)
                injected.set()
                return
            time.sleep(0.01)
    if stage == 'publish':
        binding.write_text('schema=fm-secondmate-parent.v1\nroute=invalid\n')
    elif stage == 'retire':
        request_dir.chmod(0o500)
    elif stage in ('normalize','verify'):
        threading.Thread(target=inject_filesystem_fault, daemon=True).start()
    (p/'signed-in').touch()
    watch_name = 'live-interrupted-release-' + stage
    proc = start_watcher(p, watch_name)
    proc.wait(timeout=180)
    if stage in ('normalize','verify'):
        assert injected.is_set(), 'the real filesystem fault was never applied'
        record('Real filesystem fault applied after unhold: ' + stage)
        data.chmod(0o755)
        backlog.chmod(0o644)
    request_dir.chmod(0o700)
    assert proc.returncode == 0
    lines = (EVIDENCE/(watch_name + '.stdout.txt')).read_text().splitlines()
    record('watcher output: ' + repr(lines))
    assert len(lines) == 1 and 'released but finalization failed' in lines[0]
    assert 'bin/fm-captain-hold.sh reprobe signin' in lines[0]
    assert 'held: no' in show(p, 'signin')
    request = p/'state/reconcile-requests/signin.request'
    assert request.exists()
    binding.write_text(valid)
    (p/'signed-in').rename(p/'signed-out')
    captain(p, 'reprobe', 'signin')
    captain(p, 'reprobe', 'signin')
    shown = show(p, 'signin')
    assert 'held: no' in shown and 'Captain hold set:' not in shown
    assert shown.count('Resolution recorded by fm-captain-hold.') == 1
    assert not request.exists()
    channel = (parent/'state/probe-mate.status').read_text()
    record('parent channel:\n' + channel)
    assert channel.count('resolved [key=captain-hold-signin-1]') == 1

try:
    for label, fn in [
        ('Sign-in and screen holds persist the hold protocol and release only when their dependency becomes ready', fields_and_release),
        ('Ordinary holds retain deferral and deactivate old probes; Dale-step creation refuses deferral', ordinary_and_deferral),
        ('A changed hold survives a probe that passed for the prior hold', changed_while_probing),
        ('Failed, unknown and hung probes retain the hold without notifying the parent; hung descendants stop', timeout_and_parent_silence),
        ('The existing watcher sweeps an idle home on cadence, keeps failures silent and emits one successful-release notification', sweep),
        ('An interrupted parent publication emits a recovery notification and reprobe finalizes exactly once', interrupted_publish),
    ]:
        if len(sys.argv) == 1 or sys.argv[1] == fn.__name__:
            scenario(label, fn)
finally:
    for proc in CHILDREN:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    (EVIDENCE/('live-holds-' + RUN_NAME + '-results.json')).write_text(json.dumps(RESULTS, indent=2) + '\n')
    LOG.close()
