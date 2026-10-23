#!/usr/bin/env bash
# Live guard for the Codex usage-limit route in bin/fm-cursor-guard.sh.
#
# The route's verdict comes from what the installed codex persists when a turn
# ends on its usage limit: the rollout's last task_complete carries
# codex_error_info usage_limit_exceeded. A fixture can only repeat that
# assumption, so this guard runs the real codex against a local server that
# answers every request with the 429 usage_limit_reached body, then asks the
# route about the task whose worktree that session ran in. If a codex release
# stops persisting the stop that way, the marker is never written and this
# guard fails naming the harness and version.
#
# The local server stands in for the model provider, so the guard spends no
# model tokens and runs by default wherever codex is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

fm_live_gate default-on FM_CODEX_LIMIT_LIVE codex python3 jq

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-limit-live)
mkdir -p "$TMP_ROOT/server" "$TMP_ROOT/codexhome" "$TMP_ROOT/wt" "$TMP_ROOT/home/state"
MOCK_PID=
codex_limit_cleanup() {
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap codex_limit_cleanup EXIT

cat > "$TMP_ROOT/server/mock.py" <<'PY'
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def _reply(self):
        n = int(self.headers.get('content-length') or 0)
        if n: self.rfile.read(n)
        body = json.dumps({"error": {"type": "usage_limit_reached", "message": "The usage limit has been reached",
                                     "plan_type": "pro", "resets_at": int(time.time()) + 86400}}).encode()
        self.send_response(429)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_POST = _reply
    do_GET = _reply
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
with open(sys.argv[1] + '.tmp', 'w') as f: f.write(str(s.server_address[1]))
import os; os.rename(sys.argv[1] + '.tmp', sys.argv[1])
s.serve_forever()
PY
python3 -I "$TMP_ROOT/server/mock.py" "$TMP_ROOT/server/port" &
MOCK_PID=$!
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/server/port" ] && break; sleep 0.1; done
[ -s "$TMP_ROOT/server/port" ] || fail "the local usage-limit server did not start"
PORT=$(cat "$TMP_ROOT/server/port")

ID=codex-limit-live
printf 'worktree=%s\nharness=codex\nspawn_gen=s%s.1.1\n' "$TMP_ROOT/wt" "$(( $(date +%s) - 5 ))" > "$TMP_ROOT/home/state/$ID.meta"
fm_run_timed 120 env MOCK_KEY=dummy CODEX_HOME="$TMP_ROOT/codexhome" \
  codex exec --skip-git-repo-check -C "$TMP_ROOT/wt" \
  -c 'model_provider="mock"' \
  -c "model_providers.mock={name=\"mock\",base_url=\"http://127.0.0.1:$PORT/v1\",wire_api=\"responses\",env_key=\"MOCK_KEY\"}" \
  -m gpt-5 "say hi" > "$TMP_ROOT/exec.out" 2>&1
rc=$?
[ "$rc" -ne 124 ] || fail "$CODEX_VERSION did not stop within 120s on a usage-limit answer: $(tail -5 "$TMP_ROOT/exec.out")"
[ "$rc" -ne 0 ] || fail "$CODEX_VERSION exited 0 on a usage-limit answer: $(tail -5 "$TMP_ROOT/exec.out")"

out=$(CODEX_HOME="$TMP_ROOT/codexhome" FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config" \
  "$ROOT/bin/fm-cursor-guard.sh" route "$ID" codex)
case "$out" in
  "claude codex run for $ID hit its usage limit"*) ;;
  *) fail "$CODEX_VERSION: a session ended on its usage limit must route to claude, got '$out'; codex output: $(tail -3 "$TMP_ROOT/exec.out")" ;;
esac
[ -s "$TMP_ROOT/home/state/$ID.codex-limit" ] || fail "$CODEX_VERSION: the usage-limit stop wrote no state/<id>.codex-limit"
pass "$CODEX_VERSION: a real usage-limit stop writes the marker and routes the next launch to claude"
