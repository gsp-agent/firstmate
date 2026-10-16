#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess

root = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M51TNXPWD65TJT4SFREF5TCF')
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M51TNXPWD65TJT4SFREF5TCF')
home = root / '.nm-hold-test/prefix-diagnostic'
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'GIT_CONFIG_')) or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
        env.pop(key, None)
env.update(FM_HOME=str(home), TMPDIR=str(root / '.nm-hold-test/toolchain-temp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
with (evidence / 'brief-path-diagnostic.txt').open('w') as output:
    result = subprocess.run(['bash', str(root / 'bin/fm-lab-home.sh'), 'create', str(home)], env=env, cwd=root, text=True, capture_output=True, check=True)
    for label, code in [('upstream-lean', root / '.nm-hold-test/baseline-code'), ('target', root)]:
        for name, prefix, expected in [('absolute', '$(touch${IFS}' + str(home / 'marker') + ')', 1),
                                        ('local', '$(touch${IFS}branch-prefix-shell-safe-marker)', 0)]:
            args = ['bash', str(code / 'bin/fm-brief.sh'), label + '-' + name, 'sample', '--mode', 'local-only', '--branch-prefix', prefix]
            result = subprocess.run(args, env=env, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(label, name, 'exit=' + str(result.returncode), file=output)
            print(result.stdout, file=output, flush=True)
            assert result.returncode == expected, result.stdout
print('Both base and target reject the absolute hidden-path prefix and accept the local-marker prefix.')
