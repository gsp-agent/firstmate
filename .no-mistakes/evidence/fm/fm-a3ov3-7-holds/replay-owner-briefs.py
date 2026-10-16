#!/usr/bin/env python3
"""Run the real brief generator in one disposable marked home."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M51TNXPWD65TJT4SFREF5TCF')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M51TNXPWD65TJT4SFREF5TCF')
lab = ROOT / '.nm-hold-test/briefs'
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'GIT_CONFIG_')) or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
        env.pop(key, None)
env.update(FM_HOME=str(lab), TMPDIR=str(ROOT / '.nm-hold-test/toolchain-temp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
with (EVIDENCE / 'owner-brief-replay.txt').open('w') as output:
    def run(args, expected=0):
        print('$ bash ' + ' '.join(args), file=output, flush=True)
        result = subprocess.run(['bash', *args], cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        print(result.stdout, file=output, flush=True)
        print('[exit %d]' % result.returncode, file=output, flush=True)
        assert result.returncode == expected, result.stdout
        return result.stdout
    run(['bin/fm-lab-home.sh', 'create', str(lab)])
    cases = [('declared', ['--mode', 'local-only', '--decision-owner', 'ep-firstmate'], 'ep-firstmate'),
             ('default', ['--mode', 'local-only'], 'captain'),
             ('scout', ['--scout', '--decision-owner', 'ep-sample'], 'ep-sample')]
    for id, flags, owner in cases:
        run(['bin/fm-brief.sh', id, 'sample', *flags])
        brief = (lab / 'data' / id / 'brief.md').read_text()
        print('GENERATED PUBLIC BRIEF (%s):\n%s\n' % (id, brief), file=output, flush=True)
        fields = [line.removeprefix('Decision owner: ') for line in brief.splitlines() if line.startswith('Decision owner: ')]
        assert fields == [owner]
    run(['bin/fm-brief.sh', 'invalid', 'sample', '--mode', 'local-only', '--decision-owner', 'two owners'], expected=1)
    assert not (lab / 'data/invalid/brief.md').exists()
print(json.dumps({'result': 'pass', 'declared_owner': 'ep-firstmate', 'default_owner': 'captain', 'scout_owner': 'ep-sample', 'invalid_endpoint': 'refused before output'}))
