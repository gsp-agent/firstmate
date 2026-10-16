#!/usr/bin/env python3
"""Additional live recovery and retirement checks; real gh, isolated homes."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA')
EV = Path('/Users/dalecarman/.no-mistakes/evidence/01M53A6E4TERYTKTS6MTXY5YEA')
SCRATCH = ROOT / '.queue-validation-tmp/live-guards'
SCRATCH.mkdir(parents=True, exist_ok=True)
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k not in ('GH_DEBUG', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(SCRATCH), FM_CHECK_INTERVAL='0', FM_POLL='0.05', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
RESULTS = []

def cmd(d, args, label=None, ok=True, timeout=100):
    e = dict(ENV, FM_HOME=str(d))
    p = subprocess.run([str(x) for x in args], env=e, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if label:
        (EV / (label + '.txt')).write_text(p.stdout + '\nSTDERR:\n' + p.stderr)
    if ok:
        assert not p.returncode, (args[:2], p.returncode, p.stdout, p.stderr)
    return p

def script(d, name, text):
    p = d / 'state' / (name + '.check.sh')
    p.write_text('#!/usr/bin/env bash\nset -eu\n' + text + '\n')
    p.chmod(0o700)
    cmd(d, [ROOT / 'bin/fm-check-register.sh', name])

def setup(name, number=4200, repo='groovejones/groove-sight-platform'):
    d = SCRATCH / name
    cmd(d, [ROOT / 'bin/fm-lab-home.sh', 'create', d])
    wt = d / 'work'
    wt.mkdir()
    cmd(d, ['git', '-C', wt, 'init', '-q'])
    cmd(d, ['git', '-C', wt, '-c', 'user.name=Validation fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Isolated verification fixture'])
    p = d / 'state/task-a.meta'
    p.write_text(f'kind=ship\nmode=no-mistakes\nworktree={wt}\npr=https://github.com/{repo}/pull/{number}\n')
    p.chmod(0o600)
    cmd(d, [ROOT / 'bin/fm-pr-check.sh', 'task-a', f'https://github.com/{repo}/pull/{number}'], name + '-arm')
    cmd(d, [ROOT / 'bin/fm-check-unregister.sh', 'contributions'])
    script(d, 'z-stop', 'printf "stop-cycle\\n"')
    return d

def watch(d, label):
    return cmd(d, [ROOT / 'bin/fm-watch.sh'], label).stdout

def drain(d, label):
    p = cmd(d, [ROOT / 'bin/fm-wake-drain.sh'], label)
    m = re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', p.stderr)
    assert m, p.stderr
    cmd(d, [ROOT / 'bin/fm-wake-drain.sh', '--ack-through', m[1], '--recovery-generation', m[2]])
    return p.stdout

def snapshot(d, label):
    files = {p.name: p.read_text() for p in (d / 'state').glob('task-a.*') if p.is_file()}
    (EV / (label + '.json')).write_text(json.dumps(files, indent=2) + '\n')

def passed(name, evidence):
    RESULTS.append(dict(name=name, result='pass', live=True, evidence=evidence))
    (EV / 'live-guards-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')
    print('PASS: ' + name, flush=True)

try:
    if '--only-closed' not in sys.argv:
        # Re-publish a genuine committed former template, then change only the
        # stored device numbers. Real stat supplies the live inode/device proof.
        d = setup('live-template-device')
        historical = d / 'previous-poll.sh'
        historical.write_text(cmd(d, ['git', 'show', '38fa6f7bde25e4cd64235581ceb16ca92a8453bc:bin/fm-pr-poll.sh']).stdout)
        publish = d / 'publish-previous.sh'
        publish.write_text(f'''#!/usr/bin/env bash
    set -eu
    . '{ROOT}/bin/fm-pr-lib.sh'
    fm_pr_poll_prepare '{d}/state' task-a github https://github.com/groovejones/groove-sight-platform/pull/4200 github.com groovejones/groove-sight-platform 4200 '{historical}'
    fm_pr_poll_publish_prepared
    ''')
        cmd(d, ['bash', publish])
        registration = d / 'state/task-a.pr-poll-registration'
        lines = registration.read_text().splitlines()
        for row in [9, 10]:
            device, inode = lines[row].split(':')
            lines[row] = f'{int(device) + 1}:{inode}'
        registration.write_text('\n'.join(lines) + '\n')
        snapshot(d, 'live-template-device-before')
        out = watch(d, 'live-template-device-watch')
        assert 'task-a.check.sh: dequeued https://github.com/groovejones/groove-sight-platform/pull/4200 reason=merge_conflict' in out
        assert (d / 'state/task-a.pr-poll-queue-dropped').exists(), 'The armed poll did not record its delivered event'
        assert (d / 'state/task-a.check.sh').read_bytes() == (ROOT / 'bin/fm-pr-poll.sh').read_bytes()
        snapshot(d, 'live-template-device-after')
        drain(d, 'live-template-device-drain')
        passed('A shipped old poll and stored device mismatch recover with unchanged inodes and deliver an actual GitHub removal', 'live-template-device-before.json; live-template-device-after.json; live-template-device-drain.txt')

        d = setup('live-unshipped-refusal')
        registration = d / 'state/task-a.pr-poll-registration'
        lines = registration.read_text().splitlines()
        lines[8] = hashlib.sha256(b'unshipped-template-validation-only').hexdigest()
        for row in [9, 10]:
            device, inode = lines[row].split(':')
            lines[row] = f'{int(device) + 1}:{inode}'
        registration.write_text('\n'.join(lines) + '\n')
        before = registration.read_bytes()
        out = watch(d, 'live-unshipped-refusal-watch')
        assert f'rejected unauthenticated state checks: {d}/state/task-a.check.sh' in out, out
        assert registration.read_bytes() == before, 'Unshipped hash was rewritten'
        assert not (d / 'state/task-a.pr-poll-queue-dropped').exists(), 'Unauthenticated armed poll ran'
        drain(d, 'live-unshipped-refusal-drain')
        passed('An unshipped template hash stays refused after a stored device change', 'live-unshipped-refusal-watch.txt')

        d = setup('live-check-liveness')
        script(d, 'a-slow', 'touch -t 200001010000 "$FM_HOME/state/.last-watcher-beat"\nsleep 1')
        script(d, 'b-rearm', f'''now=$(date +%s)
    modified=$(/usr/bin/stat -f %m "$FM_HOME/state/.last-watcher-beat")
    if [ "$((now - modified))" -ge 900 ]; then printf 'beacon expired\\n'; exit 1; fi
    printf 'completed-check beacon is fresh\\n' > "$FM_HOME/beacon-proof"
    '{ROOT}/bin/fm-watch.sh' > "$FM_HOME/rearm.out" 2> "$FM_HOME/rearm.err"
    ''')
        out = watch(d, 'live-check-liveness-watch')
        assert 'task-a.check.sh: dequeued https://github.com/groovejones/groove-sight-platform/pull/4200 reason=merge_conflict' in out
        rearm = (d / 'rearm.out').read_text() + (d / 'rearm.err').read_text()
        assert 'watcher: already running pid ' in rearm, rearm
        (EV / 'live-check-liveness-rearm.txt').write_text((d / 'beacon-proof').read_text() + rearm)
        drain(d, 'live-check-liveness-drain')
        passed('Completed slow checks refresh liveness, rearming retains the running process, and the later real PR removal is delivered', 'live-check-liveness-rearm.txt; live-check-liveness-drain.txt')

    # Cleanup's optional account-wide orphan scan is outside this feature.
    # Execute its actual supported read-only mode while retaining all scoped
    # PR, retirement, endpoint and metadata cleanup behavior.
    real_bash = shutil.which('bash', path=ENV['PATH'])
    probe = SCRATCH / 'cleanup-probe'
    probe.mkdir()
    wrapper = probe / 'bash'
    wrapper.write_text(f'''#!{sys.executable}
import os, sys
args = sys.argv[1:]
if args and args[0].endswith('/fm-remote-job-reap-orphans.sh'):
    args.append('--dry-run')
os.execv({real_bash!r}, [{real_bash!r}] + args)
''')
    wrapper.chmod(0o700)
    ENV['PATH'] = str(probe) + os.pathsep + ENV['PATH']
    for mode in ['normal', 'force-pending', 'force-swept', 'force-invalid']:
        d = setup('live-closed-' + mode, 24, 'gsp-agent/firstmate')
        # No endpoint or disposable copy survives in this closed task; the
        # public cleanup path therefore cannot affect a runtime or project.
        meta = d / 'state/task-a.meta'
        meta.write_text(meta.read_text().replace('mode=no-mistakes', 'mode=local-only').replace(f'worktree={d}/work', f'worktree={d}/already-removed-copy'))
        if mode in ['force-pending', 'force-invalid']:
            seen = d / 'state/merge-queue-sweep.seen'
            seen.write_text('malformed-seen-record\n')
            seen.chmod(0o600)
        out = watch(d, d.name + '-watch')
        assert 'task-a.check.sh: merged' not in out, out
        assert not (d / 'state/task-a.check.sh').exists(), 'Closed PR remains runnable'
        drain(d, d.name + '-drain')
        meta.write_text(f'window=fm-lab:fm-task-a\nproject={d}/project\n' + meta.read_text())
        ENV['TMUX'] = str(ROOT / 'q/fm-lab') + ',0,0'
        snapshot(d, d.name + '-before-cleanup')
        if mode in ['force-pending', 'force-invalid']:
            assert (d / 'state/task-a.pr-poll-retirement').exists()
            refused = cmd(d, [ROOT / 'bin/fm-teardown.sh', 'task-a'], d.name + '-normal-refusal', ok=False)
            assert refused.returncode and 'pending repository merge-queue sweep' in refused.stderr, refused.stderr
        if mode == 'force-invalid':
            (d / 'state/task-a.pr-poll-retirement').write_text('invalid-receipt\n')
            refused = cmd(d, [ROOT / 'bin/fm-teardown.sh', 'task-a', '--force'], d.name + '-invalid-refusal', ok=False)
            assert refused.returncode and 'invalid PR-poll retirement receipt' in refused.stderr, refused.stderr
            assert meta.exists()
        else:
            args = [ROOT / 'bin/fm-teardown.sh', 'task-a']
            if mode != 'normal':
                args.append('--force')
            cmd(d, args, d.name + '-cleanup')
            assert not meta.exists()
            assert not (d / 'state/task-a.pr-poll').exists()
        snapshot(d, d.name + '-after-cleanup')
    passed('A real closed-unmerged PR retires after an empty scan; force discards pending discovery but still refuses an invalid receipt', 'live-closed-normal-cleanup.txt; live-closed-force-pending-normal-refusal.txt; live-closed-force-pending-cleanup.txt; live-closed-force-swept-cleanup.txt; live-closed-force-invalid-invalid-refusal.txt')
except Exception as exc:
    (EV / 'live-guards-failure.txt').write_text(str(exc) + '\n')
    raise
finally:
    for lock in SCRATCH.glob('*/state/.watch.lock/pid'):
        pid = int(lock.read_text().strip())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError(f'Unexpected live watcher {pid}; explicit scoped stop required')
    shutil.rmtree(SCRATCH)
