import json
from pathlib import Path
from datetime import datetime, timedelta, timezone

lab = Path('.agent-state/live-validation-r2-keyexec/lab')
now = datetime.now(timezone.utc)
def stamp(d):
    return d.isoformat().replace('+00:00', 'Z')
rows = []
for p, pct in [('claude', 0), ('muse', 0), ('grok', 0), ('codex', 32)]:
    row = {
        'provider': p, 'label': p.title(), 'source': 'api',
        'state': {'status': 'fresh', 'stale': False, 'sourcesTried': ['disposable-cache'],
                  'refreshedAt': stamp(now)},
        'windows': [{
            'id': 'weekly', 'label': 'week', 'kind': 'weekly',
            'percentRemaining': pct, 'percentUsed': 100-pct,
            'startsAt': stamp(now-timedelta(days=3)),
            'resetsAt': stamp(now+timedelta(days=4)), 'windowSeconds': 604800,
        }],
    }
    if p == 'grok':
        row['credits'] = {'remaining': 48082, 'unit': 'credits'}
        row['windows'][0]['id'] = 'credits'
    if p == 'claude':
        row['windows'][0]['id'] = 'seven_day'
    if p == 'muse':
        row['windows'].append({
            'id': 'five_hour', 'label': 'session', 'kind': 'session',
            'percentUsed': 50, 'percentRemaining': 50,
            'startsAt': stamp(now-timedelta(hours=2)),
            'resetsAt': stamp(now+timedelta(hours=3)), 'windowSeconds': 18000,
        })
    rows.append(row)
(lab / 'cache-input.json').write_text(json.dumps({'schemaVersion': 3, 'providers': rows}))
