#!/usr/bin/env python3
"""Send one Herdr socket API request to an fm-lab-* session's own socket.

The CLI has no `pane scroll` command, so this sets a lab pane's scroll offset
through Herdr's documented `pane.scroll` API method. It refuses any socket that
is not the named fm-lab-* session's own socket.
Usage: herdr-lab-api.py <session> <socket> <method> <params-json>
"""
import json, os, re, socket, sys

session, sock_path, method, params = sys.argv[1:5]
if not re.fullmatch(r"fm-lab-[A-Za-z0-9][A-Za-z0-9_-]*", session):
    sys.exit("refusing non-lab session")
if os.path.basename(os.path.dirname(sock_path)) != session:
    sys.exit("refusing a socket that is not the lab session's own")
req = {"id": "fm-xbvre-live", "method": method, "params": json.loads(params)}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sock_path)
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
s.close()
print(buf.decode().strip())
