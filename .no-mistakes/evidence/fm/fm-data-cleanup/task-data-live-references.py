#!/usr/bin/env python3
"""Exercise real glab HTTP reads against an isolated local merge-request dataset."""
import http.server
import importlib.util
import json
from pathlib import Path
import threading
import unicodedata

spec = importlib.util.spec_from_file_location('live', Path(__file__).with_name('task-data-live.py'))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
run, write, home, cleanup = live.run, live.write, live.home, live.cleanup
ROOT, EVIDENCE = live.ROOT, live.EVIDENCE
live.RESULTS = json.loads((EVIDENCE / 'task-data-live-results.json').read_text())

lab, env, project = home('forge-references')
state = {'down': False, 'later': False, 'requests': []}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state['requests'].append(self.path)
        if state['down']:
            self.send_response(503)
            data = {'message': 'Disposable endpoint intentionally unavailable'}
        elif '/merge_requests/1/notes' in self.path:
            self.send_response(200)
            body = '[comment evidence](comments/)'
            if state['later']:
                body += r' [new held directory](later/) [held image](later\(1\).png)'
            data = [{'id': 1, 'body': body}]
        elif '/merge_requests/1' in self.path:
            self.send_response(200)
            data = {'id': 1, 'iid': 1, 'state': 'merged', 'title': 'Disposable cleanup evidence',
                    'description': r'[PR image](proof\(1\).png) [directory](café/)',
                    'web_url': 'https://cleanup.test/group/project/-/merge_requests/1'}
        elif '/api/v4/projects/' in self.path:
            self.send_response(200)
            data = {'id': 1, 'name': 'project', 'path': 'project', 'path_with_namespace': 'group/project',
                    'web_url': 'https://cleanup.test/group/project', 'default_branch': 'main'}
        else:
            self.send_response(404)
            data = {'message': 'No such disposable endpoint'}
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    env = {key: value for key, value in env.items()
           if not key.startswith(('GITLAB_', 'GLAB_')) and key != 'CI_JOB_TOKEN'}
    config_dir = lab / 'config/glab'
    write(config_dir / 'config.yml', 'check_update: false\ntelemetry: false\nhosts:\n  cleanup.test:\n'
          f'    api_host: 127.0.0.1:{server.server_port}\n'
          '    api_protocol: http\n    git_protocol: https\n    token: disposable-local-endpoint\n')
    (config_dir / 'config.yml').chmod(0o600)
    env['GLAB_CONFIG_DIR'] = str(config_dir)
    env['NO_PROXY'] = '127.0.0.1,localhost'
    url = 'https://cleanup.test/group/project/-/merge_requests/1'
    run(['bash', ROOT / 'bin/fm-task-data-lib.sh', 'references', url], env, project)
    root = lab / 'data/forge-owner'
    write(root / 'brief.md', 'Finish this disposable task.\n')
    expected = {'proof(1).png': b'escaped MR proof\x00\xff',
                'café/frame.bin': b'MR directory proof\x00\xff',
                'comments/member.bin': b'MR comment proof\x00\xff'}
    later = {'later/frame.bin': b'new directory reference\x00\xff',
             'later(1).png': b'new escaped reference\x00\xff'}
    for rel, content in (expected | later | {'scratch/blob.bin': b'unlinked scratch'}).items():
        write(root / rel, content)
    cleanup('stage', lab, env, 'forge-owner', project, url)
    for rel, data in expected.items():
        assert (root / rel).read_bytes() == data, rel
    for rel, data in later.items():
        assert (root / '.cleanup-hold' / rel).read_bytes() == data, rel
    state['later'] = True
    state['down'] = True
    refused = cleanup('expire', lab, env, 'forge-owner', expected=None)
    assert refused.returncode != 0
    assert (root / '.cleanup-hold/scratch/blob.bin').read_bytes() == b'unlinked scratch'
    blocked = lab / 'data/unreadable-owner'
    write(blocked / 'scratch/blob.bin', b'untouched pending scratch')
    refused = cleanup('stage', lab, env, 'unreadable-owner', project, url, expected=None)
    assert refused.returncode != 0 and (blocked / 'scratch/blob.bin').read_bytes() == b'untouched pending scratch'
    state['down'] = False
    cleanup('expire', lab, env, 'forge-owner')
    for rel, data in (expected | later).items():
        assert (root / rel).read_bytes() == data, rel
    assert not (root / '.cleanup-hold').exists()
    assert not (root / 'scratch').exists()
    live.record('Real glab reads a disposable non-GitHub MR and comments; unavailable references preserve recovery',
                {'local_http_requests': state['requests'], 'all_reference_bytes_preserved': True,
                 'later_links_restored': True, '503_refused_staging_and_expiry': True,
                 'service': 'Disposable loopback GitLab API dataset; installed glab and production cleanup code'})
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)

print('LIVE_GITLAB_REFERENCE_SCENARIOS_COMPLETE', flush=True)
