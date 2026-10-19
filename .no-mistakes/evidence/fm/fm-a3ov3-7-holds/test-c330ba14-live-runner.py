"""Exercise the real inspection CLI without running any regression lane."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M592GW4AWJHJT4FZVF69FVG7')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M592GW4AWJHJT4FZVF69FVG7')
scratch = ROOT / '.no-mistakes/test-c330ba14'
env = dict(os.environ)
for name in ('BASH_ENV', 'FM_CAPTAIN_HOLD_LANE', 'FM_TEST_HOLD_ROUTING_REGRESSION', 'FM_TEST_HOLD_DOMAIN_ONLY', 'FM_TEST_LIB_SOURCED'):
    env.pop(name, None)
env['TMPDIR'] = str(scratch / 'tmp')
transcript = EVIDENCE / 'test-c330ba14-live-runner.log'
results = {}

with transcript.open('w') as log:
    def run(label, args, expected=0, extra=None):
        log.write('$ ' + shlex.join(args) + '\n')
        if extra:
            log.write('environment: ' + json.dumps(extra, sort_keys=True) + '\n')
        log.flush()
        started = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, env={**env, **(extra or {})}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        log.write(result.stdout)
        log.write(f'exit: {result.returncode}; seconds: {time.monotonic() - started:.3f}\n\n')
        log.flush()
        assert result.returncode == expected, (label, result.returncode, result.stdout)
        results[label] = result.stdout.splitlines()
        return results[label]

    a = run('parallel_1', ['bin/fm-test-run.sh', '--list-scheduled', '--lane', 'portable-parallel-1'])
    b = run('parallel_2', ['bin/fm-test-run.sh', '--list-scheduled', '--lane', 'portable-parallel-2'])
    whole = run('all', ['bin/fm-test-run.sh', '--list', '--all'])
    isolated = run('proven', ['bin/fm-test-run.sh', '--list', '--proven-isolated'])
    family = run('family', ['bin/fm-test-run.sh', '--list', '--family', 'pure-contract-unit'])
    subject = 'tests/fm-captain-hold-lifecycle.test.sh'
    wrapper_a = 'tests/fm-captain-hold-lifecycle-lane-a.test.sh'
    wrapper_b = 'tests/fm-captain-hold-lifecycle-lane-b.test.sh'
    assert a.count(wrapper_a) == 1 and wrapper_b not in a and subject not in a
    assert b.count(wrapper_b) == 1 and wrapper_a not in b and subject not in b
    assert not set(a).intersection(b)
    assert set(a + b) == set(isolated)
    for collection in (whole, isolated, family):
        assert collection.count(wrapper_a) == 1 and collection.count(wrapper_b) == 1
        assert subject not in collection
        assert len(collection) == len(set(collection))
    assert 'tests/fm-pi-primary-types.test.sh' in a
    assert 'tests/fm-pi-primary-types.test.sh' not in b
    log.write('Observed: each captain-hold wrapper is selected once, on a different shard; the unsplit subject is excluded; family and proven-isolated lists agree; Pi stays in shard 1.\n\n')
    log.flush()
    invalid = run('invalid_subject_lane', ['bash', 'tests/fm-captain-hold-lifecycle.test.sh'], expected=1,
                  extra={'FM_CAPTAIN_HOLD_LANE': 'invalid',
                         'FM_TEST_HOLD_ROUTING_REGRESSION': 'origins', 'FM_TEST_HOLD_DOMAIN_ONLY': '1',
                         'FM_HOME': str(scratch / 'home'),
                         'FM_STATE_OVERRIDE': str(scratch / 'home/state'),
                         'FM_DATA_OVERRIDE': str(scratch / 'home/data'),
                         'FM_CONFIG_OVERRIDE': str(scratch / 'home/config')})
    assert any('FM_CAPTAIN_HOLD_LANE must be a, b or all' in line for line in invalid)
    assert not any(line.startswith('ok - ') for line in invalid)
    log.write('Observed: an invalid lane is refused before the origins/domain-only selectors can run any hold case.\n')

print(json.dumps({'transcript': str(transcript), 'result': 'pass',
                  'parallel_1_captain_wrapper': wrapper_a, 'parallel_2_captain_wrapper': wrapper_b}, sort_keys=True))
