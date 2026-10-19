from pathlib import Path
import json
import os
import subprocess
import time

root = Path.cwd()
scratch = root / '.nm-live-yeldv'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH')
fixture = json.loads((evidence / 'fixture.json').read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_'))}
env.update(json.loads((evidence / 'isolated-env.json').read_text()))

def git(*args):
    return subprocess.check_output(['git', *map(str, args)], env=env, text=True).strip()

remote = scratch / 'review-origin.git'
slot = scratch / 'review-slot'
git('clone', '-q', '--bare', fixture['remote'], remote)
git('-C', remote, 'config', 'uploadpack.allowFilter', 'true')
git('clone', '-q', '--filter=blob:none', remote.as_uri(), slot)
git('-C', slot, 'switch', '-qc', 'fm/lab-review')
(slot / 'review-local.txt').write_text('local review change\n')
git('-C', slot, 'add', 'review-local.txt')
git('-C', slot, '-c', 'user.name=gsp-agent', '-c', 'user.email=gsp-agent@users.noreply.github.com', 'commit', '-qm', 'review local fixture')
local = git('-C', slot, 'rev-parse', 'HEAD')
meta = Path(env['FM_HOME']) / 'state/lab-review.meta'
base_meta = f'worktree={slot}\nproject={slot}\nkind=ship\nbranch=fm/lab-review\nmode=direct-PR\npr=123\n'
rows = []
for label, recorded in [('missing-recorded-head', 'e' * 40), ('available-recorded-head', local), ('fresh-pull-ref', local)]:
    if label == 'fresh-pull-ref':
        git('-C', remote, 'fetch', '-q', Path(fixture['seed']).as_uri(), fixture['head'] + ':refs/pull/123/head')
    meta.write_text(base_meta + 'pr_head=' + recorded + '\n')
    trace = evidence / ('review-' + label + '-trace.jsonl')
    start = time.monotonic()
    p = subprocess.run(['bash', 'bin/fm-review-diff.sh', 'lab-review'], cwd=root, env=env | {'GIT_TRACE2_EVENT': str(trace)}, text=True, capture_output=True, timeout=45)
    calls = [v['argv'] for v in map(json.loads, trace.read_text().splitlines()) if v.get('event') == 'start']
    implicit = [argv for argv in calls if 'fetch' in argv and '--stdin' in argv]
    row = {'scenario': label, 'exit': p.returncode, 'elapsed_seconds': round(time.monotonic() - start, 4), 'implicit_lazy_fetches': implicit, 'stdout': p.stdout, 'stderr': p.stderr}
    if label == 'missing-recorded-head':
        row['expected_surface'] = p.returncode == 0 and 'PR head unavailable' in p.stderr and '+local review change' in p.stdout and not implicit
    elif label == 'available-recorded-head':
        row['expected_surface'] = p.returncode == 0 and 'PR head unavailable' not in p.stderr and '+local review change' in p.stdout and not implicit
    else:
        row['expected_surface'] = p.returncode == 0 and '+pipeline fix not pushed to origin' in p.stdout and '+local review change' not in p.stdout
        row['note'] = 'The diff may fetch omitted blobs in a partial clone; the missing-commit probes are the no-fetch boundary.'
    rows.append(row)
    (evidence / ('review-' + label + '.txt')).write_text('$ bin/fm-review-diff.sh lab-review\n' + p.stdout + p.stderr)
    print(json.dumps(row), flush=True)
(evidence / 'review-proof.json').write_text(json.dumps(rows, indent=2))
