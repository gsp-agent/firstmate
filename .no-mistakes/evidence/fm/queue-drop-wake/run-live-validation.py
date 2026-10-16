#!/usr/bin/env python3
"""Read-only GitHub checks using real Firstmate commands in disposable homes."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA')
EV = Path('/Users/dalecarman/.no-mistakes/evidence/01M53A6E4TERYTKTS6MTXY5YEA')
SCRATCH = ROOT / '.queue-validation-tmp' / 'live'
SCRATCH.mkdir(parents=True, exist_ok=True)
BASE = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_') and k not in ('GH_DEBUG', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')}
BASE.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(SCRATCH))
GH = shutil.which('gh')
BASH = shutil.which('bash')
RESULTS = []

def execute(args, env=BASE, timeout=90, ok=True):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    if ok and p.returncode:
        raise RuntimeError(f'{args[0]} {args[1:3]} exited {p.returncode}: {p.stderr[-3500:]} {p.stdout[-1500:]}')
    return p

def product(home, *args, **kw):
    env = dict(BASE, FM_HOME=str(home), FM_CHECK_INTERVAL='0', FM_POLL='0.05', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
    env.update(kw.pop('extra', {}))
    return execute(args, env=env, **kw)

def save(name, text):
    (EV / name).write_text(text)

def gh(query):
    return json.loads(execute([GH, 'api', 'graphql', '-f', 'query=' + query]).stdout)

def home(name):
    d = SCRATCH / name
    execute([ROOT / 'bin/fm-lab-home.sh', 'create', d])
    wt = d / 'work'
    wt.mkdir()
    execute(['git', '-C', wt, 'init', '-q'])
    execute(['git', '-C', wt, '-c', 'user.name=Validation fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Isolated validation fixture'])
    head = execute(['git', '-C', wt, 'rev-parse', 'HEAD']).stdout.strip()
    execute(['git', '-C', wt, 'update-ref', 'refs/remotes/origin/main', head])
    return d

def arm(d, name, url):
    p = d / 'state' / (name + '.meta')
    p.write_text(f'kind=ship\nmode=no-mistakes\nworktree={d / "work"}\npr={url}\n')
    p.chmod(0o600)
    p = product(d, ROOT / 'bin/fm-pr-check.sh', name, url)
    save(f'{d.name}-{name}-arm.txt', p.stdout + p.stderr)
    product(d, ROOT / 'bin/fm-check-unregister.sh', 'contributions')

def custom(d, name, body):
    p = d / 'state' / (name + '.check.sh')
    p.write_text('#!/usr/bin/env bash\nset -eu\n' + body + '\n')
    p.chmod(0o700)
    product(d, ROOT / 'bin/fm-check-register.sh', name)

def stop(d):
    custom(d, 'z-stop', 'printf "visited\\n" >> "$FM_HOME/stop-visits"\nprintf "stop-cycle\\n"')

def watch(d, label, extra=None, timeout=120):
    p = product(d, ROOT / 'bin/fm-watch.sh', extra=extra or {}, timeout=timeout)
    save(label + '-watch.txt', p.stdout + '\nSTDERR:\n' + p.stderr)
    return p.stdout

def drain(d, label, acknowledge=True):
    p = product(d, ROOT / 'bin/fm-wake-drain.sh')
    save(label + '-drain.txt', p.stdout + '\nSTDERR:\n' + p.stderr)
    if acknowledge:
        m = re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', p.stderr)
        assert m, 'No sequence-bound acknowledgement was requested'
        product(d, ROOT / 'bin/fm-wake-drain.sh', '--ack-through', m[1], '--recovery-generation', m[2])
    return p.stdout

def capture_state(d, label):
    state = d / 'state'
    files = {p.name: p.read_text() for p in state.glob('*.pr-poll*') if p.is_file()}
    files['files'] = sorted(p.name for p in state.iterdir())
    save(label + '-state.json', json.dumps(files, indent=2) + '\n')

def recorded(name, evidence):
    RESULTS.append(dict(name=name, result='pass', live=True, evidence=evidence))
    save('live-results.json', json.dumps(RESULTS, indent=2) + '\n')
    print('PASS: ' + name, flush=True)

try:
    history = gh('query{repository(owner:"groovejones",name:"groove-sight-platform"){pullRequest(number:4308){number state merged isInMergeQueue timelineItems(last:10,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT]){nodes{__typename ... on RemovedFromMergeQueueEvent{id reason createdAt} ... on AddedToMergeQueueEvent{id createdAt}}}}}}')
    save('github-4308-history.json', json.dumps(history, indent=2) + '\n')
    assert any(e.get('reason') == 'failed_checks' and e.get('createdAt') == '2026-10-14T02:32:46Z' for e in history['data']['repository']['pullRequest']['timelineItems']['nodes'])
    current = gh('query{repository(owner:"groovejones",name:"groove-sight-platform"){pullRequests(states:[OPEN],first:100,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor}nodes{number state merged isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT]){nodes{__typename ... on RemovedFromMergeQueueEvent{id reason createdAt} ... on AddedToMergeQueueEvent{id createdAt}}}}}}}')
    save('github-current-open-queue-events.json', json.dumps(current, indent=2) + '\n')
    page = current['data']['repository']['pullRequests']
    assert not page['pageInfo']['hasNextPage'], 'Live proof selection needs pagination'
    drops = [n for n in page['nodes'] if not n['merged'] and not n['isInMergeQueue'] and n['timelineItems']['nodes'] and n['timelineItems']['nodes'][-1].get('__typename') == 'RemovedFromMergeQueueEvent' and n['timelineItems']['nodes'][-1].get('reason') != 'merged']
    assert len(drops) >= 8, 'Expected current stranded pull requests are no longer available'
    for n in drops:
        print(f'GitHub current removal: #{n["number"]} reason={n["timelineItems"]["nodes"][-1].get("reason", "")}', flush=True)

    if '--recovered-only' not in sys.argv:
        d = home('live-notifications')
        arm(d, 'task-a', 'https://github.com/groovejones/groove-sight-platform/pull/4200')
        stop(d)
        first = watch(d, 'live-notifications-first')
        presented = drain(d, 'live-notifications-first')
        for n in drops:
            expected = f'dequeued https://github.com/groovejones/groove-sight-platform/pull/{n["number"]} reason={n["timelineItems"]["nodes"][-1].get("reason", "")}'
            assert first.count(expected + '\n') == 1, ('watch', expected, first)
            assert presented.count(expected + '\n') == 1, ('drain', expected, presented)
        capture_state(d, 'live-notifications-first')
        repeated = watch(d, 'live-notifications-repeat')
        assert 'dequeued ' not in repeated, repeated
        assert 'stop-cycle' in repeated
        drain(d, 'live-notifications-repeat')
        recorded('Armed and unarmed real GitHub removals reach main once with their reasons; restart does not repeat them', 'live-notifications-first-drain.txt; live-notifications-repeat-watch.txt')

        d = home('live-failed-seen')
        arm(d, 'task-a', 'https://github.com/groovejones/groove-sight-platform/pull/4308')
        stop(d)
        seen = d / 'state/merge-queue-sweep.seen'
        seen.write_text('malformed-seen-record\n')
        seen.chmod(0o600)
        for i in range(1, 3):
            out = watch(d, f'live-failed-seen-{i}')
            assert 'dequeued ' not in out
            assert (d / 'state/task-a.pr-poll').exists(), 'Failed sweep lost last sidecar'
            assert (d / 'state/task-a.pr-poll-retirement').exists(), 'Missing retained retirement receipt'
            assert len((d / 'stop-visits').read_text().splitlines()) == i, 'Later check did not run'
            capture_state(d, f'live-failed-seen-{i}')
            drain(d, f'live-failed-seen-{i}')
        seen.write_text('fm-merge-queue-sweep-v1\n')
        recovered = watch(d, 'live-failed-seen-recovered')
        recovered_drain = drain(d, 'live-failed-seen-recovered')
        for n in drops:
            expected = f'dequeued https://github.com/groovejones/groove-sight-platform/pull/{n["number"]} reason='
            assert recovered.count(expected) == 1, expected
            assert recovered_drain.count(expected) == 1, expected
        assert not (d / 'state/task-a.pr-poll').exists(), 'Queue-empty successful sweep did not finish retirement'
        capture_state(d, 'live-failed-seen-recovered')
        recorded('A corrupt seen record retains the last merged watch across restart, later checks still run, and repair delivers the real removals', 'live-failed-seen-1-state.json; live-failed-seen-2-watch.txt; live-failed-seen-recovered-drain.txt; live-failed-seen-recovered-state.json')

    public = gh('query{repository(owner:"kunchenguid",name:"firstmate"){pullRequests(states:[OPEN],first:5,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number isDraft}}}}')
    upstream_pr = next(n['number'] for n in public['data']['repository']['pullRequests']['nodes'] if not n['isDraft'])
    modes = ['recovered'] if '--recovered-only' in sys.argv else ['failed', 'recovered']
    for mode in modes:
        passes = 4 if mode == 'recovered' else 5
        d = home('live-runtime-' + mode)
        arm(d, 'task-a', 'https://github.com/groovejones/groove-sight-platform/pull/4200')
        stop(d)
        watch(d, 'live-runtime-' + mode + '-warmup')
        drain(d, 'live-runtime-' + mode + '-warmup')
        shutil.copyfile(d / 'state/merge-queue-sweep.seen', d / 'saved-seen')
        (d / 'state/merge-queue-sweep.seen').write_text('malformed-seen-record\n')
        for name, url in [('task-b', 'https://github.com/gsp-agent/firstmate/pull/21'), ('task-c', f'https://github.com/kunchenguid/firstmate/pull/{upstream_pr}')]:
            p = d / 'state' / (name + '.meta')
            p.write_text(f'kind=ship\nmode=no-mistakes\nworktree={d / "work"}\npr={url}\n')
            p.chmod(0o600)
        custom(d, 'a-runtime-arm', f'''n=$(cat "$FM_HOME/passes" 2>/dev/null || printf 0)
case "$n" in
  0) '{ROOT}/bin/fm-pr-check.sh' task-b https://github.com/gsp-agent/firstmate/pull/21 >> "$FM_HOME/arm.log" 2>&1
     '{ROOT}/bin/fm-check-unregister.sh' contributions >> "$FM_HOME/arm.log" 2>&1 ;;
  1) '{ROOT}/bin/fm-pr-check.sh' task-c https://github.com/kunchenguid/firstmate/pull/{upstream_pr} >> "$FM_HOME/arm.log" 2>&1
     '{ROOT}/bin/fm-check-unregister.sh' contributions >> "$FM_HOME/arm.log" 2>&1 ;;
  2) if [ '{mode}' = recovered ]; then cp "$FM_HOME/saved-seen" "$FM_HOME/state/merge-queue-sweep.seen"; fi ;;
esac''')
        custom(d, 'z-stop', f'''n=$(cat "$FM_HOME/passes" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\\n' "$n" > "$FM_HOME/passes"
if [ "$n" -ge {passes} ]; then printf 'stop-cycle\\n'; fi''')
        probe = d / 'probe'
        probe.mkdir()
        wrapper = probe / 'bash'
        log = EV / ('live-runtime-' + mode + '-inherited-repos.jsonl')
        log.write_text('')
        wrapper.write_text(f'''#!{sys.executable}
import json, os, sys
if len(sys.argv) > 2 and sys.argv[1].endswith('/fm-pr-queue-sweep.sh') and sys.argv[2] == '--scan':
    with open({str(log)!r}, 'a') as output:
        output.write(json.dumps(dict(raw=os.environ.get('FM_PR_SWEEP_REPOS', ''), repos=os.environ.get('FM_PR_SWEEP_REPOS', '').splitlines())) + '\\n')
os.execv({BASH!r}, [{BASH!r}] + sys.argv[1:])
''')
        wrapper.chmod(0o700)
        out = watch(d, 'live-runtime-' + mode, extra={'PATH': str(probe) + os.pathsep + BASE['PATH']}, timeout=600)
        assert 'dequeued ' not in out, out
        assert (d / 'passes').read_text().strip() == str(passes)
        entries = [json.loads(line) for line in log.read_text().splitlines()]
        expected = ['groovejones/groove-sight-platform', 'gsp-agent/firstmate', 'kunchenguid/firstmate']
        assert len(entries) == passes, entries
        assert entries[0]['repos'] == expected[:1], entries
        assert entries[1]['repos'] == expected[:2], entries
        for entry in entries[2:]:
            assert entry['repos'] == expected, entry
            assert entry['raw'].endswith('\n'), entry
        failures = (d / 'state/.watch-triage.log').read_text().count('merge-queue sweep failed;')
        assert failures == (5 if mode == 'failed' else 2), failures
        save('live-runtime-' + mode + '-triage.txt', (d / 'state/.watch-triage.log').read_text())
        drain(d, 'live-runtime-' + mode)
        recorded('Repositories armed after startup remain one first-seen line each through ' + ('repeated failed sweeps' if mode == 'failed' else 'failed sweeps and successful rebuilding'), log.name)

    print('All live product checks passed.', flush=True)
except Exception as exc:
    save('live-failure.txt', str(exc) + '\n')
    raise
finally:
    # These synchronous daemon invocations exit on each collected wake. Refuse
    # cleanup if any surviving home still owns a live watcher process.
    for lock in SCRATCH.glob('*/state/.watch.lock/pid'):
        pid = int(lock.read_text().strip())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError(f'Unexpected live watcher {pid}; keep disposable home for explicit scoped stop')
    shutil.rmtree(SCRATCH)
