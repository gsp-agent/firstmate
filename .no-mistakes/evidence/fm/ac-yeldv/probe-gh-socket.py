from pathlib import Path
import json
import os
import socket
import subprocess
import threading

root = Path.cwd()
evidence = Path('/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH')
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(str(evidence / 'gh-test.sock'))
sock.listen(2)
sock.settimeout(5)

def serve():
    try:
        connection, _ = sock.accept()
        request = connection.recv(10000)
        print('Local socket accepted ' + request.split(b'\r\n')[0].decode(), flush=True)
        body = b'{"login":"disposable-lab"}'
        connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
        connection.close()
    except TimeoutError:
        print('Local socket not used', flush=True)
    finally:
        sock.close()

thread = threading.Thread(target=serve)
thread.start()
env = {k: v for k, v in os.environ.items() if not k.startswith(('GH_', 'GITHUB_'))}
env.update(GH_CONFIG_DIR=str(root / '.nm-live-yeldv/gh-config'), GH_TOKEN='disposable-local-fixture', GH_HTTP_UNIX_SOCKET=str(evidence / 'gh-test.sock'), HTTPS_PROXY='http://127.0.0.1:1', HTTP_PROXY='http://127.0.0.1:1', NO_PROXY='', GH_NO_UPDATE_NOTIFIER='1', GH_TELEMETRY='0')
result = subprocess.run(['gh', 'api', 'user'], env=env, text=True, capture_output=True, timeout=10)
print(json.dumps({'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}))
thread.join()
