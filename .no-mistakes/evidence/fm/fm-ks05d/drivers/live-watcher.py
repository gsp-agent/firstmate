import importlib.util
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('live-summary.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
h = m.home('watcher')
m.cli(h)
m.backlog(h, queued='watcher-event')
(h / 'tmux').mkdir()
e = m.env(h, FM_POLL=1, FM_HOME_SUMMARY_INTERVAL=2, FM_SIGNAL_GRACE=0,
          FM_CHECK_INTERVAL=9999999, FM_HEARTBEAT=9999999, TMUX_TMPDIR=h / 'tmux')
e.pop('FM_ROOT_OVERRIDE')
with (m.EVIDENCE / 'real-watcher.log').open('w') as output:
    watcher = subprocess.Popen([str(m.ROOT / 'bin/fm-watch.sh')], env=e, stdout=output, stderr=output)
    try:
        m.wait(lambda: (h / 'state/.last-watcher-beat').exists())
        m.wait(lambda: any(item['id'] == 'watcher-event' for item in m.ledger(h)['queued']), limit=30)
        m.save(h, 'watcher-coalesced-event')
        m.log('WATCHER: real monitoring loop automatically published a backlog-only change through the request drain; private unused tmux directory selected, no fleet session touched.')
    finally:
        watcher.terminate()
        watcher.wait(timeout=10)
        m.stop_drains()
