import json
import os
from pathlib import Path
import subprocess

root = Path.cwd()
work = root / '.agent-state/live-validation-r2-keyexec'
lab = work / 'lab'
subprocess.run(['bin/fm-lab-home.sh', 'create', str(lab)], check=True)
for name in ['grok', 'cache', 'config-cli', 'data-cli', 'project', 'pool', 'baseline/bin']:
    (lab / name).mkdir(parents=True, exist_ok=True)
rules = {
    'rules': [],
    'default': [
        {'harness': 'claude', 'model': 'sonnet'},
        {'harness': 'muse', 'model': 'spark'},
        {'harness': 'grok', 'model': 'grok-4.6', 'effort': 'low'},
        {'harness': 'codex', 'model': 'gpt-6-astra'},
    ],
    'label_routes': {'docs-only': {'harness': 'codex', 'model': 'gpt-6-astra'},
                     'ep-opus': {'harness': 'claude', 'model': 'opus'}},
}
(lab / 'config/crew-dispatch.json').write_text(json.dumps(rules))
rows = []
for provider, pct, priority in [('claude', 0, -1), ('meta', 0, -1), ('grok', 0, -1), ('codex', 32, -2)]:
    row = {'provider': provider, 'windows': [], 'quotaSemantics': {
        'status': 'known', 'effectiveAvailability': [{
            'scope': 'all_products' if provider == 'grok' else 'all_models',
            'status': 'known', 'effectivePercentRemaining': pct,
            'runway': {'status': 'through_reset' if pct else 'exhausted_now'},
            'selection': {'status': 'known', 'spendPriority': priority},
        }]}}
    if provider == 'grok':
        row['credits'] = {'remaining': 48082, 'unit': 'credits'}
    rows.append(row)
snapshot = {'schemaVersion': 5, 'generatedAt': '2026-10-19T00:00:00Z', 'providers': rows}
(lab / 'quota.json').write_text(json.dumps(snapshot))
for name in ['fm-dispatch-resolve.sh', 'fm-quota-choose.sh']:
    out = subprocess.check_output(['git', 'show', 'cfb4a4d1:bin/' + name])
    (lab / 'baseline/bin' / name).write_bytes(out)
for path in (root / 'bin').iterdir():
    target = lab / 'baseline/bin' / path.name
    if not target.exists():
        target.symlink_to(path)
print(lab)
