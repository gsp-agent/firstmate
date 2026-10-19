from pathlib import Path
import http.server
import json
import os
import socketserver
import subprocess
import threading

root = Path.cwd()
scratch = root / '.nm-live-yeldv-r2'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH/round2')
fixture = json.loads((evidence / 'fixture.json').read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_', 'GH_', 'GITHUB_'))}
env.update(json.loads((evidence / 'env.json').read_text()))
env['FM_HOME'] = str(scratch / 'teardown-home')
remote = scratch / 'teardown-origin.git'
subprocess.run(['git', 'clone', '-q', '--bare', fixture['remote'], str(remote)], env=env, check=True)
subprocess.run(['git', '-C', str(remote), 'fetch', '-q', Path(fixture['seed']).as_uri(), fixture['head'] + ':refs/pull/123/head'], env=env, check=True)
subprocess.run(['git', '-C', str(scratch / 'teardown-slot'), 'remote', 'set-url', 'origin', remote.as_uri()], env=env, check=True)
socket = evidence / 'forge-api-postfetch.sock'
gh_config = scratch / 'postfetch-gh-config'
gh_config.mkdir()
(gh_config / 'config.yml').write_text('http_unix_socket: ' + str(socket) + '\n')
env.update(GH_CONFIG_DIR=str(gh_config), GH_TOKEN='disposable-local-fixture', HTTPS_PROXY='http://127.0.0.1:1', HTTP_PROXY='http://127.0.0.1:1', NO_PROXY='', GH_NO_UPDATE_NOTIFIER='1', GH_TELEMETRY='0', GH_PROMPT_DISABLED='1')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        pr = {'state': 'MERGED', 'merged': True, 'headRefOid': 'd' * 40, 'url': 'https://github.com/disposable-lab/firstmate/pull/123', 'number': 123}
        body = json.dumps({'data': {'repository': {'pullRequest': pr}}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = socketserver.UnixStreamServer(str(socket), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    trace = evidence / 'teardown-postfetch-trace.jsonl'
    p = subprocess.run(['bash', 'bin/fm-teardown.sh', 'lab-teardown'], cwd=root, env=env | {'GIT_TRACE2_EVENT': str(trace)}, text=True, capture_output=True, timeout=90)
    calls = [event['argv'] for event in map(json.loads, trace.read_text().splitlines()) if event.get('event') == 'start']
    probes = [args for args in calls if 'cat-file' in args]
    lazy = [args for args in calls if 'fetch' in args and '--stdin' in args]
    slot = scratch / 'teardown-slot'
    fetched = subprocess.run(['git', '-C', str(slot), 'cat-file', '-e', fixture['head'] + '^{commit}'], env=env | {'GIT_NO_LAZY_FETCH': '1'}, capture_output=True).returncode == 0
    kept = (slot / 'unlanded.txt').read_text() == 'Keep this local work when the merged head is unavailable.\n'
    row = {'scenario': 'Forge metadata and fetched pull ref disagree; both missing-head probes avoid lazy fetch and cleanup preserves unlanded work', 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr, 'cat_file_probes': probes, 'implicit_lazy_fetches': lazy, 'explicit_pr_fetch_retrieved_head': fetched, 'local_work_preserved': kept, 'metadata_preserved': (Path(env['FM_HOME']) / 'state/lab-teardown.meta').exists()}
    row['expected_surface'] = p.returncode == 1 and 'not on any remote and not landed' in p.stderr and len(probes) == 2 and not lazy and fetched and kept and row['metadata_preserved']
    (evidence / 'teardown-postfetch-proof.json').write_text(json.dumps(row, indent=2))
    print(json.dumps(row), flush=True)
finally:
    server.shutdown()
    thread.join()
    server.server_close()
