import copy
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path.cwd()
lab = root / '.agent-state/live-validation/lab'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M59T4BFDPQD71P8CHEHTBVJJ')
base_cache = json.loads((lab / 'cache-input.json').read_text())
base_rules = json.loads((lab / 'config/crew-dispatch.json').read_text())
env = dict(os.environ, FM_HOME=str(lab), QUOTA_AXI_SNAPSHOT=str(lab / 'cache-input.json'),
           XDG_CONFIG_HOME=str(lab / 'config-cli'), XDG_CACHE_HOME=str(lab / 'cache'),
           TMPDIR=str(lab / 'cache'))
for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE',
            'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']:
    env.pop(key, None)
records = []
transcript = []

def call(args, extra=None):
    run_env = env.copy()
    run_env.update(extra or {})
    p = subprocess.run(args, env=run_env, text=True, capture_output=True, timeout=60)
    transcript.append('$ ' + shlex.join(args) + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n')
    return p

def mutate(cache, provider, pct=None, balance=None):
    for row in cache['providers']:
        if row['provider'] == provider:
            if pct is not None:
                for w in row['windows']:
                    w.update(percentRemaining=pct, percentUsed=100-pct)
            if balance is not None:
                row['credits'] = balance

def case(name, expected, cache=None, rules=None, labels='', baseline=False, extra=None):
    cache = copy.deepcopy(cache or base_cache)
    rules = copy.deepcopy(rules or base_rules)
    (lab / 'cache-input.json').write_text(json.dumps(cache))
    (lab / 'config/crew-dispatch.json').write_text(json.dumps(rules))
    transcript.append('\nCASE: ' + name + '\n')
    producer = call(['quota-axi', '--json', '--no-credential-refresh'], extra)
    if producer.returncode == 0:
        data = json.loads(producer.stdout)
        (evidence / ('quota-' + name + '.json')).write_text(json.dumps(data, indent=2) + '\n')
        transcript[-1] = '$ quota-axi --json --no-credential-refresh\n' + json.dumps({
            'schemaVersion': data.get('schemaVersion'),
            'providers': [{k: p[k] for k in ['provider', 'accountKey', 'credits', 'quotaSemantics'] if k in p}
                          for p in data.get('providers', []) if p['provider'] in ['claude', 'muse', 'grok', 'codex']]
        }, indent=2) + '\n'
    if baseline:
        call(['bash', str(lab / 'baseline/bin/fm-dispatch-resolve.sh'), '--labels', labels], extra)
    p = call(['bash', 'bin/fm-dispatch-resolve.sh', '--labels', labels], extra)
    if expected in ['escalate', 'refused']:
        passed = 'status: ' + expected in p.stdout and 'profile:' not in p.stdout
    else:
        passed = p.returncode == 0 and "profile: --harness '" + expected + "'" in p.stdout
    records.append({'name': name, 'expected': expected, 'pass': passed,
                    'exit': p.returncode, 'output': p.stdout, 'stderr': p.stderr})
    print(name + ': ' + ('PASS' if passed else 'FAIL'), flush=True)

case('full-chain-exhausted-claude-and-muse', 'grok', baseline=True)
fixed_rules = copy.deepcopy(base_rules)
fixed_rules['default'][1]['provider'] = 'muse'
case('explicit-muse-provider-counterfactual', 'grok', rules=fixed_rules)
short_rules = copy.deepcopy(base_rules)
short_rules['default'] = [p for p in short_rules['default'] if p['harness'] != 'muse']
case('grok-weekly-zero-prepaid-positive', 'grok', rules=short_rules)
for label, balance, expected in [('zero', {'remaining': 0, 'unit': 'credits'}, 'codex'),
                                 ('unlimited', {'remaining': 0, 'unlimited': True, 'unit': 'credits'}, 'grok')]:
    cache = copy.deepcopy(base_cache)
    mutate(cache, 'grok', balance=balance)
    case('grok-prepaid-' + label, expected, cache=cache, rules=short_rules)
healthy = copy.deepcopy(base_cache)
mutate(healthy, 'claude', pct=35)
case('first-healthy-rung-retained', 'claude', cache=healthy)
exhausted = copy.deepcopy(base_cache)
mutate(exhausted, 'grok', balance={'remaining': 0, 'unit': 'credits'})
mutate(exhausted, 'codex', pct=0)
case('all-exhausted-escalates', 'escalate', cache=exhausted, rules=fixed_rules)
case('explicit-label-wins', 'codex', labels='docs-only')
case('conflicting-labels-refused', 'refused', labels='docs-only,ep-opus')
case('unreadable-quota-retains-first-rung', 'claude', extra={'QUOTA_AXI_SNAPSHOT': str(lab / 'does-not-exist')})

for state in ['blocked', 'usable']:
    for reverse in [False, True]:
        cache = copy.deepcopy(base_cache)
        codex = next(p for p in cache['providers'] if p['provider'] == 'codex')
        other = copy.deepcopy(codex)
        other['accountKey'] = 'other'
        codex['accountKey'] = 'codex-home'
        for w in codex['windows']:
            w.update(percentRemaining=0 if state == 'blocked' else 70,
                     percentUsed=100 if state == 'blocked' else 30)
        for w in other['windows']:
            w.update(percentRemaining=70 if state == 'blocked' else 0,
                     percentUsed=30 if state == 'blocked' else 100)
        cache['providers'].insert(0, other)
        if reverse:
            cache['providers'].reverse()
        rules = copy.deepcopy(short_rules)
        rules['default'] = [{'harness': 'codex', 'model': 'gpt-6-astra'},
                            {'harness': 'grok', 'model': 'grok-4.7'}]
        case('codex-account-' + state + ('-reversed' if reverse else ''),
             'grok' if state == 'blocked' else 'codex', cache=cache, rules=rules)

# The worker helper's supported default-TOON -> JSON ambiguity fallback.
(lab / 'cache-input.json').write_text(json.dumps(base_cache))
(lab / 'config/crew-dispatch.json').write_text(json.dumps(fixed_rules))
call(['quota-axi', '--no-credential-refresh'])
toon = transcript[-1].split('\n', 1)[1].rsplit('[exit ', 1)[0]
(lab / 'quota.toon').write_text(toon)
json_run = call(['quota-axi', '--json', '--no-credential-refresh'])
(lab / 'producer.json').write_text(json_run.stdout)
args = ['--candidate', 'claude:sonnet', '--candidate', 'grok:grok-4.7', '--candidate', 'codex:gpt-6-astra']
transcript.append('\nCASE: helper-default-TOON-fallback\n')
a = call(['bash', 'bin/fm-quota-choose.sh', '--snapshot', str(lab / 'quota.toon'), *args])
b = call(['bash', 'bin/fm-quota-choose.sh', '--snapshot', str(lab / 'producer.json'), *args])
old = call(['bash', str(lab / 'baseline/bin/fm-quota-choose.sh'), '--snapshot', str(lab / 'producer.json'), *args])
records.append({'name': 'helper-default-TOON-fallback',
                'pass': a.returncode == 2 and 'prepaid credit evidence' in a.stderr and b.stdout.strip() == 'grok grok-4.7',
                'toon_exit': a.returncode, 'json_output': b.stdout, 'baseline_output': old.stdout})
(evidence / 'routing-live-transcript.txt').write_text('\n'.join(transcript))
(evidence / 'routing-live-results.json').write_text(json.dumps(records, indent=2) + '\n')
print('saved routing-live-transcript.txt and routing-live-results.json', flush=True)
