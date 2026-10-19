#!/usr/bin/env python3
"""Live public-CLI validation; only disposable lab data and a loopback sign-in service."""
import contextlib
import hashlib
import http.cookiejar
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path.cwd()
EVIDENCE = Path('/Users/dalecarman/.no-mistakes/evidence/01M5988E2EDNGT1XV34F05X546')
SCRATCH = ROOT / '.agent-state' / 'holdprobe-validation-tmp'
LAB = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=SCRATCH))
RULE = '/Users/dalecarman/.agent-config/configs/claude/hooks/dale-asks-rule.py'
DOMAIN = '/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py'
REVIEW = '/Users/dalecarman/.agent-config/tools-bin/review-page'
BASE = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL', 'NO_MISTAKES_GATE') if key in os.environ}
BASE.update(HOME=str(LAB / 'hosthome'), TMPDIR=str(SCRATCH), PYTHONDONTWRITEBYTECODE='1',
            XDG_CACHE_HOME=str(LAB / 'cache'), XDG_STATE_HOME=str(LAB / 'xdg-state'),
            XDG_CONFIG_HOME=str(LAB / 'xdg-config'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
            REVIEW_PAGE_HOME=str(LAB / 'review-pages'), DALE_RECORDS_DIR=str(LAB / 'dale-records'),
            REVIEW_PAGE_DOWNLOADS=str(LAB / 'downloads'), REVIEW_PAGE_NO_OPEN='1', REVIEW_PAGE_NO_NUDGE='1',
            FM_DALE_ASKS_RULE=RULE, HOLD_DOMAIN_SPOOL=str(LAB / 'domain-spool'),
            HOLD_DOMAIN_STATE=str(LAB / 'domain-routed.tsv'))
for p in ('hosthome', 'review-pages', 'dale-records', 'downloads'):
    (LAB / p).mkdir()
TRANSCRIPT = (EVIDENCE / 'holdprobe-live-cli.log').open('w')
RESULTS = []

def log(text):
    TRANSCRIPT.write(str(text) + '\n')
    TRANSCRIPT.flush()
    print(text, flush=True)

def run(argv, home=None, extra=None, expected=0, input=None, quiet=False):
    env = dict(BASE)
    if home:
        env['FM_HOME'] = str(home)
    env.update(extra or {})
    log('$ ' + shlex.join([str(a) for a in argv]))
    p = subprocess.run([str(a) for a in argv], cwd=ROOT, env=env, input=input,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    if not quiet:
        if p.stdout:
            log(p.stdout.rstrip())
        if p.stderr:
            log('stderr: ' + p.stderr.rstrip())
    log('exit: ' + str(p.returncode))
    if expected is not None:
        assert p.returncode == expected, (argv, p.returncode, p.stdout, p.stderr)
    return p

def new_home(name, parent=None):
    home = LAB / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', home])
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    if parent:
        (home / '.fm-secondmate-home').write_text(name + '\n')
        (home / '.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home=' + str(parent) + '\n')
    return home

def hold(home, task, *, title='Local service sign-in', reason='Complete your local service sign-in', step='sign-in', probe=None, extra=None, expected=0):
    argv = [ROOT / 'bin/fm-captain-hold.sh', 'hold', task, '--reason', reason]
    if title is not None:
        argv.extend(['--title', title])
    if step:
        argv.extend(['--dale-step', step, '--probe', probe or str(LAB / 'session-probe.py')])
    return run(argv, home, extra, expected=expected)

def reprobe(home, task, expected=0):
    return run([ROOT / 'bin/fm-captain-hold.sh', 'reprobe', task], home, expected=expected)

def show(home, task):
    out = run([ROOT / 'bin/fm-tasks-axi.sh', 'show', task, '--full'], home).stdout
    fields = {}
    for line in out.splitlines():
        m = re.fullmatch(r'\s*([a-z_]+):\s*(.*)', line)
        if m:
            value = m[2]
            if value.startswith('"'):
                value = json.loads(value)
            fields[m[1]] = value
    assert 'held' in fields and 'body' in fields, out
    return fields

def channel(parent, name):
    p = parent / 'state' / (name + '.status')
    return p.read_bytes() if p.exists() else b''

def scenario(name, fn):
    log('\nSCENARIO: ' + name)
    try:
        fn()
    except Exception as e:
        log('FAIL: ' + repr(e))
        RESULTS.append(dict(name=name, result='fail', live=True, evidence='holdprobe-live-cli.log', reason=repr(e)))
    else:
        log('PASS: ' + name)
        RESULTS.append(dict(name=name, result='pass', live=True, evidence='holdprobe-live-cli.log', reason=''))
    (EVIDENCE / 'holdprobe-live-results.json').write_text(json.dumps(RESULTS, indent=2) + '\n')

SESSION = secrets.token_urlsafe(24)
SERVICE = dict(signed_in=False, screen=False)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def respond(self, code, obj, cookie=False):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        if cookie:
            self.send_header('Set-Cookie', 'session=' + SESSION + '; HttpOnly; Path=/')
        self.end_headers()
        self.wfile.write(json.dumps(obj).encode())
    def do_GET(self):
        if self.path == '/session':
            okay = SERVICE['signed_in'] and self.headers.get('Cookie') == 'session=' + SESSION
            return self.respond(200 if okay else 401, {'authenticated': okay})
        if self.path == '/screen':
            return self.respond(200 if SERVICE['screen'] else 409, {'approved': SERVICE['screen']})
        self.respond(404, {})
    def do_POST(self):
        if self.path == '/login':
            SERVICE['signed_in'] = True
            return self.respond(200, {'signedIn': True}, cookie=True)
        if self.path == '/screen/approve':
            SERVICE['screen'] = True
            return self.respond(200, {'approved': True})
        self.respond(404, {})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
URL = 'http://127.0.0.1:' + str(server.server_port)
JAR = LAB / 'session.cookies'
PROBE = LAB / 'session-probe.py'
PROBE.write_text('#!' + sys.executable + '\nimport http.cookiejar,sys,urllib.request\njar=http.cookiejar.MozillaCookieJar(' + repr(str(JAR)) + ')\ntry:\n jar.load(ignore_discard=True)\n urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar)).open(' + repr(URL + '/session') + ',timeout=5)\nexcept Exception:\n sys.exit(1)\n')
PROBE.chmod(0o700)
SCREEN_PROBE = LAB / 'screen-probe.py'
SCREEN_PROBE.write_text('#!' + sys.executable + '\nimport sys,urllib.request\ntry:\n urllib.request.urlopen(' + repr(URL + '/screen') + ',timeout=5)\nexcept Exception:\n sys.exit(1)\n')
SCREEN_PROBE.chmod(0o700)

def request_service(path, method='GET'):
    jar = http.cookiejar.MozillaCookieJar(str(JAR))
    if JAR.exists():
        jar.load(ignore_discard=True)
    client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    try:
        response = client.open(urllib.request.Request(URL + path, method=method), timeout=5)
        code, data = response.status, json.load(response)
    except urllib.error.HTTPError as error:
        code, data = error.code, json.load(error)
    jar.save(ignore_discard=True)
    JAR.chmod(0o600)
    log(method + ' ' + path + ' -> ' + str(code) + ' ' + json.dumps(data))
    return code, data

parent = new_home('parent')
home = new_home('holds', parent)

def fields_and_sign_in():
    assert request_service('/session')[0] == 401
    hold(home, 'signin')
    row = show(home, 'signin')
    assert row['held'] == 'yes'
    body = row['body']
    lines = body.splitlines()
    assert re.fullmatch(r'Captain hold set: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', lines[0])
    assert lines[1:5] == ['Decision owner: dale', 'Hold timeout seconds: 3600',
                         'Hold reason: Complete your local service sign-in', 'Hold probe: ' + str(PROBE)]
    emitted = EVIDENCE / 'signin-hold-body.txt'
    emitted.write_text(body + '\n')
    consumer = run([sys.executable, DOMAIN, 'route', '--task', 'signin', '--body-file', emitted])
    assert consumer.stdout.strip() == 'kept', consumer.stdout
    log('The real hold-domain consumer accepted the emitted default fields.')
    before = channel(parent, 'holds')
    assert reprobe(home, 'signin').stdout.strip() == 'kept: signin probe-failed'
    assert show(home, 'signin')['held'] == 'yes'
    assert channel(parent, 'holds') == before
    log('Failed sign-in probe: parent channel byte-identical; no wake generated.')
    assert request_service('/login', 'POST')[1]['signedIn']
    assert request_service('/session')[1]['authenticated']
    assert reprobe(home, 'signin').stdout.strip() == 'released: signin'
    row = show(home, 'signin')
    assert row['held'] == 'no' and row['state'] != 'done'
    assert 'Resolution mode: probe-released' in row['body']
    assert 'Reconciliation evidence:' in row['body'] and 'Captain decision:' not in row['body']
    after = channel(parent, 'holds')
    assert after.count(b'resolved [key=captain-hold-signin-1]') == 1
    assert reprobe(home, 'signin').stdout.strip() == 'released: signin'
    assert channel(parent, 'holds') == after
    assert show(home, 'signin')['body'].count('Resolution recorded by fm-captain-hold.') == 1
    (EVIDENCE / 'signin-parent-channel.log').write_bytes(after)


def screen():
    assert request_service('/screen')[0] == 409
    hold(home, 'screen', step='screen', probe=str(SCREEN_PROBE), title='Local consent screen', reason='Complete your local consent screen')
    row = show(home, 'screen')
    assert row['held'] == 'yes' and 'Hold probe: ' + str(SCREEN_PROBE) in row['body']
    before = channel(parent, 'holds')
    assert reprobe(home, 'screen').stdout.strip() == 'kept: screen probe-failed'
    assert channel(parent, 'holds') == before
    assert request_service('/screen/approve', 'POST')[1]['approved']
    assert reprobe(home, 'screen').stdout.strip() == 'released: screen'
    assert show(home, 'screen')['held'] == 'no'


def unknown_probe():
    hold(home, 'unknown', probe='fm-holdprobe-command-does-not-exist')
    before = channel(parent, 'holds')
    assert reprobe(home, 'unknown').stdout.strip() == 'kept: unknown probe-failed'
    row = show(home, 'unknown')
    assert row['held'] == 'yes' and 'Resolution mode:' not in row['body']
    assert channel(parent, 'holds') == before
    log('Unknown probe: parent channel byte-identical; no wake generated.')


def ordinary_hold():
    reason = 'Choose the next action (two choices)\nKeep the details as entered'
    hold(home, 'ordinary', step=None, reason=reason, title='Ordinary captain choice')
    row = show(home, 'ordinary')
    assert row['held'] == 'yes'
    for key in ('Decision owner:', 'Hold timeout seconds:', 'Hold reason:', 'Hold probe:'):
        assert key not in row['body']
    before = channel(parent, 'holds')
    assert reprobe(home, 'ordinary').stdout.strip() == 'kept: ordinary no-probe'
    assert channel(parent, 'holds') == before
    assert show(home, 'ordinary')['held'] == 'yes'


def changed_stamp():
    race = LAB / 'race-probe.py'
    race.write_text('#!' + sys.executable + '\nimport subprocess\nsubprocess.run([' + repr(str(ROOT / 'bin/fm-tasks-axi.sh')) + ',"unhold","race"],check=True,stdout=subprocess.DEVNULL)\nsubprocess.run([' + repr(str(ROOT / 'bin/fm-captain-hold.sh')) + ',"hold","race","--reason","New screen request","--dale-step","screen","--probe",' + repr(str(SCREEN_PROBE)) + '],check=True,stdout=subprocess.DEVNULL,env={**__import__("os").environ,"FM_CAPTAIN_HOLD_NOW":"2026-10-19T23:00:00Z"})\n')
    race.chmod(0o700)
    hold(home, 'race', probe=str(race), extra={'FM_CAPTAIN_HOLD_NOW':'2026-10-19T12:00:00Z'})
    assert reprobe(home, 'race').stdout.strip() == 'kept: race stamp-changed'
    row = show(home, 'race')
    assert row['held'] == 'yes' and row['body'].startswith('Captain hold set: 2026-10-19T23:00:00Z\n')
    assert 'Resolution mode:' not in row['body']


def changed_probe():
    race = LAB / 'probe-change.py'
    race.write_text('#!' + sys.executable + '\nimport subprocess\nsubprocess.run([' + repr(str(ROOT / 'bin/fm-captain-hold.sh')) + ',"hold","probe-change","--reason","Updated screen request","--dale-step","screen","--probe","fm-holdprobe-command-does-not-exist"],check=True,stdout=subprocess.DEVNULL)\n')
    race.chmod(0o700)
    hold(home, 'probe-change', probe=str(race))
    assert reprobe(home, 'probe-change').stdout.strip() == 'kept: probe-change stamp-changed'
    row = show(home, 'probe-change')
    assert row['held'] == 'yes' and 'Hold probe: fm-holdprobe-command-does-not-exist' in row['body']
    assert 'Resolution mode:' not in row['body']


def world_checks():
    world = LAB / 'world'
    world.mkdir()
    pages = world / 'pages'
    records = world / 'records'
    records.mkdir()
    extra = {'REVIEW_PAGE_HOME':str(pages), 'DALE_RECORDS_DIR':str(records)}
    q = 'Use your Helios account for the [local service](' + URL + '/)?'
    item = {'id':'signin', 'title':'Helios access', 'ask':q, 'recommend':q, 'text':q, 'if_no':q}
    content = {'page':'lab-signin', 'title':'Local sign-in test', 'project':'Hold probe lab', 'owner':'lab-owner',
               'chapters':[{'title':'Local sign-in', 'items':[item]}]}
    source = world / 'review.json'
    source.write_text(json.dumps(content))
    run([sys.executable, REVIEW, 'update', source, '--no-open'], extra=extra)
    def rule():
        return run([sys.executable, RULE, 'ask', '--title', item['title'], '--question', q,
                    '--recommend', q, '--text', q, '--if-no', q], extra=extra, expected=3)
    first = rule()
    assert any(line.startswith('review:') and ' asks the same decision and came first' in line for line in first.stdout.splitlines())
    for step in ('sign-in', 'screen'):
        for existing in (False, True):
            task = 'duplicate-' + step + ('-existing' if existing else '')
            if existing:
                run([ROOT / 'bin/fm-tasks-axi.sh', 'add', task, item['title']], home)
            before = (home / 'data/backlog.md').read_bytes()
            refused = hold(home, task, title=item['title'], reason=q, step=step, extra=extra, expected=1)
            assert 'owner: dale' in refused.stderr and 'asks the same decision and came first' in refused.stderr
            assert (home / 'data/backlog.md').read_bytes() == before
    page_state = json.loads((pages / 'lab-signin/state.json').read_text())
    seen = page_state['items']['signin']['hash']
    run([sys.executable, REVIEW, 'answer', 'lab-signin', 'signin', 'reply', '--seen', seen], extra=extra, input='Already signed in to the local test service.\n')
    decided = rule()
    assert 'He decided it on review:lab-signin#signin.' in decided.stdout
    for step in ('sign-in', 'screen'):
        before = (home / 'data/backlog.md').read_bytes()
        refused = hold(home, 'answered-' + step, title=item['title'], reason=q, step=step, extra=extra, expected=1)
        assert 'owner: dale' in refused.stderr and 'He decided it on review:lab-signin#signin.' in refused.stderr
        assert (home / 'data/backlog.md').read_bytes() == before
    # Ordinary holds still bypass the Dale-only creation guard.
    hold(home, 'ordinary-answered', title=item['title'], reason=q, step=None, extra=extra)
    assert show(home, 'ordinary-answered')['held'] == 'yes'
    # Invalid category and form must remain nonblocking.
    for step in ('sign-in', 'screen'):
        hold(home, 'noncategory-' + step, title='Local work', reason='Choose a local branch', step=step, extra=extra)
        assert show(home, 'noncategory-' + step)['held'] == 'yes'
        hold(home, 'form-' + step, title='Account sign-in', reason='Complete your sign-in', step=step, extra=extra)
        assert show(home, 'form-' + step)['held'] == 'yes'
        missing = {**extra, 'FM_DALE_ASKS_RULE':str(world / 'absent-rule.py')}
        hold(home, 'missing-rule-' + step, title='Account sign-in', step=step, extra=missing)
        assert show(home, 'missing-rule-' + step)['held'] == 'yes'
        broken = world / 'broken-rule.py'
        broken.write_text('raise RuntimeError("Disposable broken rule dependency")\n')
        hold(home, 'broken-rule-' + step, title='Account sign-in', step=step, extra={**extra, 'FM_DALE_ASKS_RULE':str(broken)})
        assert show(home, 'broken-rule-' + step)['held'] == 'yes'

try:
    scenario('Dale sign-in fields are consumer-compatible; failed probe stays quiet; completed sign-in releases once', fields_and_sign_in)
    scenario('A pending screen remains held until the screen is completed', screen)
    scenario('An unknown probe remains held and emits no parent wake', unknown_probe)
    scenario('An ordinary hold keeps its existing text behavior and has no automatic probe', ordinary_hold)
    scenario('A successful old probe cannot release a replacement hold with a different stamp', changed_stamp)
    scenario('A successful old probe cannot release a hold whose probe changed', changed_probe)
    scenario('The actual asks-rule blocks duplicate and answered asks while kind, form and unavailable rules fail open', world_checks)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
    log('Local sign-in service stopped. Disposable lab path: ' + str(LAB))
    (EVIDENCE / 'holdprobe-lab-path.txt').write_text(str(LAB) + '\n')
    TRANSCRIPT.close()

sys.exit(1 if any(row['result'] == 'fail' for row in RESULTS) else 0)
