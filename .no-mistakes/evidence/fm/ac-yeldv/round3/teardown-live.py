from pathlib import Path
import http.server
import json
import os
import socketserver
import subprocess
import threading
import time

root = Path.cwd()
scratch = root / '.nm-live-yeldv-r3'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round3')
fixture = json.loads((evidence / 'fixture.json').read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'GH_', 'GITHUB_'))}
env.update(json.loads((evidence / 'env.json').read_text()))
lab = scratch / 'teardown-home'
subprocess.run(['bin/fm-lab-home.sh', 'create', str(lab)], env=env, check=True, stdout=subprocess.DEVNULL)
env['FM_HOME'] = str(lab)
gh_config = scratch / 'teardown-gh-config'
gh_config.mkdir()
api_socket = evidence / 'forge-api.sock'
(gh_config / 'config.yml').write_text('http_unix_socket: ' + str(api_socket) + '\n')
env.update(GH_CONFIG_DIR=str(gh_config), GH_TOKEN='disposable-local-fixture', HTTPS_PROXY='http://127.0.0.1:1', HTTP_PROXY='http://127.0.0.1:1', NO_PROXY='', GH_NO_UPDATE_NOTIFIER='1', GH_TELEMETRY='0', GH_PROMPT_DISABLED='1')
slot = scratch / 'teardown-slot'
subprocess.run(['git', 'clone', '-q', '--filter=blob:none', Path(fixture['remote']).as_uri(), str(slot)], env=env, check=True)
subprocess.run(['git', '-C', str(slot), 'switch', '-qc', 'fm/lab-teardown'], env=env, check=True)
(slot / 'unlanded.txt').write_text('Keep this local work when the merged head is unavailable.\n')
subprocess.run(['git', '-C', str(slot), 'add', 'unlanded.txt'], env=env, check=True)
subprocess.run(['git', '-C', str(slot), '-c', 'user.name=gsp-agent', '-c', 'user.email=gsp-agent@users.noreply.github.com', 'commit', '-qm', 'unlanded fixture'], env=env, check=True)
(lab / 'data/backlog.md').write_text('# Backlog\n\n## In progress\n\n- [ ] lab-teardown - Disposable cleanup proof\n')
meta = lab / 'state/lab-teardown.meta'
meta.write_text(f'worktree={slot}\nproject={slot}\nkind=ship\nbranch=fm/lab-teardown\nmode=direct-PR\npr=https://github.com/disposable-lab/firstmate/pull/123\n')
requests = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'method': 'POST', 'path': self.path, 'query': payload.get('query', '')})
        pr = {'state': 'MERGED', 'merged': True, 'headRefOid': 'd' * 40, 'url': 'https://github.com/disposable-lab/firstmate/pull/123', 'number': 123}
        body = json.dumps({'data': {'repository': {'pullRequest': pr}}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = socketserver.UnixStreamServer(str(api_socket), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    test = subprocess.run(['gh', 'pr', 'view', 'https://github.com/disposable-lab/firstmate/pull/123', '--json', 'state,headRefOid,url', '-q', '.state + "\\t" + .headRefOid + "\\t" + .url'], cwd=slot, env=env, capture_output=True, text=True, timeout=20)
    print(json.dumps({'local_forge_client_exit': test.returncode, 'stdout': test.stdout, 'stderr': test.stderr}), flush=True)
    trace = evidence / 'teardown-trace.jsonl'
    started = time.monotonic()
    result = subprocess.run(['bash', 'bin/fm-teardown.sh', 'lab-teardown'], cwd=root, env=env | {'GIT_TRACE2_EVENT': str(trace)}, text=True, capture_output=True, timeout=90)
    events = list(map(json.loads, trace.read_text().splitlines()))
    calls = [event['argv'] for event in events if event.get('event') == 'start']
    probes = [args for args in calls if 'cat-file' in args]
    implicit = [args for args in calls if 'fetch' in args and '--stdin' in args]
    row = {'command': 'FM_HOME=<disposable-marked-home> bin/fm-teardown.sh lab-teardown', 'exit': result.returncode, 'elapsed_seconds': round(time.monotonic() - started, 4), 'stdout': result.stdout, 'stderr': result.stderr, 'cat_file_probes': probes, 'implicit_lazy_fetches': implicit, 'local_forge_requests': requests, 'metadata_preserved': meta.exists(), 'local_work_preserved': (slot / 'unlanded.txt').read_text() == 'Keep this local work when the merged head is unavailable.\n'}
    row['expected_surface'] = result.returncode == 1 and 'not on any remote and not landed' in result.stderr and bool(probes) and not implicit and row['metadata_preserved'] and row['local_work_preserved']
    (evidence / 'teardown-proof.json').write_text(json.dumps(row, indent=2))
    (evidence / 'teardown-refusal.txt').write_text('$ ' + row['command'] + '\n' + result.stdout + result.stderr)
    print(json.dumps(row), flush=True)
finally:
    server.shutdown()
    thread.join()
    server.server_close()
