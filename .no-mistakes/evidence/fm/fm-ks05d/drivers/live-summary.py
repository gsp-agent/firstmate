import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

ROOT = Path.cwd()
BASE = ROOT / '.test-phase/live'
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEEJBFTMC18N0RBFS5569B')
BASE.mkdir(exist_ok=True)
envbase = dict(os.environ)
for key in list(envbase):
    if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_', 'TMUX')):
        envbase.pop(key)
envbase.update(HOME=str(ROOT / '.test-phase/user-home'), TMPDIR=str(ROOT / '.test-phase/tmp'),
               CODEX_HOME=str(ROOT / '.test-phase/codex'), CLAUDE_CONFIG_DIR=str(ROOT / '.test-phase/claude'))
transcript = EVIDENCE / 'live-summary-transcript.log'

def log(message):
    print(message, flush=True)
    with transcript.open('a') as f:
        f.write(message + '\n')

def home(name, mate=True, orphans=0):
    h = BASE / name
    subprocess.run([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(h)], check=True, capture_output=True)
    for d in ('state', 'config', 'data', 'projects'):
        (h / d).mkdir(exist_ok=True)
    (h / 'config/backlog-backend').write_text('manual\n')
    if mate:
        (h / '.fm-secondmate-home').write_text('mate\n')
    backlog(h, orphans=orphans)
    return h

def backlog(h, queued='', orphans=0):
    inflight = ''.join(f'- [ ] orphan-{i} - Missing record (repo: firstmate) (kind: ship)\n' for i in range(orphans))
    queue = f'- [ ] {queued} - New queued event (repo: firstmate) (kind: ship)\n' if queued else ''
    (h / 'data/backlog.md').write_text(f'## In flight\n{inflight}\n## Queued\n{queue}\n## Done\n')

def env(h, **extra):
    return dict(envbase, FM_HOME=str(h), FM_ROOT_OVERRIDE=str(ROOT), **{k: str(v) for k,v in extra.items()})

def cli(h, args=(), **extra):
    start = time.monotonic()
    p = subprocess.run([str(ROOT / 'bin/fm-home-summary-refresh.sh'), *args], env=env(h, **extra),
                       capture_output=True, text=True, timeout=25)
    log(f'$ FM_HOME=live/{h.name} fm-home-summary-refresh.sh {" ".join(args)} => exit {p.returncode} ({time.monotonic()-start:.3f}s)')
    if p.stderr:
        log(p.stderr.strip())
    assert p.returncode == 0
    return p

def wait(predicate, limit=20):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError('condition did not become true within deadline')

def ledger(h):
    try:
        return json.loads((h / 'state/home-summary.json').read_text())
    except FileNotFoundError:
        return None

def idle(h):
    return not (h / 'state/.home-summary-drain.lock').exists() and not (h / 'state/.home-summary-dirty').exists()

def save(h, label):
    text = (h / 'state/home-summary.json').read_text()
    (EVIDENCE / f'{label}.json').write_text(text)
    log(f'published {label}: ' + json.dumps({k:json.loads(text)[k] for k in ('schema','generated_epoch','valid','state','counts')}))

def run():
    h = home('main', False)
    for _ in range(5):
        cli(h, ['--request'])
    assert list((h / 'state').iterdir()) == []
    log('MAIN REQUEST: five requests left state empty; no producer, ledger, mark, or drain.')
    cli(h, FM_SNAPSHOT_NOW='2026-10-22T15:00:00Z', FM_SNAPSHOT_NOW_EPOCH=1792681200)
    produced = subprocess.run([str(ROOT / 'bin/fm-fleet-snapshot.sh'), '--secondmate-home-summary'],
        env=env(h, FM_SNAPSHOT_NOW='2026-10-22T15:00:00Z', FM_SNAPSHOT_NOW_EPOCH=1792681200),
        capture_output=True, text=True, check=True)
    assert ledger(h) == json.loads(produced.stdout)
    assert (h / 'state/home-summary.json').stat().st_mode & 0o777 == 0o600
    save(h, 'direct-main-ledger')
    log('DIRECT: synchronous ledger exactly equals real producer output; permissions 0600.')

    h = home('burst')
    generations = set()
    stop = threading.Event()
    def sample():
        while not stop.is_set():
            doc = ledger(h)
            if doc:
                generations.add((doc['generated'], doc['generated_epoch']))
            time.sleep(.005)
    sampler = threading.Thread(target=sample)
    sampler.start()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(cli, h, ['--request'], FM_HOME_SUMMARY_INTERVAL=6,
                FM_SNAPSHOT_NOW=f'2026-10-22T15:00:{i:02d}Z', FM_SNAPSHOT_NOW_EPOCH=1792681200+i) for i in range(8)]
            for future in futures:
                future.result()
        wait(lambda: ledger(h) is not None)
        time.sleep(1)
        assert len(generations) == 1, generations
        first = (h / 'state/home-summary.json').read_bytes()
        backlog(h, queued='latest-event')
        cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=6, FM_SNAPSHOT_NOW='2026-10-22T15:02:00Z', FM_SNAPSHOT_NOW_EPOCH=1792681320)
        time.sleep(1)
        assert (h / 'state/home-summary.json').read_bytes() == first
        assert (h / 'state/.home-summary-dirty').exists()
        log(f'BURST: eight distinct requests exposed exactly one generation {sorted(generations)}; in-interval request retained the mark and prior ledger.')
        wait(lambda: any(x['id'] == 'latest-event' for x in ledger(h)['queued']))
        wait(lambda: idle(h))
        save(h, 'coalesced-latest-event')
    finally:
        stop.set()
        sampler.join()

    for future in ('ledger','attempt'):
        h = home(f'future-{future}')
        cli(h)
        path = h / 'state/home-summary.json'
        now = int(time.time())
        os.utime(path, (now + (3600 if future == 'ledger' else 0),) * 2)
        (h / 'state/.home-summary-attempt').write_text(str(now + (3600 if future == 'attempt' else 0)) + '\n')
        original = path.read_bytes()
        cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=30)
        wait(lambda: (h / 'state/.home-summary-drain.lock').exists())
        time.sleep(.5)
        assert path.read_bytes() == original
        assert (h / 'state/.home-summary-dirty').exists()
        cli(h, ['--_request-worker'], FM_HOME_SUMMARY_INTERVAL=30)
        assert path.read_bytes() == original
        assert (h / 'state/.home-summary-dirty').exists()
        log(f'FUTURE {future.upper()}: drain and locked worker both retained valid independent cooldown and pending mark.')
        os.utime(path, (0,0))
        (h / 'state/.home-summary-attempt').write_text('0\n')
        wait(lambda: idle(h))
        log(f'FUTURE {future.upper()}: after both timestamps aged, real publication completed.')

    timeout_run()

def timeout_run():
    h = home('timeouts5', orphans=3000)
    for attempt in range(2):
        if attempt:
            (h / 'state/.home-summary-attempt').write_text('0\n')
        cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=30, FM_HOME_SUMMARY_TIMEOUT=5)
        wait(lambda: (h / 'state/.home-summary-attempt').exists())
        wait(lambda: idle(h))
        failures = (h / 'state/.home-summary-refresh.log').read_text().splitlines()
        assert len(failures) == attempt + 1
        assert 'refresh exceeded its 5-second deadline' in failures[-1]
        recorded = (h / 'state/.home-summary-attempt').read_text()
        stamp = datetime.datetime.strptime(failures[-1][1:21], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
        assert stamp <= int(recorded)
        if not attempt:
            cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=30, FM_HOME_SUMMARY_TIMEOUT=5)
            time.sleep(.5)
            assert (h / 'state/.home-summary-attempt').read_text() == recorded
            assert (h / 'state/.home-summary-dirty').exists()
            log('TIMEOUT RESTART: successor drain retained persisted attempt cooldown, with mark pending and no second attempt.')
    (EVIDENCE / 'real-drain-timeouts.log').write_text('\n'.join(failures) + '\n')
    log('REAL DRAIN FAILURES:\n' + '\n'.join(failures))
    log('TIMEOUTS: two real 3000-record publications were bounded, logged with attempt ordering, and left no partial ledger.')
    assert ledger(h) is None
    # The summary-publication diagnostic is a local phase of the actual bootstrap.
    p = subprocess.run([str(ROOT / 'bin/fm-bootstrap.sh')],
        env=env(h, FM_BOOTSTRAP_DETECT_ONLY=1, FM_BOOTSTRAP_NETWORK='skip', FM_HOME_SUMMARY_FAILURE_REPORT=2),
        capture_output=True, text=True, timeout=30)
    (EVIDENCE / 'real-bootstrap-diagnostic.log').write_text(p.stdout + p.stderr)
    summary_lines = [line for line in p.stdout.splitlines() if line.startswith('HOME_SUMMARY:')]
    log('BOOTSTRAP: ' + '\n'.join(summary_lines))
    assert any('2 failed attempt(s)' in line for line in summary_lines)
    log('LIVE SCENARIOS COMPLETED')

def stop_drains():
    # Stop only the exact disposable drain processes recorded in these homes.
    for lock in BASE.glob('*/state/.home-summary-drain.lock/pid'):
        try:
            os.kill(int(lock.read_text()), signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass

if __name__ == '__main__':
    import sys
    try:
        timeout_run() if '--timeouts' in sys.argv else run()
    finally:
        stop_drains()
