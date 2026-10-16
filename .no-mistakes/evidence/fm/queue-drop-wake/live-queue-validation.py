#!/usr/bin/env python3
"""Drive the real watcher and gh against a disposable local GitHub API dataset.

The gh launcher only redirects the API endpoint to loopback. Real gh still
converts fields, makes HTTP requests, processes errors and evaluates --jq.
No Firstmate program or poll template is copied, replaced or mocked.
"""
import copy
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = Path.cwd()
OUT = Path('/Users/dalecarman/.no-mistakes/evidence/01M52M4YB15FC8H82PA7T22SFS')
LAB = ROOT / '.queue-live-lab'
REAL_GH = shutil.which('gh')
assert REAL_GH
BASE = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'GH_', 'GITHUB_', 'TASKS_AXI_')) and k not in ('TMUX', 'TMUX_PANE')}
BASE.update(GH_TOKEN='disposable-fixture-token', GH_NO_UPDATE_NOTIFIER='1', GH_NO_EXTENSION_UPDATE_NOTIFIER='1', GH_TELEMETRY='false', GH_PROMPT_DISABLED='1')
REQUESTS = []
RESULTS = []
CURRENT = None

def node(n, event=None, reason='failed_checks', queued=False, state='OPEN', kind='RemovedFromMergeQueueEvent'):
    events = [] if event is None else [dict(__typename=kind, id=event, reason=reason)]
    return dict(number=n, state=state, merged=state == 'MERGED', isInMergeQueue=queued, timelineItems=dict(nodes=events))

class Dataset:
    def __init__(self, name, pages, polls=None):
        self.name, self.pages, self.polls = name, pages, polls or {}
        self.cycle = 0
        self.fail_page = None
        self.slow_page = None
        self.on_page_two = None
        self.errors = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        query = request['query']
        fields = request.get('variables', request)
        sweep = 'pullRequests(' in query
        page = 1 if fields.get('cursor') is None else 2
        row = dict(scenario=CURRENT.name, cycle=CURRENT.cycle, kind='sweep' if sweep else 'poll', page=page, variables={k:v for k,v in fields.items() if k != 'query'})
        REQUESTS.append(row)
        if not isinstance(fields.get('owner'), str) or not isinstance(fields.get('repo'), str):
            CURRENT.errors.append('owner/repo was not a string')
            return self.respond(422, {'errors':[{'message':'owner/repo must be String!'}]})
        if sweep:
            if page == CURRENT.slow_page:
                time.sleep(3)
            if page == CURRENT.fail_page:
                return self.respond(503, {'message':'disposable endpoint page unavailable'})
            if page == 2 and CURRENT.on_page_two:
                CURRENT.on_page_two()
            rows = copy.deepcopy(CURRENT.pages[page-1])
            more = page < len(CURRENT.pages)
            row.update(queued=[n['number'] for n in rows if n['isInMergeQueue']], returned=[n['number'] for n in rows])
            data = {'data':{'repository':{'pullRequests':{'nodes':rows,'pageInfo':{'hasNextPage':more,'endCursor':'page2' if more else None}}}}}
        else:
            if not isinstance(fields.get('number'), int):
                CURRENT.errors.append('PR number was not an integer')
                return self.respond(422, {'errors':[{'message':'number must be Int!'}]})
            if getattr(CURRENT, 'on_poll', None):
                CURRENT.on_poll(fields['number'])
            data = {'data':{'repository':{'pullRequest':copy.deepcopy(CURRENT.polls[fields['number']])}}}
        self.respond(200, data)

    def respond(self, code, data):
        body = json.dumps(data).encode()
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass

SERVER = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
(LAB / 'bin').mkdir(parents=True, exist_ok=True)
LAUNCHER = LAB / 'bin/gh'
LAUNCHER.write_text(f'''#!{sys.executable}
import os,sys
args=sys.argv[1:]
if len(args)<2 or args[:2]!=['api','graphql']:
    sys.stderr.write('Lab launcher refuses all requests except the product GraphQL API.\\n')
    sys.exit(98)
args[1]='http://127.0.0.1:{SERVER.server_port}/graphql'
os.execv({REAL_GH!r},[{REAL_GH!r}]+args)
''')
LAUNCHER.chmod(0o700)

def call(args, env, timeout=60):
    p = subprocess.Popen([str(a) for a in args], env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        stdout, stderr = p.communicate(timeout=10)
        raise AssertionError(f'Product command exceeded {timeout}s: {args}\n{stdout}\n{stderr}')
    if p.returncode:
        raise AssertionError(f'Product command exited {p.returncode}: {args}\n{stdout}\n{stderr}')
    return stdout, stderr

def setup(data, watches):
    global CURRENT
    CURRENT = data
    directory = OUT / data.name
    directory.mkdir(exist_ok=True)
    home = LAB / data.name
    home.mkdir(mode=0o700)
    env = dict(BASE, FM_HOME=str(home), FM_BACKEND='tmux', FM_POLL='0.05', FM_CHECK_INTERVAL='0', FM_SIGNAL_GRACE='0', FM_HEARTBEAT='999999', GH_CONFIG_DIR=str(home/'gh-config'), PATH=str(LAB/'bin')+os.pathsep+os.environ['PATH'], TMUX_TMPDIR=str(home/'tmux'))
    call([ROOT/'bin/fm-lab-home.sh', 'create', home], env)
    (home/'gh-config').mkdir()
    (home/'tmux').mkdir()
    for ident, repo, number in watches:
        url = f'https://github.com/{repo}/pull/{number}'
        meta = home/'state'/f'{ident}.meta'
        meta.write_text(f'pr={url}\n')
        meta.chmod(0o600)
        call(['bash', OUT/'seed-watch.sh', ROOT, home, ident, url], env)
    stop = home/'state/z-lab-cycle.check.sh'
    stop.write_text('#!/usr/bin/env bash\nprintf "lab cycle complete\\n"\n')
    stop.chmod(0o700)
    call([ROOT/'bin/fm-check-register.sh', 'z-lab-cycle'], env)
    return home, env, directory

def cycle(data, context, acknowledge=True, timeout=60, per_check_timeout=None):
    home, env, directory = context
    data.cycle += 1
    if per_check_timeout is not None:
        env = dict(env, FM_CHECK_TIMEOUT=str(per_check_timeout))
    stdout, stderr = call([ROOT/'bin/fm-watch.sh'], env, timeout)
    (directory/f'cycle-{data.cycle}-watch.txt').write_text(stdout+stderr)
    drain, err = call([ROOT/'bin/fm-wake-drain.sh'], env)
    (directory/f'cycle-{data.cycle}-drain.txt').write_text(drain+err)
    snapshot = {'cycle':data.cycle,'watched_repositories':call([ROOT/'bin/fm-pr-queue-sweep.sh','--repos',home/'state'],env)[0].splitlines(), 'poll_artifacts':sorted(p.name for p in (home/'state').glob('*.pr-poll*')), 'notifications':[line for line in drain.splitlines() if 'dequeued https://' in line]}
    (directory/f'cycle-{data.cycle}-state.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    print(data.name, 'cycle',data.cycle, json.dumps(snapshot),flush=True)
    if acknowledge:
        ack = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', err)
        assert ack, f'No acknowledgement contract: {err}'
        call([ROOT/'bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]],env)
    return drain, snapshot

def once(drain, repo, number, reason):
    needle=f'dequeued https://github.com/{repo}/pull/{number} reason={reason}'
    assert drain.count(needle)==1, f'Expected exactly one {needle}: {drain}'

def finish(data, name):
    assert not data.errors, data.errors
    (OUT/data.name/'api-requests.json').write_text(json.dumps([r for r in REQUESTS if r['scenario']==data.name],indent=2)+'\n')
    RESULTS.append({'name':name,'result':'pass','live':True,'evidence':str(OUT/data.name)})

if __name__ == "__main__":
    try:
        # Replay the actual incident removals at their historical open/nonqueued state.
        history=json.loads((OUT/'github-history.json').read_text())['data']['repository']
        replay=[]
        for source in history.values():
            removed=[e for e in source['timelineItems']['nodes'] if e['__typename']=='RemovedFromMergeQueueEvent' and e.get('reason')!='merged']
            event=removed[-1]
            if source['number']==4308:
                event=next(e for e in removed if e['createdAt']=='2026-10-14T02:32:46Z')
            replay.append(node(source['number'],event['id'],event['reason']))
        data=Dataset('historical-replay',[replay[:6],replay[6:]+[node(9001,'readded',queued=False,kind='AddedToMergeQueueEvent'),node(9002,'merge-only',reason='merged')]],{4308:next(n for n in replay if n['number']==4308)})
        ctx=setup(data,[('task-a','groovejones/groove-sight-platform',4308)])
        first,state=cycle(data,ctx,acknowledge=False)
        for pr in replay:
            once(first,'groovejones/groove-sight-platform',pr['number'],pr['timelineItems']['nodes'][0]['reason'])
        assert '/pull/9001' not in first and '/pull/9002' not in first
        # Redrain without acknowledging: every pending notification remains durable.
        again,err=call([ROOT/'bin/fm-wake-drain.sh'],ctx[1])
        (ctx[2]/'unacknowledged-redrain.txt').write_text(again+err)
        for pr in replay:
            once(again,'groovejones/groove-sight-platform',pr['number'],pr['timelineItems']['nodes'][0]['reason'])
        ack=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',err)
        call([ROOT/'bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]],ctx[1])
        again,_=cycle(data,ctx)
        assert 'dequeued https://' not in again
        data.polls[4308]=node(4308,'later-drop',reason='manual')
        data.pages[0]=[n for n in data.pages[0] if n['number']!=4308]+[data.polls[4308]]
        again,_=cycle(data,ctx)
        once(again,'groovejones/groove-sight-platform',4308,'manual')
        finish(data,'Actual #4308 and nine stranded PR removal histories wake once, survive an interrupted drain, and allow a later removal')

        data=Dataset('interpage-retirement',[[node(9,'queued-nine',queued=True,kind='AddedToMergeQueueEvent')],[node(10)]],{1:node(1,state='MERGED')})
        data.on_page_two=lambda: data.pages[0].__setitem__(0,node(9,'drop-nine',reason='manual removal'))
        ctx=setup(data,[('task-a','o/r',1)])
        first,state=cycle(data,ctx)
        assert '/pull/9' not in first and state['watched_repositories']==['o/r']
        assert 'task-a.pr-poll' in state['poll_artifacts'] and 'task-a.pr-poll-retirement' in state['poll_artifacts']
        assert [r['page'] for r in REQUESTS if r['scenario']==data.name and r['cycle']==1 and r['kind']=='sweep']==[1,2]
        second,state=cycle(data,ctx)
        once(second,'o/r',9,'manual removal')
        assert state['watched_repositories']==[]
        assert not any(name in state['poll_artifacts'] for name in ('task-a.pr-poll','task-a.pr-poll-retirement','task-a.pr-poll-registration'))
        third,_=cycle(data,ctx)
        assert 'dequeued https://' not in third
        finish(data,'A queued sighting retains the last merged watch across restart; the next sweep reports the inter-page removal once and retires it')

        data=Dataset('numeric-identities',[[node(7,'drop-seven')],[node(8,'drop-eight',reason='manual')]],{7:node(7,'drop-seven')})
        ctx=setup(data,[('task-a','123/123',7)])
        first,state=cycle(data,ctx)
        once(first,'123/123',7,'failed_checks');once(first,'123/123',8,'manual')
        assert len([r for r in REQUESTS if r['scenario']==data.name and r['kind']=='sweep'])==2
        finish(data,'Numeric owner and repository identities stay strings in the real gh CLI for armed polling and both sweep pages')

        for fault in ('page-error','page-timeout','malformed-seen'):
            data=Dataset(fault,[[node(9,'pending-drop')],[node(10)]],{1:node(1,state='MERGED'),2:node(2)})
            ctx=setup(data,[('task-a','o/r',1),('task-b','other/repo',2)])
            if fault=='page-error': data.fail_page=2
            if fault=='page-timeout': data.slow_page=2
            seen=ctx[0]/'state/merge-queue-sweep.seen'
            if fault=='malformed-seen':
                seen.write_text('invalid record\n');seen.chmod(0o600)
            first,state=cycle(data,ctx,per_check_timeout=1 if fault=='page-timeout' else 30)
            assert '/pull/9' not in first
            assert 'o/r' in state['watched_repositories'] and 'task-a.pr-poll-retirement' in state['poll_artifacts']
            assert any(r['kind']=='poll' and r['variables'].get('number')==2 for r in REQUESTS if r['scenario']==data.name and r['cycle']==1), 'Later independent watch did not poll'
            data.fail_page=None;data.slow_page=None
            if fault=='malformed-seen':
                seen.write_text('fm-merge-queue-sweep-v1\n');seen.chmod(0o600)
            second,state=cycle(data,ctx)
            once(second,'o/r',9,'failed_checks')
            assert 'o/r' not in state['watched_repositories'] and 'task-a.pr-poll-retirement' not in state['poll_artifacts']
            finish(data,f'{fault}: a failed scan retains discovery, a later independent watch still polls, and retry reports the removal')
    finally:
        SERVER.shutdown();SERVER.server_close()
        (OUT/'live-scenarios.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
        (OUT/'live-api-requests.json').write_text(json.dumps(REQUESTS,indent=2)+'\n')
