import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('live-summary.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
h = m.BASE / 'burst'
# The existing seeded-home contract requires these two fixture paths.
(h / 'AGENTS.md').write_bytes((m.ROOT / 'AGENTS.md').read_bytes())
(h / 'bin').mkdir(exist_ok=True)
(h / '.fm-secondmate-home').write_text('burst\n')
parent = m.home('reader-parent', False)
(parent / 'data/secondmates.md').write_text(f'- burst - disposable domain (home: {h}; scope: fixture work; projects: firstmate; added 2026-10-22)\n')
e = m.env(parent, FM_SNAPSHOT_REGISTRY_TIMEOUT=15)
e['FM_ROOT_OVERRIDE'] = str(m.ROOT / '.test-phase/runtime-root')
p = subprocess.run([str(m.ROOT / 'bin/fm-fleet-snapshot.sh'), '--json'], env=e,
    capture_output=True, text=True, check=True, timeout=60)
(m.EVIDENCE / 'real-parent-reader.json').write_text(p.stdout)
doc = json.loads(p.stdout)
record = doc['secondmate_current']['records'][0]
assert record['provenance']['summary_source'] == 'local-ledger', record
assert any(item['id'] == 'latest-event' for item in record['queued']), record
m.log('PARENT READER: real fleet snapshot consumed the coalesced local ledger and surfaced latest-event in its queued work; no session or backend fixtures.')
