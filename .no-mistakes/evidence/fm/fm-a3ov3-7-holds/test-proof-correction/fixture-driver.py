import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M52QK1HG196HGAE7YGSQF6KP')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M52QK1HG196HGAE7YGSQF6KP/test-proof-correction')
ROUTER = '/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py'


def snapshot(kind, home, **details):
    home = Path(home)
    record = {'kind': kind, 'home': home.name, **details}
    record['backlog'] = (home / 'data/backlog.md').read_text()
    record['owner_prompts'] = (home / 'owner.log').read_text() if (home / 'owner.log').exists() else ''
    state = home / 'state/hold-domain'
    record['receipts'] = (state / 'routed.tsv').read_text() if (state / 'routed.tsv').exists() else ''
    record['pending_bodies'] = {p.name: p.read_text() for p in sorted((state / 'pending').glob('*.body'))}
    record['outputs'] = {p.name: p.read_text() for p in home.glob('*.out')}
    with (EVIDENCE / (os.environ['PROOF_CASE'] + '-state.jsonl')).open('a') as stream:
        stream.write(json.dumps(record) + '\n')


if len(sys.argv) > 1 and sys.argv[1] == 'snapshot':
    snapshot(sys.argv[2], sys.argv[3], clock=sys.argv[4], exit_code=int(sys.argv[5]))
    sys.exit(0)

assert Path.cwd() == ROOT
case = sys.argv[1]
functions = {
    'deferred': 'test_domain_deferred_holds_keep_their_routing_wake',
    'reserved': 'test_domain_keeps_reserved_human_and_answered_holds',
}
assert case in functions
EVIDENCE.mkdir(exist_ok=True)
temporary = ROOT / '.hold-validation'
(temporary / 'tmp').mkdir(exist_ok=True)

# Select existing executable behavioral fixtures; no test assertions are added.
source = (ROOT / 'tests/fm-captain-hold-lifecycle.test.sh').read_text()
source = source.split('case "${FM_TEST_HOLD_ROUTING_REGRESSION:-}" in\n', 1)[0]
source = source.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$PROOF_ROOT/tests/lib.sh"', 1)
source = source.replace('run_domain_watcher() {', 'recorded_run_domain_watcher() {', 1)
source += '''
run_domain_watcher() {
  recorded_run_domain_watcher "$@"
  local rc=$?
  python3 "$PROOF_ROOT/.hold-validation/proof.py" snapshot watcher "$1" "$2" "$rc"
  return "$rc"
}
'''
source += functions[case] + '\nrc=$?\n'
source += '''
for home in "$TMP_ROOT"/*; do
  [ -f "$home/data/backlog.md" ] || continue
  python3 "$PROOF_ROOT/.hold-validation/proof.py" snapshot final "$home" final "$rc"
done
exit "$rc"
'''
driver = temporary / (case + '.sh')
driver.write_text(source)
env = {
    **os.environ,
    'PROOF_CASE': case,
    'PROOF_ROOT': str(ROOT),
    'TMPDIR': str(temporary / 'tmp'),
    'PYTHONDONTWRITEBYTECODE': '1',
    'FM_TEST_SKIP_ORPHAN_REAP': '1',
    'FM_TEST_HOLD_DOMAIN_ROUTER': ROUTER,
}
start = time.monotonic()
with (EVIDENCE / (case + '-execution.log')).open('w') as stream:
    stream.write('Existing fixture: ' + functions[case] + '\n')
    stream.write('Installed router: ' + ROUTER + '\n')
    stream.write('Transport: existing fake HOLD_DOMAIN_HERDR; no real sessions\n')
    stream.flush()
    result = subprocess.run(['bash', str(driver)], env=env, stdout=stream, stderr=subprocess.STDOUT)
receipt = {
    'case': case,
    'function': functions[case],
    'exit_code': result.returncode,
    'seconds': round(time.monotonic() - start, 2),
    'live_harness_delivery': False,
    'installed_router': ROUTER,
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
}
with (EVIDENCE / 'focused-results.jsonl').open('a') as stream:
    stream.write(json.dumps(receipt) + '\n')
print(json.dumps(receipt), flush=True)
print((EVIDENCE / (case + '-execution.log')).read_text(), flush=True)
sys.exit(result.returncode)
