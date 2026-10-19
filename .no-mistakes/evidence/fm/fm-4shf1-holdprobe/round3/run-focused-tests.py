import json
import os
from pathlib import Path
import subprocess
import time

root = Path.cwd()
out = Path(__file__).parent
scratch = root / '.test-phase'
tmp = scratch / 'tmp'
tmp.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_'):
        env.pop(key)
env.update(TMPDIR=str(tmp), PYTHONDONTWRITEBYTECODE='1', FM_BACKLOG_ROW_TIMEOUT_SECS='60')
checks = [
    ('dale-step', ['bash', 'tests/fm-captain-hold-lifecycle.test.sh', '--dale-step-only'], {}),
    ('sweep-probes', ['bash', 'tests/fm-watch-triage.test.sh'], {'FM_TEST_ONLY': 'test_check_sweep_reprobes_captain_holds'}),
    ('sweep-finalization', ['bash', 'tests/fm-watch-triage.test.sh'], {'FM_TEST_ONLY': 'test_check_sweep_surfaces_interrupted_probe_releases'}),
    ('idle-autoarm', ['bash', 'tests/fm-claude-stop-autoarm.test.sh'], {'FM_TEST_ONLY': 'test_arms_for_captain_probe_hold_without_inflight'}),
    ('plist-semantics', ['bash', 'tests/fm-drift-nightly.test.sh'], {'FM_TEST_ONLY': 'test_install_and_uninstall_round_trip'}),
]
results = []
for name, argv, extra in checks:
    start = time.monotonic()
    with (out / f'targeted-retry-{name}.log').open('w') as log:
        log.write('$ ' + ' '.join(f'{k}={v}' for k, v in extra.items()) + ' ' + ' '.join(argv) + '\n')
        log.flush()
        try:
            p = subprocess.run(argv, cwd=root, env=dict(env, **extra), stdout=log, stderr=subprocess.STDOUT, timeout=900, start_new_session=True)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = 124
            log.write('\nTargeted driver deadline exceeded (900 seconds).\n')
    result = dict(name=name, command=argv, env=extra, status=rc, seconds=round(time.monotonic()-start, 2))
    results.append(result)
    print(json.dumps(result), flush=True)
(out / 'targeted-results.json').write_text(json.dumps(results, indent=2) + '\n')
