#!/usr/bin/env python3
"""Execute the existing squash regression function against both real CLIs."""
from pathlib import Path
import os
import shlex
import subprocess

root = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5BVRCV3QQMRTF34PSAMRW21')
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5BVRCV3QQMRTF34PSAMRW21')
scratch = root / '.agent-state/drift-squash-regression'
(scratch / 'tmp').mkdir(parents=True, exist_ok=True)
# Preserve the test's function bodies and assertions; select the existing case
# rather than rerunning unrelated cases before the regression can be reached.
source = (root / 'tests/fm-drift-nightly.test.sh').read_text()
definitions, _, _ = source.partition('\ntest_unproven_file_is_path_drift_and_exits_1\n')
definitions = definitions.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$FM_DRIFT_ROOT/tests/lib.sh"')
harness = scratch / 'squash-regression.sh'
harness.write_text(definitions + '\nSCRIPT=$FM_DRIFT_REGRESSION_SCRIPT\ntest_squash_merged_branch_carries_its_own_manifest_line\n')
env = dict(os.environ, FM_DRIFT_ROOT=str(root), TMPDIR=str(scratch / 'tmp'),
           PYTHONDONTWRITEBYTECODE='1')
with (evidence / 'squash-regression-before-after.log').open('w') as log:
    for label, script, expected in [
        ('previous', root / '.agent-state/drift-live-validation-v2/previous-fm-drift-nightly.sh', 1),
        ('candidate', root / 'bin/fm-drift-nightly.sh', 0),
    ]:
        env['FM_DRIFT_REGRESSION_SCRIPT'] = str(script)
        args = ['bash', str(harness)]
        proc = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=90)
        text = proc.stdout + proc.stderr
        log.write(f'{label}: FM_DRIFT_REGRESSION_SCRIPT={shlex.quote(str(script))} {shlex.join(args)}\n')
        log.write(text + f'exit: {proc.returncode}\n\n')
        log.flush()
        assert proc.returncode == expected, (label, proc.returncode, text)
        if label == 'previous':
            assert 'a squash carrying its own manifest line exits 0' in text and 'proof line is not a full sha: pr: 7' in text
        else:
            assert 'ok - a squash-merged branch carries its own manifest line and later edits fail' in text
        print(f'{label}: existing squash regression exit {proc.returncode} (expected {expected})', flush=True)
