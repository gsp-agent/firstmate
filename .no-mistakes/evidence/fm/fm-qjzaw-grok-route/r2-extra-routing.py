import copy
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile

root = Path.cwd()
lab = root / '.agent-state/live-validation-r2/lab'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M59T4BFDPQD71P8CHEHTBVJJ')
home = lab / 'more-routing'
(home / 'config').mkdir(parents=True)
base = json.loads((lab / 'cache-input.json').read_text())
rules = json.loads((lab / 'config/crew-dispatch.json').read_text())
env = dict(os.environ, FM_HOME=str(home), QUOTA_AXI_SNAPSHOT=str(home / 'cache.json'),
           XDG_CONFIG_HOME=str(lab / 'config-cli'), XDG_CACHE_HOME=str(lab / 'cache'),
           TMPDIR=str(lab / 'cache'))
for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE',
            'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']:
    env.pop(key, None)
lines = []
results = []

def call(args):
    p = subprocess.run(args, env=env, text=True, capture_output=True, timeout=80)
    lines.append('$ ' + shlex.join(args) + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n')
    return p

def write_case(cache, profiles=None):
    (home / 'cache.json').write_text(json.dumps(cache))
    (home / 'config/crew-dispatch.json').write_text(json.dumps(profiles or rules))

def case(name, cache, expected, profiles=None):
    lines.append('\nCASE: ' + name)
    write_case(cache, profiles)
    producer = call(['quota-axi', '--json', '--no-credential-refresh'])
    producer.check_returncode()
    p = call(['bash', 'bin/fm-dispatch-resolve.sh', '--labels', ''])
    passed = p.returncode == 0 and ("profile: --harness '" + expected + "'") in p.stdout
    results.append({'name': name, 'pass': passed, 'expected': expected, 'output': p.stdout})
    print(name + ': ' + ('PASS' if passed else 'FAIL'), flush=True)

healthy_muse = copy.deepcopy(base)
for row in healthy_muse['providers']:
    if row['provider'] == 'muse':
        for window in row['windows']:
            window.update(percentRemaining=45, percentUsed=55)
case('healthy-muse-precedes-grok', healthy_muse, 'muse')

missing = copy.deepcopy(base)
missing['providers'] = [p for p in missing['providers'] if p['provider'] != 'claude']
case('missing-claude-quota-remains-eligible', missing, 'claude')

no_credits = copy.deepcopy(base)
for row in no_credits['providers']:
    if row['provider'] == 'grok':
        row.pop('credits', None)
case('missing-prepaid-evidence-does-not-bypass-exhaustion', no_credits, 'codex')

other_credits = copy.deepcopy(no_credits)
for row in other_credits['providers']:
    if row['provider'] == 'claude':
        row['credits'] = {'remaining': 48082, 'unit': 'credits'}
case('non-grok-credits-do-not-bypass-exhaustion', other_credits, 'codex')

object_rules = copy.deepcopy(rules)
object_rules['default'] = {'harness': 'grok', 'model': 'grok-4.7'}
case('single-profile-default-honors-prepaid', base, 'grok', object_rules)

# Reproduce through the exact executable code shipped before each fix.
write_case(base)
lines.append('\nCASE: original-default-walk-and-previous-Muse-regression')
observed = {}
for ref, label in [('cfb4a4d1', 'original'), ('dbd12060', 'previous-test-target')]:
    checkout = lab / ('baseline-exact-' + label)
    checkout.mkdir()
    data = subprocess.check_output(['git', 'archive', ref, 'bin'])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(checkout, filter='data')
    p = call(['bash', str(checkout / 'bin/fm-dispatch-resolve.sh'), '--labels', ''])
    observed[label] = p.stdout
current = call(['bash', 'bin/fm-dispatch-resolve.sh', '--labels', ''])
passed = ("profile: --harness 'claude'" in observed['original'] and
          "profile: --harness 'muse'" in observed['previous-test-target'] and
          "profile: --harness 'grok'" in current.stdout)
results.append({'name': 'executable-before-after-routing', 'pass': passed,
                'before': observed, 'after': current.stdout})
print('executable-before-after-routing: ' + ('PASS' if passed else 'FAIL'), flush=True)

for schema in [5, 6]:
    cache = copy.deepcopy(base)
    if schema == 6:
        codex = next(p for p in cache['providers'] if p['provider'] == 'codex')
        codex['accountKey'] = 'codex-home'
        other = copy.deepcopy(codex)
        other['accountKey'] = 'other'
        cache['providers'].insert(0, other)
    write_case(cache)
    lines.append(f'\nCASE: schema-{schema}-native-TOON-to-JSON-prepaid-fallback')
    toon = call(['quota-axi', '--no-credential-refresh'])
    toon.check_returncode()
    raw_json = call(['quota-axi', '--json', '--no-credential-refresh'])
    raw_json.check_returncode()
    actual_schema = json.loads(raw_json.stdout)['schemaVersion']
    assert actual_schema == schema, (schema, actual_schema)
    toon_file = home / f'quota-{schema}.toon'
    json_file = home / f'quota-{schema}.json'
    toon_file.write_text(toon.stdout)
    json_file.write_text(raw_json.stdout)
    args = ['--candidate', 'claude:sonnet', '--candidate', 'muse:spark',
            '--candidate', 'grok:grok-4.7', '--candidate', 'codex:gpt-6-astra']
    a = call(['bash', 'bin/fm-quota-choose.sh', '--snapshot', str(toon_file), *args])
    b = call(['bash', 'bin/fm-quota-choose.sh', '--snapshot', str(json_file), *args])
    passed = a.returncode == 2 and 'prepaid credit evidence' in a.stderr and b.stdout.strip() == 'grok grok-4.7'
    results.append({'name': f'schema-{schema}-native-TOON-to-JSON-prepaid-fallback', 'pass': passed,
                    'toon_exit': a.returncode, 'json_output': b.stdout})
    print(f'schema-{schema}-native-TOON-to-JSON-prepaid-fallback: ' + ('PASS' if passed else 'FAIL'), flush=True)

(evidence / 'r2-extra-routing-transcript.txt').write_text('\n'.join(lines))
(evidence / 'r2-extra-routing-results.json').write_text(json.dumps(results, indent=2) + '\n')
if not all(r['pass'] for r in results):
    raise SystemExit(1)
