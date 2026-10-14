#!/usr/bin/env python3
"""Drive the stock PR registration, polling, watcher, drain and cleanup CLIs.

GitHub is read-only throughout. No forge or runtime executable is stubbed.
The three custom checks are intentional checks registered through the public
interface; their outputs and midpoint timestamps exercise sweep completion.
"""
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path('/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4WK97NVNAQQSVPMPF30NGSD')
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M4WK97NVNAQQSVPMPF30NGSD')
GUARDS_ONLY = sys.argv[1:] == ['--cleanup-guards']
LOG = (EVIDENCE / ('queue-drop-cleanup-live.txt' if GUARDS_ONLY else 'queue-drop-live.txt')).open('w')
RESULTS = {}
LAB = None


def note(text):
    print(text, flush=True)
    LOG.write(text + '\n')
    LOG.flush()


def run(argv, *, env=None, expect=None, timeout=60, quiet=False, stdin=None):
    args = [str(x) for x in argv]
    if not quiet:
        note('$ ' + shlex.join(args))
    proc = subprocess.Popen(args, cwd=ROOT, env=env or ENV,
                            stdin=subprocess.PIPE if stdin is not None else None,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
        note('command exceeded its bounded verification window')
        raise
    if not quiet:
        if out:
            note(out.rstrip('\n'))
        if err:
            note('stderr:\n' + err.rstrip('\n'))
        note('exit=' + str(proc.returncode))
    if expect is not None:
        assert proc.returncode == expect, (args, proc.returncode, out, err)
    return proc.returncode, out, err


def remove_guarded(argv):
    """Ask the existing destructive-command guard before a disposable removal."""
    code, out, err = run(['dcg'], stdin=json.dumps({
        'tool_name': 'Bash', 'tool_input': {'command': shlex.join([str(x) for x in argv])}
    }), quiet=True)
    assert code == 0, (code, out, err)
    if out.strip():
        verdict = json.loads(out)
        assert verdict.get('hookSpecificOutput', {}).get('permissionDecision') != 'deny', out
        assert not verdict.get('decision') == 'block', out
    run(argv, expect=0)


def cleanup_home(home):
    assert home.parent == Path('/tmp') and home.name.startswith('fm-lab.')
    assert (home / '.fm-lab-home').read_text().strip() == 'fm-lab-home v1'
    # Inspect the disposable inventory, then remove only named files and empty
    # directories. No recursive/forced removal, no following symlinks.
    inventory = []
    for directory, dirs, files in os.walk(home, topdown=False, followlinks=False):
        for name in files:
            inventory.append((Path(directory) / name, False))
        for name in dirs:
            item = Path(directory) / name
            inventory.append((item, not item.is_symlink()))
    note('Disposable inventory: ' + ', '.join(str(path.relative_to(home)) for path, _ in inventory))
    for path, is_dir in inventory:
        if is_dir:
            remove_guarded(['rmdir', path])
        else:
            remove_guarded(['rm', '--', path])
    remove_guarded(['rmdir', home])


def write(path, text, mode=0o600):
    assert str(path).startswith(str(LAB) + '/')
    assert not path.exists(), 'refusing to overwrite an existing test input: ' + str(path)
    path.write_text(text)
    path.chmod(mode)


def meta(task, *, url=None, missing=False, mode='no-mistakes'):
    lines = ['window=validation:fm-' + task, 'endpoint_task_id=' + task, 'kind=ship',
             'mode=' + mode, 'worktree=' + str(LAB / ('already-gone' if missing else 'workcopy')),
             'project=' + str(LAB / 'projects' / 'gsp')]
    if url:
        lines.append('pr=' + url)
    write(LAB / 'state' / (task + '.meta'), '\n'.join(lines) + '\n')


def register(task, script):
    write(LAB / 'state' / (task + '.check.sh'), script, 0o700)
    run([ROOT / 'bin/fm-check-register.sh', task], expect=0)


def watcher(label):
    code, out, err = run([ROOT / 'bin/fm-watch.sh'])
    (EVIDENCE / (label + '.txt')).write_text(out + (('\nstderr:\n' + err) if err else ''))
    return code, out, err


def ack(label):
    code, out, err = run([ROOT / 'bin/fm-wake-drain.sh'], expect=0)
    (EVIDENCE / (label + '-drain.txt')).write_text(out + '\nstderr:\n' + err)
    match = re.search(r'WAKE_ACK_REQUIRED:.*--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', err)
    assert match, 'no generation-bound acknowledgement was offered'
    run([ROOT / 'bin/fm-wake-drain.sh', '--ack-through', match[1],
         '--recovery-generation', match[2]], expect=0)


def check_cleanup_readers(api):
    note('\nCleanup must keep an open github.com PR record even under a conflicting GH_HOST.')
    for reader in ['gh', 'gh-axi']:
        task = 'open-record-' + reader
        meta(task, url=api['a']['url'], missing=True, mode='direct-PR')
        path = LAB / ('state/' + task + '.meta')
        before = path.read_bytes()
        cleanup_env = ENV.copy()
        if reader == 'gh-axi':
            # The installed gh-axi itself depends on gh. Removing gh cannot
            # force a successful fallback. Drive the stock fallback reader
            # directly against the live forge with its normal dependencies.
            probe = LAB / 'fallback-reader.sh'
            write(probe, '#!/usr/bin/env bash\nset -eu\n. ' + shlex.quote(str(ROOT / 'bin/fm-pr-lib.sh')) + '\n'
                  'fm_pr_github_read_record_with_gh_axi groovejones groove-sight-platform 4017\n'
                  'printf "state=%s\\nmerged=%s\\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"\n', 0o700)
            note('Direct stock fallback-reader integration against real gh-axi; automatic handover is not injected.')
            _, output, _ = run(['bash', probe], env=cleanup_env, expect=0)
            assert output == 'state=OPEN\nmerged=false\n', output
            assert path.read_bytes() == before
            RESULTS['fallback_reader_live_host_binding'] = 'pass'
            continue
        code, out, err = run([ROOT / 'bin/fm-teardown.sh', task], env=cleanup_env)
        assert code == 1 and 'still open' in err, (reader, code, out, err)
        assert path.read_bytes() == before, 'the open PR record changed during refused cleanup'
        RESULTS['cleanup_host_binding_' + reader] = 'pass'


ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith('FM_') and key.endswith('_OVERRIDE'):
        ENV.pop(key)
for key in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM',
            'FM_TASK_ID', 'FM_PRIMARY_HARNESS', 'FM_SUPERVISION_ACTOR',
            'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX', 'HERDR_SESSION']:
    ENV.pop(key, None)
if len(sys.argv) == 3 and sys.argv[1] == '--cleanup':
    LAB = Path(sys.argv[2])
    ENV['TMUX_TMPDIR'] = str(LAB / 'tmux')
    code, out, err = run(['tmux', '-L', 'fm-lab', 'list-sessions'])
    assert code != 0 and 'no server running' in err, 'refusing to clean a running lab'
    cleanup_home(LAB)
    LOG.close()
    sys.exit(0)
# Read the already authenticated account into subprocess environment only.
auth = subprocess.run(['gh', 'auth', 'token', '--user', 'gsp-agent'],
                      capture_output=True, text=True, check=True)
ENV['GH_TOKEN'] = auth.stdout.strip()
auth = None
ENV.update({'TMPDIR': '/tmp', 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_CONFIG_NOSYSTEM': '1', 'FM_CHECK_INTERVAL': '0',
            'FM_POLL': '0.05', 'FM_HEARTBEAT': '999999',
            'FM_SIGNAL_GRACE': '0', 'GH_HOST': 'enterprise.invalid'})

try:
    note('Read-only live GitHub validation; GH_HOST=enterprise.invalid; account=gsp-agent')
    _, labpath, _ = run(['mktemp', '-d', '/tmp/fm-lab.XXXXXX'], expect=0)
    LAB = Path(labpath.strip())
    assert LAB.parent == Path('/tmp') and LAB.name.startswith('fm-lab.')
    run([ROOT / 'bin/fm-lab-home.sh', 'create', LAB], expect=0)
    ENV['FM_HOME'] = str(LAB)
    (LAB / 'tmux').mkdir()
    ENV['TMUX_TMPDIR'] = str(LAB / 'tmux')
    run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'validation',
         '-c', ROOT, '-e', 'FM_HOME=' + str(LAB), 'bash', '--noprofile', '--norc'], expect=0)
    _, tmux_identity, _ = run(['tmux', '-L', 'fm-lab', 'display-message', '-p',
                              '-t', 'validation', '#{socket_path},#{pid},#{pane_index}'], expect=0)
    ENV['TMUX'] = tmux_identity.strip()
    write(LAB / 'config' / 'backend', 'tmux\n')
    write(LAB / 'config' / 'backlog-backend', 'manual\n')
    (LAB / 'workcopy').mkdir()
    run(['git', '-c', 'core.hooksPath=/dev/null', 'init', '-q', LAB / 'workcopy'], expect=0)

    query = '''query{repository(owner:"groovejones",name:"groove-sight-platform"){
      a:pullRequest(number:4017){url state merged isInMergeQueue isDraft headRefOid timelineItems(last:5,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason createdAt}}}}
      b:pullRequest(number:4172){url state merged isInMergeQueue isDraft headRefOid timelineItems(last:5,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason createdAt}}}}
      m:pullRequest(number:4308){url state merged isInMergeQueue isDraft headRefOid timelineItems(last:5,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason createdAt}}}}
    }}'''
    _, raw, _ = run(['gh', 'api', 'graphql', '--hostname', 'github.com', '-f', 'query=' + query,
                     '--jq', '.data.repository'], expect=0)
    api = json.loads(raw)
    (EVIDENCE / 'github-live-pr-states.json').write_text(json.dumps(api, indent=2) + '\n')
    assert api['a']['state'] == api['b']['state'] == 'OPEN'
    assert not api['a']['isInMergeQueue'] and not api['b']['isInMergeQueue']
    assert not api['a']['merged'] and not api['b']['merged'] and api['m']['merged']
    assert len(api['b']['timelineItems']['nodes']) > 1, 'the latest-only scenario needs multiple real removals'
    if GUARDS_ONLY:
        check_cleanup_readers(api)
        note('Live results: ' + json.dumps(RESULTS, sort_keys=True))
        sys.exit(0)

    for task, key in [('task-a', 'a'), ('task-b', 'b'), ('task-m', 'm')]:
        meta(task)
        run([ROOT / 'bin/fm-pr-check.sh', task, api[key]['url']], expect=0)
    # The contribution observer is independent of this queue-drop change.
    run([ROOT / 'bin/fm-check-unregister.sh', 'contributions'], expect=0)

    note('\nCapture the real removal twice before publication: both reads must remain reportable.')
    for attempt in [1, 2]:
        _, out, _ = run(['bash', LAB / 'state/task-a.check.sh'], expect=0)
        event = api['a']['timelineItems']['nodes'][-1]
        reason = json.dumps(event['reason'], ensure_ascii=False)[1:-1]
        assert out == 'dequeued ' + api['a']['url'] + ' reason=' + reason + ' event=' + event['id'] + '\n'
        assert not (LAB / 'state/task-a.pr-poll-queue-dropped').exists()
    RESULTS['capture_before_publication'] = 'pass'

    note('\nMake the durable queue sequence destination unavailable, then retry through the real watcher.')
    sequence_path = LAB / 'state/.wake-queue.seq'
    sequence_path.mkdir()
    code, out, err = watcher('publication-failure')
    assert code != 0, 'watcher silently accepted an unwritable sequence destination'
    assert not (LAB / 'state/task-a.pr-poll-queue-dropped').exists()
    queue = LAB / 'state/.wake-queue'
    assert not queue.exists() or not queue.read_text().strip()
    note('After failure: no handled-removal marker and no durable wake row.')
    remove_guarded(['rmdir', sequence_path])

    register('a-alert', '#!/usr/bin/env bash\nprintf "early-alert\\n"\n')
    register('task-a0', '''#!/usr/bin/env bash
if [ -e "$FM_HOME/state/.last-check" ]; then
  stamp=$(/usr/bin/stat -f %m "$FM_HOME/state/.last-check")
else
  stamp=absent
fi
printf 'midpoint stamp=%s\\n' "$stamp" >> "$FM_HOME/state/sweep-progress"
printf 'midpoint\\n'
''')
    register('z-final', '#!/usr/bin/env bash\nprintf "end-of-sweep\\n"\n')

    code, out, err = watcher('live-first-sweep')
    if out.strip() == 'check: rearm-resurface':
        assert code == 0
        ack('publication-recovery')
        code, out, err = watcher('live-first-sweep')
    assert code == 0, 'retry did not complete'
    expected = {}
    for task, key in [('task-a', 'a'), ('task-b', 'b')]:
        event = api[key]['timelineItems']['nodes'][-1]
        reason = json.dumps(event['reason'], ensure_ascii=False)[1:-1]
        expected[task] = 'check: ' + str(LAB / ('state/' + task + '.check.sh')) + ': dequeued ' + api[key]['url'] + ' reason=' + reason
        assert out.splitlines().count(expected[task]) == 1, (task, out)
        marker = (LAB / ('state/' + task + '.pr-poll-queue-dropped')).read_text()
        assert marker.splitlines() == ['fm-pr-poll-queue-dropped-v1', api[key]['url'], event['id']]
        note(task + ' published marker:\n' + marker.rstrip('\n'))
        assert (LAB / ('state/' + task + '.check.sh')).exists(), 'an unmerged watch was retired'
    assert out.splitlines().count('check: ' + str(LAB / 'state/task-m.check.sh') + ': merged') == 1
    assert 'dequeued ' + api['m']['url'] not in out
    assert not (LAB / 'state/task-m.check.sh').exists(), 'merged poll did not retire'
    assert 'early-alert' in out and 'midpoint' in out and 'end-of-sweep' in out
    assert (LAB / 'state/sweep-progress').read_text() == 'midpoint stamp=absent\n'
    assert (LAB / 'state/.last-check').exists()
    (EVIDENCE / 'live-wake-queue.tsv').write_text(queue.read_text())
    note('First sweep progress:\n' + (LAB / 'state/sweep-progress').read_text().rstrip())
    RESULTS.update({'latest_drop_and_reason': 'pass', 'sweep_completion': 'pass',
                    'publication_failure_retry': 'pass', 'merged_is_not_dequeued': 'pass',
                    'github_host_binding': 'pass', 'multiple_removals_latest_only': 'pass'})
    ack('first-sweep')

    old_timestamp = 946684800
    os.utime(LAB / 'state/.last-check', (old_timestamp, old_timestamp))
    code, out, err = watcher('live-repeat-sweep')
    assert code == 0 and 'early-alert' in out and 'end-of-sweep' in out
    assert 'dequeued ' not in out and ': merged' not in out, 'a handled forge event notified again'
    assert (LAB / 'state/sweep-progress').read_text().splitlines()[-1] == 'midpoint stamp=' + str(old_timestamp)
    assert (LAB / 'state/.last-check').stat().st_mtime > old_timestamp
    note('Repeat sweep progress:\n' + (LAB / 'state/sweep-progress').read_text().rstrip())
    RESULTS['handled_drop_deduplicated'] = 'pass'
    ack('repeat-sweep')

    note('\nA real failed network read must stay silent and preserve the poll.')
    meta('unreadable')
    run([ROOT / 'bin/fm-pr-check.sh', 'unreadable', api['a']['url']], expect=0)
    run([ROOT / 'bin/fm-check-unregister.sh', 'contributions'], expect=0)
    unavailable = ENV.copy()
    unavailable.update({'HTTPS_PROXY': 'http://127.0.0.1:9', 'HTTP_PROXY': 'http://127.0.0.1:9',
                        'ALL_PROXY': 'http://127.0.0.1:9', 'NO_PROXY': ''})
    code, raw, err = run(['gh', 'api', 'graphql', '--hostname', 'github.com', '-f', 'query=' + query], env=unavailable)
    assert code != 0, 'the deliberately unavailable proxy did not refuse the live request'
    _, out, _ = run(['bash', LAB / 'state/unreadable.check.sh'], env=unavailable, expect=0)
    assert out == ''
    assert not (LAB / 'state/unreadable.pr-poll-queue-dropped').exists()
    assert (LAB / 'state/unreadable.check.sh').exists()
    RESULTS['unreadable_forge_is_silent'] = 'pass'

    check_cleanup_readers(api)

    note('\nLive results: ' + json.dumps(RESULTS, sort_keys=True))
finally:
    if LAB is not None:
        # Only this freshly minted home and its private socket may be stopped.
        assert LAB.parent == Path('/tmp') and LAB.name.startswith('fm-lab.')
        assert (LAB / '.fm-lab-home').read_text().strip() == 'fm-lab-home v1'
        note('\nInspect and stop only the lab socket, then remove its disposable home.')
        run(['tmux', '-L', 'fm-lab', 'list-sessions'])
        run(['tmux', '-L', 'fm-lab', 'kill-server'])
        run(['tmux', '-L', 'fm-lab', 'list-sessions'])
        cleanup_home(LAB)
        assert not LAB.exists()
        note('Lab home removed; no test primary or server remains.')
    (EVIDENCE / ('queue-drop-cleanup-results.json' if GUARDS_ONLY else 'queue-drop-live-results.json')).write_text(json.dumps(RESULTS, indent=2) + '\n')
    LOG.close()
