#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53A6E4TERYTKTS6MTXY5YEA')
EV = Path('/Users/dalecarman/.no-mistakes/evidence/01M53A6E4TERYTKTS6MTXY5YEA')
LAB = ROOT / '.queue-validation-tmp/live-queued'
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k != 'GH_DEBUG'}
ENV.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.queue-validation-tmp'), FM_CHECK_INTERVAL='0', FM_POLL='0.05', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
def run(args, label=None):
    p = subprocess.run([str(x) for x in args], env=ENV, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if label:
        (EV / (label + '.txt')).write_text(p.stdout + '\nSTDERR:\n' + p.stderr)
    assert p.returncode == 0, (args[:2], p.returncode, p.stdout, p.stderr)
    return p
def queue():
    p = run(['gh', 'api', 'graphql', '-f', 'query=query{repository(owner:"groovejones",name:"groove-sight-platform"){pullRequests(states:[OPEN],first:100){nodes{number isInMergeQueue timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT]){nodes{__typename ... on RemovedFromMergeQueueEvent{id reason} ... on AddedToMergeQueueEvent{id}}}}}}}'])
    return json.loads(p.stdout)
try:
    before = queue()
    queued = [n['number'] for n in before['data']['repository']['pullRequests']['nodes'] if n['isInMergeQueue']]
    assert queued, 'No real queued pull request is currently available'
    (EV / 'live-queued-before.json').write_text(json.dumps(before, indent=2) + '\n')
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB])
    (LAB / 'work').mkdir()
    meta = LAB / 'state/task-a.meta'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nworktree={LAB}/work\npr=https://github.com/groovejones/groove-sight-platform/pull/4308\n')
    meta.chmod(0o600)
    run([ROOT / 'bin/fm-pr-check.sh', 'task-a', 'https://github.com/groovejones/groove-sight-platform/pull/4308'], 'live-queued-arm')
    run([ROOT / 'bin/fm-check-unregister.sh', 'contributions'])
    stop = LAB / 'state/z-stop.check.sh'
    stop.write_text('#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n')
    stop.chmod(0o700)
    run([ROOT / 'bin/fm-check-register.sh', 'z-stop'])
    first = run([ROOT / 'bin/fm-watch.sh'], 'live-queued-watch')
    after = queue()
    (EV / 'live-queued-after.json').write_text(json.dumps(after, indent=2) + '\n')
    still_queued = [n['number'] for n in after['data']['repository']['pullRequests']['nodes'] if n['isInMergeQueue']]
    retained = (LAB / 'state/task-a.pr-poll').exists()
    snapshot = {p.name: p.read_text() for p in (LAB / 'state').glob('task-a.pr-poll*')}
    snapshot.update(queuedBefore=queued, queuedAfter=still_queued, sidecarRetained=retained)
    (EV / 'live-queued-retention.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    if set(queued).intersection(still_queued):
        assert retained and (LAB / 'state/task-a.pr-poll-retirement').exists()
        assert not (LAB / 'state/task-a.check.sh').exists()
        print(f'PASS: real queued PRs {still_queued} keep the last merged watch sidecar and retirement receipt', flush=True)
    else:
        print('Real queue changed during the scan; inspecting the next cycle.', flush=True)
    p = run([ROOT / 'bin/fm-wake-drain.sh'], 'live-queued-drain')
    m = re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', p.stderr)
    assert m
    run([ROOT / 'bin/fm-wake-drain.sh', '--ack-through', m[1], '--recovery-generation', m[2]])
finally:
    if LAB.exists():
        for lock in LAB.glob('state/.watch.lock/pid'):
            pid = int(lock.read_text().strip())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError(f'Unexpected live watcher {pid}; scoped stop required')
        shutil.rmtree(LAB)
