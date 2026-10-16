#!/usr/bin/env python3
"""Exercise real gh pagination and numeric repository names without forge writes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA')
EV = Path('/Users/dalecarman/.no-mistakes/evidence/01M53A6E4TERYTKTS6MTXY5YEA')
LAB = ROOT / '.queue-validation-tmp/live-pages'
GH = shutil.which('gh')
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k != 'GH_DEBUG'}
ENV['TMPDIR'] = str(ROOT / '.queue-validation-tmp')
ENV['FM_HOME'] = str(LAB)
def run(args, extra=None, timeout=180):
    e = dict(ENV)
    e.update(extra or {})
    p = subprocess.run([str(x) for x in args], env=e, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, (args[:2], p.returncode, p.stdout, p.stderr)
    return p
try:
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    numeric = run([ROOT / 'bin/fm-pr-queue-sweep.sh', '--scan', LAB / 'state'], {'FM_PR_SWEEP_REPOS': 'xcatliu/123\n'})
    (EV / 'live-numeric-repository.txt').write_text(numeric.stdout + '\nSTDERR:\n' + numeric.stderr)
    assert 'queue-empty xcatliu/123\n' in numeric.stdout
    print('PASS: real gh successfully scans the numeric repository xcatliu/123', flush=True)

    probe = LAB / 'probe'
    probe.mkdir()
    log = EV / 'live-page-requests.jsonl'
    log.write_text('')
    wrapper = probe / 'gh'
    wrapper.write_text(f'''#!{sys.executable}
import json, os, sys, time
fields = {{}}
for arg in sys.argv[1:]:
    for key in ['owner', 'repo', 'cursor']:
        if arg.startswith(key + '='):
            fields[key] = arg.split('=', 1)[1]
with open({str(log)!r}, 'a') as output:
    output.write(json.dumps(dict(at=time.time(), fields=fields)) + '\\n')
os.execv({GH!r}, [{GH!r}] + sys.argv[1:])
''')
    wrapper.chmod(0o700)
    start = time.monotonic()
    p = run([ROOT / 'bin/fm-pr-queue-sweep.sh', '--scan', LAB / 'state'], {
        'PATH': str(probe) + os.pathsep + ENV['PATH'],
        'FM_PR_SWEEP_REPOS': 'kunchenguid/firstmate\ngroovejones/groove-sight-platform\n',
        'FM_PR_SWEEP_PAGE_TIMEOUT': '5',
        'FM_PR_SWEEP_BEAT': str(LAB / 'state/.last-watcher-beat'),
    })
    elapsed = time.monotonic() - start
    requests = [json.loads(line) for line in log.read_text().splitlines()]
    pages = [x for x in requests if x['fields'].get('owner') == 'kunchenguid']
    assert len(pages) >= 10, len(pages)
    assert elapsed > 5, elapsed
    assert p.stdout.count('dequeued https://github.com/groovejones/groove-sight-platform/pull/') >= 8, p.stdout
    assert 'queue-empty kunchenguid/firstmate\n' in p.stdout
    assert (LAB / 'state/.last-watcher-beat').stat().st_mtime >= time.time() - 5
    (EV / 'live-multipage-sweep.txt').write_text(f'Per-page timeout: 5 seconds\nElapsed: {elapsed:.3f} seconds\nUpstream pages: {len(pages)}\n\n' + p.stdout + '\nSTDERR:\n' + p.stderr)
    print(f'PASS: {len(pages)} real GitHub pages took {elapsed:.3f}s at a 5s per-page bound, refreshed liveness, and still reported all GSP removals', flush=True)
finally:
    if LAB.exists():
        shutil.rmtree(LAB)
