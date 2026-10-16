#!/usr/bin/env python3
"""Drive real Firstmate binaries and gh against an isolated HTTPS GitHub replay."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
import traceback

ROOT = Path.cwd()
WORK = ROOT / '.phase-test'
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M52ZKA2EPSP789SM0Y7YDE7G')
RESULTS = []
REQUESTS = []
FIXTURE = {'polls': {}, 'pages': {}, 'hook': None, 'gitlab_state': 'opened'}
BASE = dict(os.environ)
for k in list(BASE):
    if k in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND') or k.startswith(('FM_', 'HERDR_')) or k.lower().endswith('_proxy'):
        BASE.pop(k, None)
BASE.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GH_PROMPT_DISABLED='1', GH_TOKEN='disposable-local-replay', NO_PROXY='', no_proxy='')

def run(args, env=None, check=True, timeout=240):
    process=subprocess.Popen([str(x) for x in args],cwd=ROOT,env=env or BASE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        stdout,stderr=process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGTERM)
        try:stdout,stderr=process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);stdout,stderr=process.communicate()
        raise AssertionError(f'test driver deadline {timeout}s expired for {args[0]}: {stdout[-1000:]} {stderr[-1000:]}')
    r=subprocess.CompletedProcess(args,process.returncode,stdout,stderr)
    if check and r.returncode:
        raise AssertionError(f'{args[0]} exited {r.returncode}: {r.stderr[-3000:]} {r.stdout[-1000:]}')
    return r

def save(name, text):
    (EVIDENCE / name).write_text(text)

def node(n, reason='failed_checks', event=None, queued=False, state='OPEN', kind='RemovedFromMergeQueueEvent'):
    return {'number': n, 'url': f'https://github.com/groovejones/groove-sight-platform/pull/{n}', 'state': state, 'merged': state == 'MERGED', 'isInMergeQueue': queued, 'isDraft': False, 'headRefOid': '1'*40,
            'timelineItems': {'nodes': [] if event == '' else [{'__typename': kind, 'id': event or f'replay-{n}', 'reason': reason}]}}

class GraphQL(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        row={'kind':'gitlab-rest','path':self.path,'started':time.time()}
        REQUESTS.append(row)
        if '/merge_requests/' in self.path and not self.path.endswith(('/notes','/approvals','/pipelines','/versions','/commits')):
            value={'id':1,'iid':1,'project_id':1,'title':'Disposable live merge watch','description':'API replay','state':FIXTURE['gitlab_state'],'created_at':'2026-10-14T02:00:00Z','updated_at':'2026-10-14T02:32:46Z','merged_at':'2026-10-14T03:00:00Z' if FIXTURE['gitlab_state']=='merged' else None,'web_url':'https://gitlab.com/acme/merge/-/merge_requests/1','source_branch':'feature','target_branch':'main','author':{'id':1,'name':'Replay agent','username':'replay'},'assignees':[],'reviewers':[],'labels':[],'user_notes_count':0,'upvotes':0,'downvotes':0,'merge_status':'can_be_merged','has_conflicts':False}
        elif self.path.endswith('/version'):
            value={'version':'17.0.0','revision':'fixture'}
        elif self.path.endswith(('/notes','/pipelines','/versions','/commits')):
            value=[]
        else:
            value={'id':1,'path_with_namespace':'acme/merge','web_url':'https://gitlab.com/acme/merge','name':'merge','default_branch':'main'}
        payload=json.dumps(value).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.send_header('Connection','close');self.end_headers();self.wfile.write(payload)
        row.update(status=200,completed=time.time())
        self.close_connection=True
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        variables = body.get('variables', {})
        query = body.get('query', '')
        repo = f"{variables.get('owner')}/{variables.get('repo', variables.get('name'))}"
        sweep = 'pullRequests(' in query
        cursor = variables.get('cursor')
        number = variables.get('number')
        row = {'repository': repo, 'kind': 'sweep' if sweep else 'poll', 'number': number, 'cursor': cursor, 'owner_type': type(variables.get('owner')).__name__, 'repo_type': type(variables.get('repo')).__name__, 'number_type': type(number).__name__, 'started': time.time()}
        ordering=re.search(r'orderBy\s*:\s*\{\s*field\s*:\s*(\w+)',query)
        row['order_by']=ordering[1] if ordering else None
        REQUESTS.append(row)
        try:
            # This is the server's GraphQL variable contract, not a source assertion.
            if not isinstance(variables.get('owner'), str) or not isinstance(variables.get('repo'), str):
                response = {'errors': [{'message': 'owner and repo must be GraphQL String values'}]}
                code = 422
            else:
                if FIXTURE['hook']:
                    FIXTURE['hook'](row)
                if sweep:
                    value = FIXTURE['pages'].get((repo, cursor), ([], False, None))
                    if value == 'fail':
                        response = {'errors': [{'message': 'disposable page read failure'}]}
                        code = 503
                    else:
                        nodes, more, end = value
                        response = {'data': {'repository': {'pullRequests': {'nodes': nodes, 'pageInfo': {'hasNextPage': more, 'endCursor': end}}}}}
                        code = 200
                else:
                    response = {'data': {'repository': {'pullRequest': FIXTURE['polls'].get((repo, number), node(number or 1, event=''))}}}
                    code = 200
            payload = json.dumps(response).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(payload)
            row['completed'] = time.time()
            row['status'] = code
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            row['status'] = 'client deadline closed connection'
        self.close_connection = True

class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_CONNECT(self):
        if self.path not in ('api.github.com:443','gitlab.com:443'):
            self.send_error(403, 'external access refused by disposable proxy')
            return
        self.send_response(200, 'Connection established')
        self.end_headers()
        try:
            stream = TLS.wrap_socket(self.connection, server_side=True)
            GraphQL(stream, self.client_address, self.server)
            stream.close()
        except (ConnectionResetError, ssl.SSLError):
            pass
        self.close_connection = True

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class Lab:
    def __init__(self, name):
        self.name = name
        self.home = Path(tempfile.mkdtemp(prefix='fm-lab-', dir=WORK))
        run([ROOT/'bin/fm-lab-home.sh', 'create', self.home])
        self.state = self.home/'state'
        self.env = dict(BASE, FM_HOME=str(self.home), GH_CONFIG_DIR=str(self.home/'config/gh'), SSL_CERT_FILE=str(WORK/'replay-cert.pem'), HTTPS_PROXY=PROXY, https_proxy=PROXY, FM_CHECK_INTERVAL='0', FM_CHECK_TIMEOUT='30', FM_POLL='1', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0', TMUX='.phase-test/fm-lab-queue.sock,0,0', TMPDIR=str(WORK/'tmp'), GITLAB_TOKEN='disposable-local-replay', GITLAB_HOST='gitlab.com', GLAB_CONFIG_DIR=str(self.home/'config/glab'), GLAB_CHECK_UPDATE='false')
        self.cycle_number = 0
        # A genuine registered custom check gives every quiet cycle an observable end.
        self.register('z-end', 'printf "end-of-cycle\\n"\n')
        self.log = []
    def register(self, ident, body):
        path = self.state/f'{ident}.check.sh'
        path.write_text('#!/usr/bin/env bash\n'+body)
        path.chmod(0o700)
        run([ROOT/'bin/fm-check-register.sh', ident], self.env)
    def arm(self, ident, repo, number, template=None, kind='ship', provider='github'):
        host='github.com' if provider=='github' else 'gitlab.com'
        url = f'https://{host}/{repo}/'+(f'pull/{number}' if provider=='github' else f'-/merge_requests/{number}')
        path = self.state/f'{ident}.meta'
        path.write_text(f'window=fm-lab-queue-proof:fm-{ident}\nendpoint_task_id={ident}\nkind={kind}\nmode=local-only\nworktree={self.home}/missing-worktree\nproject={self.home}/missing-project\npr={url}\n')
        path.chmod(0o600)
        env = dict(self.env, LAB_ID=ident, LAB_URL=url, LAB_REPO=repo, LAB_NUMBER=str(number), LAB_TEMPLATE=str(template or ROOT/'bin/fm-pr-poll.sh'), LAB_PROVIDER=provider,LAB_HOST=host)
        run(['bash', WORK/'arm.sh'], env)
    def cycle(self, label, check=True):
        self.cycle_number += 1
        r = run([ROOT/'bin/fm-watch.sh'], self.env, check=check)
        self.log.append(f'--- {label}: watcher exit {r.returncode} ---\n{r.stdout}{r.stderr}')
        return r
    def drain(self, label, ack=True):
        r = run([ROOT/'bin/fm-wake-drain.sh'], self.env)
        self.log.append(f'--- {label}: delivered to main ---\n{r.stdout}{r.stderr}')
        if ack:
            match = re.search(r'WAKE_ACK_REQUIRED:.*(--ack-through \d+ --recovery-generation [A-Za-z0-9._-]+)', r.stderr)
            if match:
                run([ROOT/'bin/fm-wake-drain.sh', *match[1].split()], self.env)
        return r.stdout
    def teardown(self):
        # No persistent server, agent, endpoint, or project was launched by this lab.
        save(f'{self.name}.log', '\n'.join(self.log))
        shutil.rmtree(self.home)

def reset():
    FIXTURE.update(polls={}, pages={}, hook=None,gitlab_state='opened')

def scenario(name, fn):
    reset()
    started = len(REQUESTS)
    lab = Lab(name)
    try:
        details = fn(lab)
        RESULTS.append({'name': name, 'result': 'pass', 'details': details, 'requests': len(REQUESTS)-started})
        print(f'PASS {name}: {details}', flush=True)
    except Exception as error:
        lab.log.append(traceback.format_exc())
        RESULTS.append({'name': name, 'result': 'fail', 'details': str(error), 'requests': len(REQUESTS)-started})
        print(f'FAIL {name}: {error}', flush=True)
    finally:
        lab.teardown()
        save('live-results.json', json.dumps(RESULTS, indent=2)+'\n')

REPO = 'groovejones/groove-sight-platform'

def replay(lab):
    history = json.loads((EVIDENCE/'github-4308-history.json').read_text())['data']['repository']['pullRequest']['timelineItems']['nodes']
    removal = next(e for e in history if e.get('reason') == 'failed_checks')
    dropped = node(4308, event=removal['id'], reason=removal['reason'])
    dropped['timelineItems']['nodes'] = [removal]
    FIXTURE['polls'][REPO, 4308] = node(4308, event='', queued=True)
    FIXTURE['pages'][REPO, None] = ([node(4308, event='', queued=True)], False, None)
    lab.arm('task-a', REPO, 4308)
    before = lab.cycle('4308 queued at 9:09 PM Central').stdout
    assert 'dequeued ' not in before, before
    lab.drain('queued baseline')
    FIXTURE['polls'][REPO, 4308] = dropped
    numbers = [(3941,'merge_conflict'),(3950,'merge_conflict'),(3939,'manual'),(4006,'merge_conflict'),(4017,'failed_checks'),(4111,'merge_conflict'),(4172,'manual'),(4183,'merge_conflict'),(4200,'merge_conflict')]
    rows = [node(n, reason) for n, reason in numbers] + [dropped, node(3361, kind='AddedToMergeQueueEvent'), node(9001, reason='merged')]
    FIXTURE['pages'][REPO, None] = (rows[:6], True, 'page2')
    FIXTURE['pages'][REPO, 'page2'] = (rows[6:], False, None)
    output = lab.cycle('historical removal plus nine stranded PRs').stdout
    assert output.count('dequeued ') == 10, output
    delivered = lab.drain('first drain before simulated interruption', ack=False)
    repeated = lab.drain('drain again after interruption')
    for n, reason in numbers+[(4308, 'failed_checks')]:
        expect = f'dequeued https://github.com/{REPO}/pull/{n} reason={reason}'
        assert output.count(expect) == 1 and delivered.count(expect) == 1 and repeated.count(expect) == 1, expect
    assert 'pull/3361 ' not in output and 'pull/9001 ' not in output, output
    assert removal['id'] in (lab.state/'merge-queue-sweep.seen').read_text()
    repeat = lab.cycle('restart after acknowledgement').stdout
    assert 'dequeued ' not in repeat, repeat
    lab.drain('repeat acknowledged')
    FIXTURE['polls'][REPO, 4308] = node(4308, event='second-independent-removal')
    again = lab.cycle('same PR leaves queue under a new removal event').stdout
    assert again.count(f'dequeued https://github.com/{REPO}/pull/4308 reason=failed_checks') == 1, again
    lab.drain('new event delivered')
    return 'Exact GitHub #4308 event and nine stranded PRs each delivered once; drains survive interruption; acknowledged events stay silent; new event wakes again.'

def numeric(lab):
    for repo, n in [('acme/123', 7), ('123/true', 8), ('false/null',9)]:
        lab.arm(f'task-{n}', repo, n)
        FIXTURE['polls'][repo,n] = node(n)
        FIXTURE['pages'][repo,None] = ([node(n+10)], True, 'page2')
        FIXTURE['pages'][repo,'page2'] = ([node(n+20)], False, None)
    start=len(REQUESTS)
    out=lab.cycle('numeric and JSON literal repository identities').stdout
    assert out.count('dequeued ') == 9, out
    assert 'dequeued https://github.com/acme/123/pull/7 reason=failed_checks' in out
    for row in REQUESTS[start:]:
        assert row['owner_type']=='str' and row['repo_type']=='str',row
        if row['kind']=='poll': assert row['number_type']=='int',row
    lab.drain('numeric names delivered')
    return 'Real gh sent String owner/repo values on all poll and two-page sweep requests, retained integer PR numbers, and delivered nine drops.'

def queued_sighting(lab):
    repo='acme/interpage'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
    FIXTURE['pages'][repo,None]=([node(2, queued=True, kind='AddedToMergeQueueEvent')], True, 'page2')
    FIXTURE['pages'][repo,'page2']=([],False,None)
    def hook(row):
        if row['kind']=='sweep' and row['cursor']=='page2':
            FIXTURE['pages'][repo,None]=([node(2,reason='failed_checks')],True,'page2')
    FIXTURE['hook']=hook
    first=lab.cycle('last watch merged; unarmed PR drops after page 1').stdout
    assert 'dequeued ' not in first, first
    assert (lab.state/'task-a.pr-poll').is_file() and (lab.state/'task-a.pr-poll-retirement').is_file()
    assert not (lab.state/'task-a.check.sh').exists()
    lab.log.append('After first sweep: runnable poll removed; discovery sidecar and exact retirement receipt retained.\n')
    lab.drain('merge delivered')
    second=lab.cycle('next sweep observes removal and no queued PRs').stdout
    assert second.count(f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks')==1,second
    assert not (lab.state/'task-a.pr-poll').exists() and not (lab.state/'task-a.pr-poll-retirement').exists()
    lab.log.append('After second sweep: removal durable; discovery sidecar and retirement receipt removed.\n')
    lab.drain('drop delivered')
    third=lab.cycle('retired repository no longer scanned').stdout
    assert 'dequeued ' not in third,third
    lab.drain('quiet after retirement')
    return 'A queued page-1 sighting retains discovery after inter-page drop; next sweep reports failed_checks once and retires only afterward.'

def failed_pages(lab):
    lab.env['FM_CHECK_TIMEOUT']='2'
    repo='acme/retry'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
    FIXTURE['pages'][repo,None]=([node(2)],True,'page2')
    FIXTURE['pages'][repo,'page2']='fail'
    first=lab.cycle('last watch merged and page 2 fails').stdout
    assert 'dequeued ' not in first,first
    assert (lab.state/'task-a.pr-poll').exists() and (lab.state/'task-a.pr-poll-retirement').exists()
    lab.drain('merge survives failed scan')
    def hook(row):
        if row['repository']==repo and row['cursor']=='page2': time.sleep(3)
    FIXTURE['hook']=hook
    lab.cycle('second page exceeds its real two-second deadline')
    assert (lab.state/'task-a.pr-poll').exists()
    lab.drain('timeout cycle')
    FIXTURE['hook']=None
    FIXTURE['pages'][repo,'page2']=([],False,None)
    final=lab.cycle('later successful scan retries retained repository').stdout
    assert final.count(f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks')==1,final
    assert not (lab.state/'task-a.pr-poll').exists()
    lab.drain('retried drop delivered')
    return 'Failed and genuinely timed-out second pages preserve last-watch discovery; successful retry delivers the previously unarmed drop.'

def seen_failure(lab):
    a='acme/seen'; b='acme/later'
    lab.arm('task-a',a,1)
    lab.arm('task-b',b,3)
    FIXTURE['polls'][a,1]=node(1)
    FIXTURE['polls'][b,3]=node(3,event='')
    FIXTURE['pages'][a,None]=([node(1),node(2)],False,None)
    seen=lab.state/'merge-queue-sweep.seen'
    seen.write_text('malformed seen record\n'); seen.chmod(0o600)
    for label in ['malformed seen, first cycle','malformed seen, restart']:
        start=len(REQUESTS)
        lab.cycle(label)
        assert any(r['kind']=='poll' and r['repository']==b for r in REQUESTS[start:])
        assert not any(r['kind']=='sweep' for r in REQUESTS[start:])
        assert (lab.state/'task-a.pr-poll').exists()
        lab.drain(label+' delivered')
    FIXTURE['polls'][a,1]=node(1,state='MERGED',reason='merged')
    lab.cycle('last watch merges with unreadable deduplication record')
    assert (lab.state/'task-a.pr-poll').exists() and (lab.state/'task-a.pr-poll-retirement').exists()
    lab.drain('merge notification')
    seen.write_text('fm-merge-queue-sweep-v1\n')
    final=lab.cycle('seen record repaired; retained drop read and published').stdout
    assert final.count(f'dequeued https://github.com/{a}/pull/2 reason=failed_checks')==1,final
    assert not (lab.state/'task-a.pr-poll').exists()
    lab.drain('retained drop notification')
    return 'Malformed seen data fails only the sweep; later PR polls run in both cycles, last-watch discovery survives, and recovery delivers the missed drop.'

def mixed_repositories(lab):
    a='acme/complete'; b='acme/failing'
    for i,repo in enumerate([a,b],1):
        lab.arm(f'task-{i}',repo,1)
        FIXTURE['polls'][repo,1]=node(1,event='')
    FIXTURE['pages'][a,None]=([node(2)],False,None)
    FIXTURE['pages'][b,None]='fail'
    out=lab.cycle('completed repository followed by failed repository').stdout
    assert out.count(f'dequeued https://github.com/{a}/pull/2 reason=failed_checks')==1,out
    assert 'dequeued https://github.com/acme/failing/' not in out,out
    lab.drain('completed results published despite aggregate failure')
    return 'Completed repository removal is delivered while another repository page fails.'

def template_recovery(lab):
    historical=lab.home/'historical.sh'
    r=run(['git','show','38fa6f7bde25e4cd64235581ceb16ca92a8453bc:bin/fm-pr-poll.sh'])
    historical.write_text(r.stdout); historical.chmod(0o600)
    repo='acme/upgrade'
    lab.arm('task-a',repo,1,template=historical)
    reg=lab.state/'task-a.pr-poll-registration'
    lines=reg.read_text().splitlines()
    for n in [9,10]:
        dev,inode=lines[n].split(':'); lines[n]=f'{int(dev)+1}:{inode}'
    reg.write_text('\n'.join(lines)+'\n')
    FIXTURE['polls'][repo,1]=node(1)
    out=lab.cycle('shipped prior template plus volume device renumber').stdout
    assert f'dequeued https://github.com/{repo}/pull/1 reason=failed_checks' in out,out
    assert 'rejected unauthenticated' not in out,out
    assert hashlib.sha256((lab.state/'task-a.check.sh').read_bytes()).digest()==hashlib.sha256((ROOT/'bin/fm-pr-poll.sh').read_bytes()).digest()
    lab.drain('recovered watch delivered')
    # Hash-only tampering is not an upgrade, including when devices shift again.
    lines=reg.read_text().splitlines(); lines[8]='f'*64
    for n in [9,10]:
        dev,inode=lines[n].split(':'); lines[n]=f'{int(dev)+1}:{inode}'
    reg.write_text('\n'.join(lines)+'\n')
    start=len(REQUESTS)
    out=lab.cycle('unshipped template hash with unchanged check and renumber').stdout
    assert 'rejected unauthenticated state checks' in out,out
    assert not any(r['kind']=='poll' and r['repository']==repo for r in REQUESTS[start:])
    lab.drain('tampered registration refused')
    return 'Shipped-template + device-renumber recovery resumes polling; unshipped hash-only tampering stays refused without executing the check.'

def baseline_comparison(lab):
    removal=next(e for e in json.loads((EVIDENCE/'github-4308-history.json').read_text())['data']['repository']['pullRequest']['timelineItems']['nodes'] if e.get('reason')=='failed_checks')
    repo=REPO
    FIXTURE['polls'][repo,4308]=node(4308,event=removal['id'],reason=removal['reason'])
    lab.arm('task-a',repo,4308)
    before=lab.home/'baseline-poll.sh'
    before.write_text(run(['git','show','20dcbf91520b1816663b81873ad67d0b93b3e4d6:bin/fm-pr-poll.sh']).stdout)
    env=dict(lab.env,FM_PR_POLL_ID='task-a',FM_PR_POLL_STATE=str(lab.state))
    args=['--validated','github',f'https://github.com/{repo}/pull/4308','github.com',repo,'4308']
    old=run(['bash',before,*args],env)
    new=run(['bash',ROOT/'bin/fm-pr-poll.sh',*args],env)
    lab.log.append(f'Baseline poll output: {old.stdout!r}; exit {old.returncode}\nCurrent poll output: {new.stdout!r}; exit {new.returncode}\n')
    assert old.stdout=='' and 'reason=failed_checks' in new.stdout
    assert removal['id'] in new.stdout
    return 'The base-commit poll is silent for the exact #4308 removal; the current poll emits the PR, failed_checks, and its real GitHub removal-event ID.'

def lifecycle(lab):
    repo='acme/lifecycle'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
    FIXTURE['pages'][repo,None]=([node(2)],False,None)
    # Before the watcher observes the merge, both public cleanup and cross-repo
    # re-arm must preserve discovery without requiring a pre-existing receipt.
    for args in [[ROOT/'bin/fm-teardown.sh','task-a'],[ROOT/'bin/fm-pr-check.sh','task-a','https://github.com/other/repo/pull/3']]:
        r=run(args,lab.env,check=False)
        lab.log.append(f'Before merge observed: {args[0].name} exit {r.returncode}\n{r.stdout}{r.stderr}')
        assert r.returncode and 'pending repository merge-queue sweep; preserving task state' in r.stderr,r.stderr
        assert (lab.state/'task-a.pr-poll').is_file() and not (lab.state/'task-a.pr-poll-retirement').exists()
    out=lab.cycle('preserved discovery reports drop after refused cleanup and rearm').stdout
    assert f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks' in out,out
    lab.drain('preserved removal delivered')
    # The target commit also stops a closed-unmerged watch without a merge wake.
    lab.arm('task-closed',repo,18)
    FIXTURE['polls'][repo,18]=node(18,state='CLOSED',event='')
    FIXTURE['pages'][repo,None]=( [],False,None)
    out=lab.cycle('closed without merging and queue-empty sweep').stdout
    assert 'task-closed.check.sh: merged' not in out
    assert not (lab.state/'task-closed.pr-poll').exists() and not (lab.state/'task-closed.check.sh').exists()
    lab.drain('closed cycle acknowledged')
    r=run([ROOT/'bin/fm-teardown.sh','task-closed'],lab.env)
    lab.log.append(f'Normal cleanup after empty sweep: exit {r.returncode}\n{r.stdout}{r.stderr}')
    assert not (lab.state/'task-closed.meta').exists()
    return 'Cleanup and cross-repository rearm preserve an unobserved last-watch merge; its unarmed drop is delivered. Closed-unmerged watch retires after one empty sweep and normal cleanup succeeds.'

def forced_cleanup(lab):
    repo='acme/force'
    for ident, sweep in [('without-sweep',False),('with-sweep',True),('invalid-receipt',False)]:
        lab.arm(ident,repo,18)
        FIXTURE['polls'][repo,18]=node(18,state='CLOSED',event='')
        FIXTURE['pages'][repo,None]=( [],False,None) if sweep else 'fail'
        lab.cycle(f'{ident}: closed pull request observed')
        lab.drain(f'{ident}: close cycle acknowledged')
        receipt=lab.state/f'{ident}.pr-poll-retirement'
        if not sweep:
            assert receipt.is_file() and (lab.state/f'{ident}.pr-poll').is_file()
        if ident=='invalid-receipt':
            receipt.write_text('invalid receipt\n')
        else:
            if not sweep:
                refused=run([ROOT/'bin/fm-teardown.sh',ident],lab.env,check=False)
                lab.log.append(f'Normal cleanup while pending: exit {refused.returncode}\n{refused.stdout}{refused.stderr}')
                assert refused.returncode and 'pending repository merge-queue sweep' in refused.stderr
        r=run([ROOT/'bin/fm-teardown.sh',ident,'--force'],lab.env,check=False)
        lab.log.append(f'Explicit discard {ident}: exit {r.returncode}\n{r.stdout}{r.stderr}')
        if ident=='invalid-receipt':
            assert r.returncode and 'invalid PR-poll retirement receipt' in r.stderr,r.stderr
            assert (lab.state/f'{ident}.meta').exists() and receipt.exists()
        else:
            assert r.returncode==0,r.stderr
            assert not (lab.state/f'{ident}.meta').exists() and not (lab.state/f'{ident}.pr-poll').exists()
    return 'Explicit --force discards the closed watch with or without a sweep; ordinary cleanup refuses pending discovery; invalid retirement receipts remain refused even with --force.'

def retained_renumber(lab):
    repo='acme/retained'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
    FIXTURE['pages'][repo,None]='fail'
    lab.cycle('merge observed but repository scan fails')
    lab.drain('merge notification acknowledged')
    receipt=lab.state/'task-a.pr-poll-retirement'
    assert receipt.is_file() and not (lab.state/'task-a.pr-poll-registration').exists()
    before_inode=(lab.state/'task-a.pr-poll').stat().st_ino
    lines=receipt.read_text().splitlines()
    for n in [9,10,12]:
        dev,inode=lines[n].split(':'); lines[n]=f'{int(dev)+1}:{inode}'
    receipt.write_text('\n'.join(lines)+'\n')
    # Both public clients must reach the same identity proof, not reject a
    # live-device / unchanged-inode receipt as tampering.
    for args in [[ROOT/'bin/fm-teardown.sh','task-a'],[ROOT/'bin/fm-pr-check.sh','task-a','https://github.com/other/repo/pull/3']]:
        r=run(args,lab.env,check=False)
        lab.log.append(f'Renumbered retained receipt: {args[0].name} exit {r.returncode}\n{r.stdout}{r.stderr}')
        assert r.returncode and 'pending repository merge-queue sweep' in r.stderr,r.stderr
    FIXTURE['pages'][repo,None]=([node(2)],False,None)
    out=lab.cycle('restart on live device with unchanged retained inode').stdout
    assert f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks' in out,out
    assert not (lab.state/'task-a.pr-poll').exists() and not receipt.exists()
    lab.log.append(f'Retained sidecar inode {before_inode}: unchanged proof accepted; exact retired artifacts removed.\n')
    lab.drain('retained drop delivered')
    return 'A device-renumbered retained receipt passes unchanged-inode proof through cleanup, rearm, and restart; the drop is delivered before exact retirement.'

def slow_checks(lab):
    repo='acme/slow'
    for n in range(1,5):
        lab.arm(f'task-{n}',repo,n)
        FIXTURE['polls'][repo,n]=node(n,event='' if n<4 else 'last-poll-removal',queued=n<4)
    FIXTURE['pages'][repo,None]=([node(9)],False,None)
    # A custom check backdates the existing beacon just before completion.
    # The following API read must observe the real completion refresh.
    lab.register('a-custom', 'python3 - <<\'PY\'\nimport os,time\np=os.environ["FM_HOME"]+"/state/.last-watcher-beat"\nos.utime(p,(time.time()-950,time.time()-950))\nprint("custom-check-completed")\nPY\n')
    paused=threading.Event(); release=threading.Event(); ages=[]
    def hook(row):
        if row['kind']!='poll' or row['repository']!=repo:return
        age=time.time()-(lab.state/'.last-watcher-beat').stat().st_mtime
        ages.append({'before_poll':row['number'],'beacon_age_seconds':age})
        assert age<30,ages
        if row['number']==3:
            paused.set()
            assert release.wait(40),'rearm test did not release the live request'
        # Model elapsed work by aging only the existing persisted clock input;
        # production liveness/stall bounds and completion code stay untouched.
        os.utime(lab.state/'.last-watcher-beat',(time.time()-950,time.time()-950))
        time.sleep(.2)
    FIXTURE['hook']=hook
    p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],cwd=ROOT,env=lab.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        assert paused.wait(75),'did not reach the third real gh poll'
        rearm=run([ROOT/'bin/fm-watch.sh'],lab.env,timeout=30)
        lab.log.append(f'Rearm during third collected check: exit {rearm.returncode}\n{rearm.stdout}{rearm.stderr}')
        assert 'already running pid' in rearm.stdout+rearm.stderr,rearm.stdout+rearm.stderr
        release.set()
        stdout,stderr=p.communicate(timeout=60)
        lab.log.append(f'Original watcher after rearm: exit {p.returncode}\n{stdout}{stderr}\nCompleted-check beacon observations:\n{json.dumps(ages,indent=2)}\n')
        assert p.returncode==0,stderr
        assert len(ages)==4,ages
        assert f'dequeued https://github.com/{repo}/pull/4 reason=failed_checks' in stdout,stdout
        assert f'dequeued https://github.com/{repo}/pull/9 reason=failed_checks' in stdout,stdout
        lab.drain('final poll and repository sweep delivered after rearm')
    finally:
        release.set()
        if p.poll() is None:p.terminate();p.communicate(timeout=15)
    return 'Completion of real custom and gh checks refreshes the existing expired beacon at unchanged default bounds; concurrent rearm preserves the running watcher, final PR and sweep drops arrive.'

def long_sweep(lab):
    lab.env['FM_CHECK_TIMEOUT']='2'
    repo='acme/long-pages'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,event='')
    for cursor,n,next_cursor in [(None,2,'page2'),('page2',3,'page3'),('page3',4,None)]:
        FIXTURE['pages'][repo,cursor]=([node(n)],next_cursor is not None,next_cursor)
    def hook(row):
        if row['kind']=='sweep':time.sleep(1.2)
    FIXTURE['hook']=hook
    start=time.monotonic()
    out=lab.cycle('three pages each below deadline but scan exceeds one deadline').stdout
    elapsed=time.monotonic()-start
    assert out.count('dequeued ')==3,out
    for n in [2,3,4]: assert f'dequeued https://github.com/{repo}/pull/{n} reason=failed_checks' in out
    lab.drain('every completed page delivered')
    lab.log.append(f'Scan pages delayed 1.2s each; per-page deadline 2s; whole watcher cycle {elapsed:.2f}s.\n')
    return 'Three real API pages took more than the two-second page budget in aggregate and still delivered every removal.'

def reason_preservation(lab):
    repo='acme/reasons'
    # Probe the external CLI's rendering separately: gh renders U+0001 as ^A
    # even before Firstmate sees it. That is not the queue-drop regression.
    FIXTURE['polls'][repo,1]=node(1,reason='control\u0001')
    probe=run(['gh','api','graphql','--hostname','github.com','-f','owner=acme','-f','repo=reasons','-F','number=1','-f','query=query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){timelineItems(last:1,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){nodes{... on RemovedFromMergeQueueEvent{id reason}}}}}}','--jq','.data.repository.pullRequest.timelineItems.nodes[0].reason | tojson'],lab.env)
    lab.log.append(f'Independent real-gh rendering probe, API input control U+0001: {probe.stdout!r}\n')
    reason=('long reason '*400)+'failed "checks"\\path\nnext\tline\réchec event=not-the-id'
    escaped=json.dumps(reason,ensure_ascii=False)[1:-1]
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,reason=reason,event='actual-removal-id')
    FIXTURE['pages'][repo,None]=([node(1,reason=reason,event='actual-removal-id'),node(2,reason=''),node(3,reason='échec des vérifications')],False,None)
    out=lab.cycle('long, escaped and Unicode GitHub reasons').stdout
    expect=f'dequeued https://github.com/{repo}/pull/1 reason={escaped}'
    assert out.count(expect)==1,out
    assert f'dequeued https://github.com/{repo}/pull/2 reason=\n' in out,out
    assert f'dequeued https://github.com/{repo}/pull/3 reason=échec des vérifications' in out,out
    marker=(lab.state/'task-a.pr-poll-queue-dropped').read_text().splitlines()
    assert marker[-1]=='actual-removal-id',marker
    delivered=lab.drain('full GitHub reason delivered with bounded line escaping')
    assert delivered.count(expect)==1,delivered
    return 'Long and Unicode GitHub reasons survive poll, sweep, and drain; controls are escaped and event-like reason text cannot replace the actual deduplication event ID.'

def gitlab_continuity(lab):
    repo='acme/seen-before-gitlab'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1)
    lab.arm('task-b','acme/merge',1,provider='gitlab')
    seen=lab.state/'merge-queue-sweep.seen';seen.write_text('malformed record\n');seen.chmod(0o600)
    for label in ['first malformed-seen cycle','restart with malformed seen']:
        start=len(REQUESTS)
        lab.cycle(label)
        assert any(r['kind']=='gitlab-rest' and '/merge_requests/1' in r['path'] for r in REQUESTS[start:]),REQUESTS[start:]
        lab.drain(label+' notifications')
    FIXTURE['gitlab_state']='merged'
    out=lab.cycle('unrelated GitLab MR merges while seen record remains invalid').stdout
    assert 'task-b.check.sh: merged' in out,out
    delivered=lab.drain('GitLab merge delivered to main')
    assert 'https://gitlab.com/acme/merge/-/merge_requests/1 external' in delivered,delivered
    return 'The real glab CLI reads the later GitLab watch in the malformed-seen cycle and on restart, then its merge notification reaches main despite the GitHub sweep failure.'

def immutable_cursor(lab):
    repo='acme/mutable-update'
    lab.arm('task-a',repo,1)
    FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
    items=[{'id':2,'created':20,'updated':20,'node':node(2,event='')},{'id':3,'created':10,'updated':10,'node':node(3,queued=True,kind='AddedToMergeQueueEvent')}]
    def hook(row):
        if row['kind']!='sweep' or row['repository']!=repo:return
        field='created' if row['order_by']=='CREATED_AT' else 'updated'
        ordered=sorted(items,key=lambda x:x[field],reverse=True)
        if row['cursor'] is None:
            first=ordered[0]
            FIXTURE['pages'][repo,None]=([first['node']],True,f"after-{first['id']}")
            # A GitHub update after page 1 moves this PR only under UPDATED_AT.
            items[1]['updated']=30
            items[1]['node']=node(3,reason='failed_checks')
        else:
            previous=int(row['cursor'].split('-')[1])
            index=next(i for i,x in enumerate(ordered) if x['id']==previous)
            FIXTURE['pages'][repo,row['cursor']]=([x['node'] for x in ordered[index+1:]],False,None)
    FIXTURE['hook']=hook
    out=lab.cycle('later-page PR drops and receives update after first cursor').stdout
    assert f'dequeued https://github.com/{repo}/pull/3 reason=failed_checks' in out,out
    assert not (lab.state/'task-a.pr-poll').exists()
    lab.drain('updated later-page removal delivered before last-watch retirement')
    return 'A real two-page scan retains immutable creation ordering when a later-page PR updates and drops after page 1, delivers its removal, and only then retires the merged last watch.'

def interrupted_receipts(lab):
    for stage in ['full','registration','sidecar']:
        repo=f'acme/crash-{stage}';ident=f'task-{stage}'
        lab.arm(ident,repo,1)
        env=dict(lab.env,LAB_ID=ident)
        run(['bash',WORK/'publish-retirement.sh'],env)
        receipt=lab.state/f'{ident}.pr-poll-retirement'
        registration=lab.state/f'{ident}.pr-poll-registration'
        check=lab.state/f'{ident}.check.sh'
        if stage in ['registration','sidecar']:check.unlink()
        if stage=='sidecar':registration.unlink()
        reg_hash=None
        if registration.exists():
            lines=registration.read_text().splitlines()
            for n in [9,10]:
                dev,inode=lines[n].split(':');lines[n]=f'{int(dev)+1}:{inode}'
            registration.write_text('\n'.join(lines)+'\n')
            reg_hash=hashlib.sha256(registration.read_bytes()).hexdigest()
        lines=receipt.read_text().splitlines()
        for n in [9,10,12]:
            dev,inode=lines[n].split(':');lines[n]=f'{int(dev)+1}:{inode}'
        if reg_hash:lines[11]=reg_hash
        receipt.write_text('\n'.join(lines)+'\n')
        FIXTURE['pages'][repo,None]=([node(2,event=f'crash-{stage}-removal-2')],False,None)
        lab.log.append(f'Setup {stage}: sidecar and receipt remain on their original inodes; surviving registration/check recorded devices are renumbered.\n')
        out=lab.cycle(f'restart from {stage} interrupted-retirement artifacts').stdout
        assert f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks' in out,out
        for suffix in ['pr-poll','check.sh','pr-poll-registration','pr-poll-retirement']:
            assert not (lab.state/f'{ident}.{suffix}').exists(),suffix
        lab.drain(f'{stage}: removal delivered and exact artifacts retired')
    return 'Restarts with full, registration-only, and sidecar-only interrupted retirement artifacts accept unchanged inodes after recorded-device renumber, deliver the unarmed drop, and remove only those exact artifacts.'

def unreadable_seen(lab):
    for fault in ['unreadable','unsafe','lookup']:
        repo=f'acme/seen-{fault}';ident=f'task-{fault}'
        lab.arm(ident,repo,1)
        FIXTURE['polls'][repo,1]=node(1,state='MERGED',reason='merged')
        FIXTURE['pages'][repo,None]=([node(2,event=f'removal-{fault}-2')],False,None)
        seen=lab.state/'merge-queue-sweep.seen'
        seen.write_text('fm-merge-queue-sweep-v1\n')
        seen.chmod(0o000 if fault=='unreadable' else 0o644 if fault=='unsafe' else 0o600)
        def hook(row):
            if fault=='lookup' and row['kind']=='sweep' and row['repository']==repo:
                seen.write_text('malformed after scan starts\n')
        FIXTURE['hook']=hook
        start=len(REQUESTS)
        out=lab.cycle(f'{fault} deduplication record while last armed PR merges').stdout
        assert f'dequeued https://github.com/{repo}/pull/2 ' not in out,out
        assert (lab.state/f'{ident}.pr-poll').exists() and (lab.state/f'{ident}.pr-poll-retirement').exists()
        if fault!='lookup': assert not any(r['kind']=='sweep' and r['repository']==repo for r in REQUESTS[start:])
        lab.drain(f'{fault}: merge delivered while discovery survives')
        seen.chmod(0o600);seen.write_text('fm-merge-queue-sweep-v1\n');FIXTURE['hook']=None
        out=lab.cycle(f'{fault}: next successful scan reads and publishes removal').stdout
        assert out.count(f'dequeued https://github.com/{repo}/pull/2 reason=failed_checks')==1,out
        assert not (lab.state/f'{ident}.pr-poll').exists()
        lab.drain(f'{fault}: recovered removal delivered')
    return 'Unreadable/unsafe seen records and a deduplication lookup corrupted after the scan begins all preserve the last-watch sidecar; every next successful scan delivers its removal before retirement.'

(WORK/'arm.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
. "$PWD/bin/fm-pr-lib.sh"
fm_pr_poll_prepare "$FM_HOME/state" "$LAB_ID" "$LAB_PROVIDER" "$LAB_URL" "$LAB_HOST" "$LAB_REPO" "$LAB_NUMBER" "$LAB_TEMPLATE"
fm_pr_poll_publish_prepared
''')
(WORK/'publish-retirement.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
. "$PWD/bin/fm-pr-lib.sh"
fm_pr_poll_snapshot_capture "$FM_HOME/state" "$LAB_ID" "$PWD/bin/fm-pr-poll.sh"
fm_pr_poll_retirement_publish "$FM_HOME/state" "$LAB_ID" "$PWD/bin/fm-pr-poll.sh" merged
''')
config=WORK/'openssl.cnf'
config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Firstmate disposable API replay\n[ext]\nsubjectAltName=DNS:api.github.com,DNS:gitlab.com\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyCertSign,keyEncipherment\n')
run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,'-keyout',WORK/'replay-key.pem','-out',WORK/'replay-cert.pem'])
TLS=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
TLS.load_cert_chain(WORK/'replay-cert.pem',WORK/'replay-key.pem')
server=Server(('127.0.0.1',0),Proxy)
PROXY=f'http://127.0.0.1:{server.server_port}'
thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
try:
    selected=os.environ.get('LIVE_ONLY')
    if selected:
        RESULTS.extend(r for r in json.loads((EVIDENCE/'live-results.json').read_text()) if r['name'] not in selected.split(','))
        REQUESTS.extend(json.loads((EVIDENCE/'live-api-requests.json').read_text()))
    for name, fn in [('historical-replay',replay),('numeric-identities',numeric),('interpage-retirement',queued_sighting),('failed-page-retry',failed_pages),('seen-record-recovery',seen_failure),('mixed-repositories',mixed_repositories),('template-device-recovery',template_recovery),('baseline-comparison',baseline_comparison),('lifecycle-boundary',lifecycle),('force-closed-cleanup',forced_cleanup),('retained-device-renumber',retained_renumber),('slow-checks-rearm',slow_checks),('long-sweep-pages',long_sweep),('reason-preservation',reason_preservation),('later-gitlab-watch',gitlab_continuity),('immutable-pagination',immutable_cursor),('interrupted-retirement-artifacts',interrupted_receipts),('unreadable-seen-recovery',unreadable_seen)]:
        if selected and name not in selected.split(','):continue
        scenario(name, fn)
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=5)
    save('live-api-requests.json',json.dumps(REQUESTS,indent=2)+'\n')
raise SystemExit(any(r['result']=='fail' for r in RESULTS))
