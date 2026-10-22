import importlib.util
from pathlib import Path
import os
import signal
import subprocess
import time

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('live-summary.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
worker = None
publisher = None
watcher = None
try:
    h = m.home('busy')
    publisher = subprocess.Popen([str(m.ROOT / 'bin/fm-home-summary-refresh.sh')],
        env=m.env(h, FM_HOME_SUMMARY_TIMEOUT=60), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    m.wait(lambda: bool(list((h / 'state').glob('.home-summary.json.*'))))
    worker = int((h / 'state/.home-summary-refresh.lock/pid').read_text())
    os.kill(worker, signal.SIGSTOP)
    m.backlog(h, queued='after-busy-publication')
    m.cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=1)
    time.sleep(2)
    assert (h / 'state/.home-summary-dirty').exists()
    assert int((h / 'state/.home-summary-refresh.lock/pid').read_text()) == worker
    m.log('BUSY: pending request survived two seconds while a real synchronous writer retained the refresh lock; no competing publisher acquired it.')
    os.kill(worker, signal.SIGCONT)
    worker = None
    assert publisher.wait(timeout=30) == 0
    m.wait(lambda: m.ledger(h) is not None and any(x['id'] == 'after-busy-publication' for x in m.ledger(h)['queued']))
    m.wait(lambda: m.idle(h))
    m.save(h, 'busy-pending-event')

    # Repeat requests near drain exit, then stop triggering and require the last event to appear.
    for i in range(5):
        name = f'handoff-final-{i}'
        m.backlog(h, queued=name)
        m.cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=1)
        m.wait(lambda: any(x['id'] == name for x in m.ledger(h)['queued']))
        # Fire the next event as soon as publication is visible, while lock cleanup may still run.
    m.wait(lambda: m.idle(h))
    m.save(h, 'handoff-final-event')
    m.log('HANDOFF STRESS: five successive events around publication/cleanup all reached the real ledger, including the final event without another trigger. Deterministic exact-boundary coverage remains in the regression script.')

    h = m.home('signaled', orphans=3000)
    m.cli(h, ['--request'], FM_HOME_SUMMARY_INTERVAL=30, FM_HOME_SUMMARY_TIMEOUT=30)
    m.wait(lambda: bool(list((h / 'state').glob('.home-summary.json.*'))))
    pid = int((h / 'state/.home-summary-refresh.lock/pid').read_text())
    os.kill(pid, signal.SIGTERM)
    m.wait(lambda: m.idle(h))
    failure = (h / 'state/.home-summary-refresh.log').read_text()
    assert 'refresh worker failed with exit 143' in failure
    (m.EVIDENCE / 'real-drain-signal.log').write_text(failure)
    m.log('REAL DRAIN SIGNAL: ' + failure.strip())
    m.log('LIVE RACE SCENARIOS COMPLETED')
finally:
    if worker is not None:
        os.kill(worker, signal.SIGCONT)
    if publisher is not None and publisher.poll() is None:
        publisher.terminate()
        publisher.wait(timeout=10)
    m.stop_drains()
