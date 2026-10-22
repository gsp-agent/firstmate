import json, os, subprocess, time
from pathlib import Path

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5HEFVZ2ZGARFBBBDTE72WAN')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5HEFVZ2ZGARFBBBDTE72WAN')
INPUTS = EVIDENCE / 'lint-inputs-round4'
INPUTS.mkdir(exist_ok=True)
LOG = EVIDENCE / 'lint-product-round4.txt'
RESULTS = []

def say(value):
    with LOG.open('a') as f:
        f.write(value + '\n')
    print(value, flush=True)

def snapshot():
    return subprocess.check_output(['sysctl', 'vm.swapusage'], text=True).strip() + '\n' + subprocess.check_output(['vm_stat'], text=True)

def run(name, args, limits=None, expected=0, deadline=330):
    env = os.environ.copy()
    env.update(TMPDIR=str(EVIDENCE / 'round4-tmp'))
    env.pop('FM_LINT_TELEMETRY', None)
    for key in ['FM_LINT_ROOT_SECONDS', 'FM_LINT_ROOT_MEMORY_KIB', 'FM_LINT_ROOT_GRACE', 'FM_LINT_JOBS']:
        env.pop(key, None)
    env.update(limits or {})
    command = [str(ROOT / 'bin/fm-lint.sh'), '--telemetry', str(EVIDENCE / (name + '.tsv'))] + [str(a) for a in args]
    say('\nSCENARIO ' + name)
    say('environment overrides: ' + json.dumps(limits or {}))
    say('command: ' + ' '.join(command))
    started=time.monotonic()
    process=subprocess.Popen(command, env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output,_=process.communicate(timeout=deadline)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            output,_=process.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            output,_=process.communicate()
        say(output)
        raise RuntimeError(name + ' exceeded external safety cutoff')
    elapsed=round(time.monotonic()-started, 3)
    say(output.rstrip())
    say('exit=' + str(process.returncode) + ' elapsed_seconds=' + str(elapsed))
    sidecar=EVIDENCE / (name + '.roots.tsv')
    if sidecar.exists():
        say('per-root records:\n' + sidecar.read_text().rstrip())
    RESULTS.append(dict(name=name, exit=process.returncode, expected=expected, elapsed_seconds=elapsed, passed=process.returncode==expected))
    (EVIDENCE / 'lint-product-results-round4.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    return process.returncode, output

say('Product validation at ' + time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
small = INPUTS / 'clean.sh'
small.write_text('#!/usr/bin/env bash\nprintf ok\n')
bad = INPUTS / 'finding.sh'
bad.write_text('#!/usr/bin/env bash\nprintf "%s\\n" $1\n')
run('named-clean', [small])
run('named-finding', [bad], expected=1)
heavy=INPUTS / 'heavy.sh'
block=''.join('l0_f%d() {\n  local a=$1 b\n  b=$(printf "%%s" "$a" | tr a-z A-Z) || return 1\n  [ -n "$b" ] && printf "%%s\\n" "$b" || return 3\n}\n' % fn for fn in range(10))
heavy.write_text('#!/usr/bin/env bash\n' + ''.join(block+'l0_f1 x%d\n' % copy for copy in range(32)))
run('real-memory-cap', [heavy], {'FM_LINT_ROOT_MEMORY_KIB':'65536', 'FM_LINT_ROOT_SECONDS':'30', 'FM_LINT_ROOT_GRACE':'1'}, expected=123, deadline=40)
run('real-time-cap', [heavy], {'FM_LINT_ROOT_MEMORY_KIB':'2097152', 'FM_LINT_ROOT_SECONDS':'1', 'FM_LINT_ROOT_GRACE':'1'}, expected=124, deadline=12)
say('\nBEFORE incident roots:\n'+snapshot())
run('incident-roots', ['bin/fm-task-data-lib.sh', 'tests/fm-teardown.test.sh'])
say('AFTER incident roots:\n'+snapshot())
# Minimal source graph: every level imports its child twice.
base=INPUTS/'l0.sh'
base.write_text('#!/usr/bin/env bash\n'+block)
previous=base
for level in range(1,8):
    current=INPUTS/('l%d.sh'%level)
    current.write_text('#!/usr/bin/env bash\n'+''.join('# shellcheck source=%s\n. "%s"\n'%(previous,previous) for _ in range(2))+'l0_f1 sample\n')
    previous=current
run('minimal-source-growth', [previous], {'FM_LINT_ROOT_MEMORY_KIB':'2097152', 'FM_LINT_ROOT_SECONDS':'90', 'FM_LINT_ROOT_GRACE':'1'}, expected=123, deadline=100)
# No fast-mode substitution; use full analysis and cut repeated source edges.
for level in range(1,8):
    current=INPUTS/('l%d.sh'%level)
    current.write_text(current.read_text().replace('# shellcheck source='+str(INPUTS/('l%d.sh'%(level-1))), '# shellcheck source=/dev/null'))
run('minimal-source-boundary-control', [previous], {'FM_LINT_ROOT_MEMORY_KIB':'2097152', 'FM_LINT_ROOT_SECONDS':'90', 'FM_LINT_ROOT_GRACE':'1'}, deadline=100)
say('All manual scenarios finished.')
