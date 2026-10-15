import http.server
import json
import os
from pathlib import Path
import shlex
import subprocess
import threading
import time

root = Path.cwd()
lab = root / 'L'
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M50V2BM2QVYA70JHTFYFVJEA')
requests = []

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'model': body.get('model'), 'stream': body.get('stream'), 'message_roles': [m['role'] for m in body.get('messages', [])]})
        chunks = [
            {'id': 'local-lab', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'lab', 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'LOCAL-LAB-ACK'}, 'finish_reason': None}]},
            {'id': 'local-lab', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'lab', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]},
        ]
        payload = ''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks) + 'data: [DONE]\n\n'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload.encode())))
        self.end_headers()
        self.wfile.write(payload.encode())

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
agent = lab / 'pi-agent'
agent.mkdir(exist_ok=True)
(agent / 'models.json').write_text(json.dumps({'providers': {'nm-local': {'baseUrl': f'http://127.0.0.1:{server.server_port}/v1', 'api': 'openai-completions', 'apiKey': 'local-fixture-placeholder', 'models': [{'id': 'lab', 'name': 'Local fixture provider', 'contextWindow': 131072, 'maxTokens': 1024, 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}))
event_path = evidence / 'native-pi-events.jsonl'
event_path.write_text('')
observer = lab / 'observer.ts'
observer.write_text('''
import { appendFileSync } from "node:fs";
import branch from %s;
import watch from %s;
const out = %s;
const record = (value) => appendFileSync(out, JSON.stringify(value) + "\\n");
export default function(pi) {
  pi.on("session_start", async () => {
    const result = await pi.exec("bash", [%s]);
    record({event:"lock", ...result});
  });
  pi.on("before_agent_start", (event) => {
    record({event:"before_agent_start", messageType:event.messageType, hasPrompt:typeof event.prompt === "string", prompt:event.prompt, customType:event.message?.customType});
  });
  pi.on("message_end", (event) => {
    if (event.message.role === "assistant") record({event:"assistant_end", stopReason:event.message.stopReason, content:event.message.content});
  });
  pi.registerCommand("labcustom", {description:"Send one native custom-message turn", handler: async () => {
    pi.sendMessage({customType:"nm-validation", content:"native custom protocol probe", display:true}, {triggerTurn:true});
  }});
  branch(pi);
  watch(pi);
  pi.on("session_start", () => record({event:"ready", pid:process.pid}));
  pi.on("session_shutdown", () => record({event:"shutdown"}));
}
''' % tuple(json.dumps(str(p)) for p in [root / '.pi/extensions/fm-branch-supervision.ts', root / '.pi/extensions/fm-primary-pi-watch.ts', event_path, root / 'bin/fm-lock.sh']))

env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX', 'NO_MISTAKES_GATE')}
env.update(FM_HOME=str(lab), TMUX_TMPDIR=str(lab / 'tmux'), PI_CODING_AGENT_DIR=str(agent), PI_CODING_AGENT_SESSION_DIR=str(lab / 'sessions'), PI_OFFLINE='1', PI_TELEMETRY='0', TMPDIR=str(root / '.test-phase/tmp'))
log_path = evidence / 'native-pi-primary.log'
with log_path.open('w') as log:
    def tmux(*args):
        p = subprocess.run(['tmux', '-L', 'fm-lab', *args], env=env, text=True, capture_output=True, timeout=15)
        if p.stderr:
            log.write(p.stderr)
        return p

    def events():
        return [json.loads(line) for line in event_path.read_text().splitlines() if line]

    def wait_for(predicate, label, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(events()):
                return
            time.sleep(0.1)
        log.write(tmux('capture-pane', '-p', '-t', 'primary', '-S', '-100').stdout)
        log.flush()
        raise RuntimeError('Native Pi timeout: ' + label)

    pi_cli = root / '.test-phase/pi-current/node_modules/.bin/pi'
    cli = ' '.join(shlex.quote(arg) for arg in [str(pi_cli), '--no-extensions', '--no-skills', '--no-context-files', '--no-prompt-templates', '--offline', '--provider', 'nm-local', '--model', 'lab', '--extension', str(observer), '--approve'])
    started = tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), '-e', f'FM_HOME={lab}', cli)
    log.write(f'Real Pi CLI; private 120x40 tmux primary; local provider endpoint 127.0.0.1:{server.server_port}; no user credential or configuration. Start exit={started.returncode}\n')
    assert started.returncode == 0
    try:
        wait_for(lambda rows: any(r['event'] == 'ready' for r in rows), 'extension readiness')
        assert tmux('send-keys', '-t', 'primary', '-l', 'native user protocol probe').returncode == 0
        tmux('send-keys', '-t', 'primary', 'Enter')
        wait_for(lambda rows: sum(r['event'] == 'assistant_end' for r in rows) >= 1, 'typed user completion')
        log.write('After real typed-user turn:\n' + tmux('capture-pane', '-p', '-t', 'primary', '-S', '-100').stdout + '\n')
        tmux('send-keys', '-t', 'primary', '-l', '/labcustom')
        tmux('send-keys', '-t', 'primary', 'Enter')
        wait_for(lambda rows: any(r.get('messageType') == 'custom' for r in rows), 'custom-message before_agent_start')
        wait_for(lambda rows: sum(r['event'] == 'assistant_end' for r in rows) >= 2, 'custom completion')
        capture = tmux('capture-pane', '-p', '-t', 'primary', '-S', '-150').stdout
        log.write('After real custom-message turn:\n' + capture + '\n')
        rows = events()
        assert any(r.get('messageType') == 'user' and r.get('prompt') == 'native user protocol probe' for r in rows), rows
        assert any(r.get('messageType') == 'custom' and r.get('customType') == 'nm-validation' and not r['hasPrompt'] for r in rows), rows
        assert not any(phrase in capture for phrase in ['TypeError', 'Cannot read properties', 'Extension error']), capture
        assert all(r.get('stopReason') == 'stop' for r in rows if r['event'] == 'assistant_end'), rows
        log.write('Both typed-user and custom-message turns completed through the real Pi CLI with the production branch and watcher extensions loaded.\n')
    finally:
        tmux('send-keys', '-t', 'primary', 'C-d')
        try:
            wait_for(lambda rows: any(r['event'] == 'shutdown' for r in rows), 'graceful shutdown', timeout=8)
        finally:
            tmux('kill-server')
            server.shutdown()
            (evidence / 'native-pi-provider-requests.json').write_text(json.dumps(requests, indent=2) + '\n')
print('Native Pi user/custom protocol scenario passed.')
