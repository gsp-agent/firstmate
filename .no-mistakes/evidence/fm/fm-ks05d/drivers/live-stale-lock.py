import importlib.util
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('live-summary.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
h = m.home('stale-lock')
p = subprocess.Popen(['bash', str(m.ROOT / '.test-phase/hold-lock.sh'), str(m.ROOT)], env=m.env(h))
try:
    m.wait(lambda: (h / 'state/lock-ready').exists())
    p.kill()
    p.wait()
    m.cli(h, ['--best-effort'], FM_HOME_SUMMARY_IF_IDLE=1)
    assert m.ledger(h) is not None
    m.save(h, 'recovered-stale-lock')
    m.log('STALE LOCK: after killing the real lock-owning process, a direct best-effort publication recovered the lock and published successfully.')
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
