"""Render-only evidence: shipped board template with real CLI projection data.
No Lavish session is opened or armed, and no shared fleet service is touched.
"""
import json
from pathlib import Path
root = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5CGASNXHDRR59BT65X36T6X')
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5CGASNXHDRR59BT65X36T6X')
template = (root / '.agents/skills/bearings/assets/board-template.html').read_text()
for state in ('before', 'after'):
    model = json.loads((evidence / ('bearings-' + state + '.json')).read_text())
    payload = dict(schema='fm-bearings-board.v1', home='disposable archived-blocker validation',
                   generated=model['generated'], prs_live=False, captains_call=[], underway=[], landed=[], charted=[])
    for row in model['decisions_open']:
        payload['captains_call'].append(dict(key=row['key'], type='decision', repo='disposable-project',
            title='Approval after shipment', about=row['summary'], decide='Approve the completed shipment',
            options=[dict(value='approve', label='Approve'), dict(value='defer', label='Defer')]))
    for row in model['gates']:
        blockers = row.get('blocked_by')
        reason = ('blocked-by ' + blockers) if blockers and blockers != '-' else None
        if row.get('reason') not in (None, '-', ''):
            reason = row['reason']
        payload['charted'].append(dict(id=row['id'], repo='disposable-project', title=row['title'],
                                       reason=reason, dispatchable=not reason, filed=row.get('filed')))
    (evidence / ('board-' + state + '-payload.json')).write_text(json.dumps(payload, indent=2) + '\n')
    encoded = json.dumps(payload, separators=(',', ':')).replace('<', '\\u003c')
    page = template.replace('__FM_BEARINGS_BOARD_DATA__', encoded)
    (evidence / ('board-' + state + '.html')).write_text(page)
print('Prepared before/after pages using the unchanged shipped board template and actual bearings output.')
