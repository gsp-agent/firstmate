import json
from pathlib import Path
import subprocess


ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M52QK1HG196HGAE7YGSQF6KP')
SAVED = Path('/Users/dalecarman/.no-mistakes/evidence/01M52QK1HG196HGAE7YGSQF6KP')
CURRENT = SAVED / 'test-proof-correction'
TARGET = 'fa7972e060ec00e6563eb981c7471f081ac35f2d'


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


assert Path.cwd() == ROOT
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == TARGET
assert {r['case']: r['exit_code'] for r in records(CURRENT / 'focused-results.jsonl')} == {'deferred': 0, 'reserved': 0}
assert {r['case']: r['status'] for r in records(SAVED / 'focused-results.jsonl')} == {
    'replay-fixture': 0, 'deferred-fixture': 0, 'retry-fixture': 0,
    'fairness-before': 1, 'fairness': 0, 'rows': 0,
}

# These checks consume saved public state contracts, never implementation text.
deferred = records(CURRENT / 'deferred-state.jsonl')
for mode in ('fresh', 'postponed'):
    checkpoints = [r for r in deferred if r['home'] == 'domain-deferred-' + mode]
    before, due, final = checkpoints
    assert before['clock'] == '2098-12-31T23:59:59Z'
    assert before['pending_bodies'].keys() == {'deferred.body'}
    assert before['owner_prompts'] == before['receipts'] == ''
    assert due['clock'] == '2099-01-01T00:00:00Z'
    assert not due['pending_bodies']
    assert len(due['receipts'].splitlines()) == 1
    assert due['receipts'].splitlines()[0].split('\t')[2] == 'ep-firstmate'
    assert len(due['owner_prompts'].splitlines()) == 1
    assert final['receipts'] == due['receipts']
    assert final['owner_prompts'] == due['owner_prompts']
    assert '(hold-kind:' not in final['backlog']
    assert 'Resolution mode: agent-routed' in final['backlog']
    assert 'Captain decision:' not in final['backlog']

reserved, = records(CURRENT / 'reserved-state.jsonl')
assert reserved['owner_prompts'] == reserved['receipts'] == ''
for task in ['reserved-' + str(n) for n in range(1, 9)] + ['captain', 'pm-dale-desk', 'human-desk-pane', 'changed']:
    row, = [line for line in reserved['backlog'].splitlines() if line.startswith('- [ ] ' + task + ' - ')]
    assert '(hold-kind: captain)' in row
assert 'divergent hold and routing reasons' in reserved['outputs']['drift.out']


def scenario(name, evidence, reason):
    return {'name': name, 'result': 'pass', 'live': False,
            'evidence': [str(path) for path in evidence], 'reason': reason}


scenarios = [
    scenario('Expired update-branch and EP-approved capacity holds release to their declared owners once per lifecycle.',
             [SAVED / 'replay-fixture-execution.log', SAVED / 'replay-fixture-state.jsonl'],
             'Reused unchanged target evidence: real hold CLI and installed router, fake transport; matching owner receipts and one prompt per lifecycle.'),
    scenario('Money, credentials, people, client words, production, accounts, taste, mixed asks, and declared human owners remain held.',
             [CURRENT / 'reserved-execution.log', CURRENT / 'reserved-state.jsonl'],
             'Existing reserved fixture rerun with installed router and fake transport; all eleven reserved/human holds remain held with no owner prompt or routing receipt.'),
    scenario('Changing a technical hold into a production question prevents stale routing fields from releasing it.',
             [CURRENT / 'reserved-execution.log', CURRENT / 'reserved-state.jsonl'],
             'Existing fixture observes reason-drift refusal and a held production question; replacing the stale routing metadata retires technical pending work.'),
    scenario('Creating or postponing a deferred hold preserves its pending routing record through a sweep before its date.',
             [CURRENT / 'deferred-execution.log', CURRENT / 'deferred-state.jsonl'],
             'Fresh and postponed cases both pass through public hold and watcher interfaces; supervision stays required, pending bodies survive, and pre-date prompt and receipt counts are zero.'),
    scenario('When a deferral expires, the watcher transfers responsibility once and releases the hold without completing the task.',
             [CURRENT / 'deferred-execution.log', CURRENT / 'deferred-state.jsonl'],
             'Both cases route to ep-firstmate at the date, release into queued state, persist one receipt without captain words, converge on replay, and retire supervision.'),
    scenario('Repeated bounded sweeps reach later and newly added holds despite blocked locks, writes, and unholds, while preserving ordinary checks and cleanup.',
             [SAVED / 'fairness-before-execution.log', SAVED / 'fairness-execution.log', SAVED / 'fairness-state.jsonl', SAVED / 'rows-execution.log', SAVED / 'rows-state.jsonl'],
             'Reused failing-before and passing-target isolated evidence: interrupted repeated sweeps, row insertion/retirement, all three blocking sites, scheduled checks and subprocess cleanup.'),
    scenario('Failed delivery preserves the hold, and an interrupted release recovers from its receipt without prompting twice.',
             [SAVED / 'retry-fixture-execution.log', SAVED / 'retry-fixture-state.jsonl'],
             'Reused unchanged passing isolated target evidence; pending work survives failure and recovery consumes the single existing receipt.'),
]
report = {
    'summary': 'Complete hold-routing proof with isolated fixtures',
    'findings': [],
    'resolved_finding_ids': ['test-2'],
    'tested_head_sha': TARGET,
    'verdict': 'pass',
    'validation_scope': 'Authorized existing isolated fixtures with installed router and fake HOLD_DOMAIN_HERDR transport.',
    'live_harness_delivery': False,
    'baseline': {'selected_findings': 1, 'prior_verdict': 'inconclusive', 'prior_live_scenarios': '3/7'},
    'result': {'selected_findings_remaining': 0, 'authorized_scenarios_passed': '7/7'},
    'testing_summary': 'Deferred and reserved fixtures passed sequentially; unchanged original-hold, scheduling, blocked-row and receipt-recovery results reused at the same target. No product or test edits required.',
    'tested': ['PYTHONDONTWRITEBYTECODE=1 python3 .hold-validation/proof.py deferred',
               'PYTHONDONTWRITEBYTECODE=1 python3 .hold-validation/proof.py reserved'],
    'scenarios': scenarios,
    'limitations': [
        'Isolated transport does not prove delivery to an active live harness; no real Herdr sessions were touched in this correction.',
        'Real endpoint cutover and next-day validation remain Firstmate-owned after landing, outside this worker phase.',
        'Historical default-session read-only tripwire checks via local socket link are documented only from saved evidence; no default panes were driven according to that record.',
        'Accepted base-only approved-merge fixture limitation and existing Firstmate CI hold are preserved; no workflow changes or full-suite/CI-green claim.',
    ],
    'artifacts': [
        {'kind': 'other', 'label': 'Exact fixture selector and observer', 'path': str(CURRENT / 'fixture-driver.py')},
        {'kind': 'other', 'label': 'Scoped proof procedure and historical boundaries', 'path': str(CURRENT / 'test-procedure.txt')},
        {'kind': 'other', 'label': 'Current focused fixture results', 'path': str(CURRENT / 'focused-results.jsonl')},
    ],
}
(CURRENT / 'test-result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'verdict': report['verdict'], 'scope': report['validation_scope'], 'scenarios': '7/7', 'report': str(CURRENT / 'test-result.json')}))
