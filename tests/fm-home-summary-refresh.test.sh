#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-refresh)
HOME_DIR="$TMP_ROOT/mate-home"
CADENCE_HOME="$TMP_ROOT/cadence-home"
PARENT_HOME="$TMP_ROOT/parent-home"
LARGE_HOME="$TMP_ROOT/large-home"
STATELESS_HOME="$TMP_ROOT/stateless-home"
LARGE_CHILD_HOME="$TMP_ROOT/large-child-home"
LARGE_PARENT_HOME="$TMP_ROOT/large-parent-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID=
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
LOCK_HOLDER_PID=

cleanup() {
  local pid
  case "$SLOW_WORKER_PGID" in
    ''|*[!0-9]*) ;;
    *) kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 || true ;;
  esac
  for pid in "$WATCH_PID" "$SLOW_WRITER_PID" "$SLOW_NM_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NM_MARKER:-}" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_MARKER"
  sleep "${FM_TEST_NM_SLEEP:-30}"
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"

python3 - "$ROOT" "$TMP_ROOT" "$FAKEBIN" <<'PYTHON' || fail "watcher refresh cleanup failed"
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, tmp, fakebin = map(Path, sys.argv[1:])
code = tmp / "refresh-cleanup-code" / "bin"
code.mkdir(parents=True)
for helper in (root / "bin").iterdir():
    if helper.name not in ("fm-fleet-snapshot.sh", "fm-timeout-lib.sh"):
        (code / helper.name).symlink_to(helper)
shutil.copy2(root / "bin/fm-timeout-lib.sh", code / "fm-timeout-lib.sh")
producer = code / "fm-fleet-snapshot.sh"
producer.write_text(r'''#!/usr/bin/env bash
if [ "${FM_TEST_SLOW_REFRESH:-0}" = 1 ]; then
  (trap '' HUP INT TERM; sleep 900) &
  child=$!
  printf '%s %s %s\n' "$$" "$PPID" "$child" > "$FM_HOME/state/producer.pids"
  wait "$child"
  exit 1
fi
jq -n --arg home "$FM_HOME" '{
  schema:"fm-secondmate-home-summary.v1", hold_classifier_schema:"fm-captain-hold-buckets.v1",
  home:$home, generated:"2026-10-22T00:00:00Z", generated_epoch:1792627200,
  valid:true, state:"idle", invalidity:{}, active_children:[], decisions_open:[],
  holds:[], queued:[], landed:[], endpoints:[], counts:{}, omitted:[]
}'
''')
producer.chmod(0o755)

normal = tmp / "refresh-normal.sh"
normal.write_text(r'''#!/usr/bin/env bash
. "$1"
trap 'printf callback > "$FM_HOME/trap-fired"' TERM
for wanted in 0 7 137 143; do
  rc=0
  fm_run_timed 30 bash "$FM_HOME/status.sh" "$wanted" <<< 'preserved input' || rc=$?
  [ "$rc" = "$wanted" ] || exit 90
  [ "$(cat "$FM_HOME/input")" = 'preserved input' ] || exit 91
done
rc=0
fm_run_timed 1 sleep 30 || rc=$?
[ "$rc" = 124 ] || exit 92
kill -TERM "$$"
[ "$(cat "$FM_HOME/trap-fired")" = callback ] || exit 93
''')
normal.chmod(0o755)

def wait_for(predicate, message):
    for _ in range(1200):
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(message)

def running(pids):
    output = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, pids))],
                            stdout=subprocess.PIPE, text=True, check=False).stdout
    return {int(row.split()[0]) for row in output.splitlines() if not row.split()[1].startswith("Z")}

gnu = shutil.which("timeout") or shutil.which("gtimeout")
paths = {}
for mechanism in ("timeout", "gtimeout", "perl", "bash"):
    tools = tmp / ("refresh-tools-" + mechanism)
    tools.mkdir()
    for name in ("bash", "sleep", "dirname", "basename", "date", "env", "mkdir", "mktemp",
                 "chmod", "cat", "rm", "rmdir", "mv", "jq", "ps", "awk", "sed", "tr", "tail",
                 "wc", "head", "cut", "sort", "shasum", "sha256sum", "cksum", "stat", "find",
                 "uname", "touch", "python3", "git", "readlink", "id", "grep", "mkfifo", "od",
                 "cp", "ln", "cmp", "xargs", "hostname", "kill", "perl"):
        source = shutil.which(name)
        if source:
            (tools / name).symlink_to(source)
    if mechanism in ("timeout", "gtimeout"):
        if not gnu:
            print("skip: " + mechanism + " refresh cancellation requires GNU timeout", flush=True)
            continue
        (tools / mechanism).symlink_to(gnu)
    elif mechanism == "perl":
        assert shutil.which("perl"), "perl refresh cancellation requires perl on PATH"
    paths[mechanism] = str(tools) + os.pathsep + str(fakebin)

def make_home(name, mechanism, secondmate=True):
    home = tmp / ("refresh-cleanup-" + name)
    for directory in (home / "state", home / "data", home / "config"):
        directory.mkdir(parents=True)
    if secondmate:
        (home / ".fm-secondmate-home").write_text("mate\n")
    (home / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
    env = dict(os.environ, PATH=paths[mechanism], FM_ROOT_OVERRIDE=str(root), FM_HOME=str(home),
               FM_STATE_OVERRIDE=str(home / "state"), FM_DATA_OVERRIDE=str(home / "data"),
               FM_CONFIG_OVERRIDE=str(home / "config"), FM_PROJECTS_OVERRIDE=str(home / "projects"),
               FM_HOME_SUMMARY_TIMEOUT="900", FM_POLL="1", FM_SIGNAL_GRACE="0",
               FM_CHECK_INTERVAL="9999999", FM_HEARTBEAT="9999999")
    env.pop("FM_TIMEOUT_MECHANISM_OVERRIDE", None)
    if mechanism == "bash":
        env["FM_TIMEOUT_MECHANISM_OVERRIDE"] = "bash"
    return home, env

def cancel(name, mechanism, sig, watcher=False):
    home, env = make_home(name + "-" + mechanism, mechanism)
    state = home / "state"
    env["FM_TEST_SLOW_REFRESH"] = "1"
    signal_trigger = name in ("signal", "actionable")
    env["FM_HOME_SUMMARY_INTERVAL"] = "9999999" if signal_trigger else "1"
    if signal_trigger:
        (state / "task.meta").write_text("kind=scout\nharness=claude\nwindow=fmtest:task\n")
        (state / "task.status").touch()
        crew = home / "crew-state.sh"
        crew.write_text("#!/usr/bin/env bash\nprintf 'state: working · source: pane · fixture busy\\n'\n")
        crew.chmod(0o755)
        env["FM_CREW_STATE_BIN"] = str(crew)
    command = ["bash", str(code / ("fm-watch.sh" if watcher else "fm-home-summary-refresh.sh"))]
    records = []
    producer_group = None
    drain_pid = None
    with (home / "out").open("w") as out, (home / "err").open("w") as err:
        parent = subprocess.Popen(command, env=env, stdout=out, stderr=err)
        try:
            if signal_trigger:
                wait_for(lambda: (state / ".last-watcher-beat").exists(), "signal watcher never polled")
                verb = "blocked" if name == "actionable" else "working"
                (state / "task.status").write_text(verb + ": fixture busy\n")
            def started():
                assert parent.poll() is None, name + " exited before starting its producer"
                record = state / "producer.pids"
                return record.exists() and len(record.read_text().split()) == 3
            wait_for(started, name + " producer never started")
            records = list(map(int, (state / "producer.pids").read_text().split()))
            if watcher:
                drain_pid = int((state / ".home-summary-drain.lock/pid").read_text())
            producer_group = os.getpgid(records[0])
            assert producer_group != os.getpgrp(), name + " producer did not own a separate group"
            assert {records[0], records[2]} <= running(records), name + " producer was not running"
            if name == "signal":
                assert not (state / ".home-summary-dirty").exists(), "producer did not consume its request"
                with (state / "task.status").open("a") as status:
                    status.write("working: another status during publication\n")
                wait_for(lambda: (state / ".home-summary-dirty").exists(),
                         "signal during publication lost its pending request")
            if name == "actionable":
                wait_for(lambda: (home / "out").read_text().startswith("signal:"),
                         "actionable signal was not delivered while publication was pending")
            parent.send_signal(sig)
            parent.wait(timeout=120)
            expected = (0,) if name == "actionable" else (-sig, 128 + sig)
            assert parent.returncode in expected, name + " cancellation status: " + str(parent.returncode)
            owned = records + ([drain_pid] if drain_pid else [])
            survivors = running(owned)
            assert not survivors, name + " left a drain, producer, or worker running: " + str(sorted(survivors))
        except Exception as error:
            raise AssertionError(str(error) + "\n" + (home / "err").read_text() + (home / "out").read_text()) from error
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.wait()
            if producer_group is not None:
                try:
                    os.killpg(producer_group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            record = state / "producer.pids"
            if record.exists():
                for pid in map(int, record.read_text().split()):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if drain_pid:
                try:
                    os.kill(drain_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

for mechanism in paths:
    home, env = make_home("completed-" + mechanism, mechanism)
    (home / "status.sh").write_text(r'''IFS= read -r incoming
printf '%s\n' "$incoming" > "$FM_HOME/input"
case "$1" in
  137) kill -KILL "$$" ;;
  143) kill -TERM "$$" ;;
  *) exit "$1" ;;
esac
''')
    completed = subprocess.run(["/bin/bash", str(normal), str(code / "fm-timeout-lib.sh")],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    assert completed.returncode == 0, mechanism + " normal call failed: " + completed.stderr
    published = subprocess.run(["bash", str(code / "fm-home-summary-refresh.sh")],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    assert published.returncode == 0, mechanism + " publication failed: " + published.stderr
    ledger = json.loads((home / "state/home-summary.json").read_text())
    assert ledger["home"] == str(home) and ledger["valid"], mechanism + " publication changed"
    owned_home, owned_env = make_home("request-" + mechanism, mechanism)
    request_command = ["bash", str(code / "fm-home-summary-refresh.sh"), "--request", "--wait"]
    published = subprocess.run(request_command, env=owned_env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, timeout=30)
    assert published.returncode == 0, mechanism + " waited request failed: " + published.stderr
    owned_state = owned_home / "state"
    original = (owned_state / "home-summary.json").read_bytes()
    assert json.loads(original)["home"] == str(owned_home), mechanism + " waited request did not publish"
    assert not (owned_state / ".home-summary-drain.lock").exists(), mechanism + " drain lock survived publication"
    owned_env["FM_TEST_SLOW_REFRESH"] = "1"
    owned_env["FM_HOME_SUMMARY_INTERVAL"] = "9999999"
    cooling = subprocess.run(request_command, env=owned_env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, timeout=10)
    assert cooling.returncode == 0, mechanism + " cooling request failed: " + cooling.stderr
    assert not (owned_state / "producer.pids").exists(), mechanism + " cooldown started a producer"
    assert (owned_state / "home-summary.json").read_bytes() == original, mechanism + " cooldown changed the ledger"
    assert (owned_state / ".home-summary-dirty").exists(), mechanism + " cooldown lost the pending request"
    assert not (owned_state / ".home-summary-drain.lock").exists(), mechanism + " cooldown kept its drain alive"
    main_home, main_env = make_home("main-" + mechanism, mechanism, secondmate=False)
    main_request = subprocess.run(request_command, env=main_env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, timeout=10)
    assert main_request.returncode == 0, mechanism + " main-home request failed"
    assert not list((main_home / "state").iterdir()), mechanism + " main-home request wrote publication state"
    cancel("parent", mechanism, signal.SIGTERM)
    for trigger in ("poll", "signal", "actionable"):
        cancel(trigger, mechanism, signal.SIGTERM, watcher=True)
        print("ok - real refresh producer reaped after watcher " + trigger + ": " + mechanism, flush=True)
    print("ok - real refresh cancellation and normal calls: " + mechanism, flush=True)

mechanism = next(iter(paths))
for sig in (signal.SIGHUP, signal.SIGINT):
    cancel("parent-signal-" + str(sig), mechanism, sig)
PYTHON
pass "watcher cleanup reaps real refresh workers and producers across timeout mechanisms"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" \
  "$HOME_DIR/projects/task" "$HOME_DIR/bin"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
printf '# Seeded Firstmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
fm_git_init_commit "$HOME_DIR/projects/task"
git -C "$HOME_DIR/projects/task" checkout -q -b fm/ledger-task
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] ledger-task - Publish the home ledger (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$HOME_DIR/state/ledger-task.meta" \
  "window=fmtest:fm-ledger-task" \
  "worktree=$HOME_DIR/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.ledger123456"
busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" ledger-task)
"$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" ledger-task idle \
  --gen "$busy_gen" --source claude-hook --event stop

NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
NOW_TWO=2026-08-28T10:01:00Z
EPOCH_TWO=1787911260
NOW_THREE=2026-08-28T10:02:00Z
EPOCH_THREE=1787911320

run_writer() {  # <now> <epoch> [writer args...]
  local now=$1 epoch=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$now" FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    "$WRITER" "$@"
}

run_producer() {  # <now> <epoch>
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_SNAPSHOT_NOW="$1" FM_SNAPSHOT_NOW_EPOCH="$2" \
    "$SNAPSHOT" --secondmate-home-summary
}

wait_for_ledger_generation() {  # <generated> [tenths]
  local want=$1 attempts=${2:-150} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(jq -r '.generated // ""' "$HOME_DIR/state/home-summary.json" 2>/dev/null || true)
    [ "$got" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_writer "$NOW_ONE" "$EPOCH_ONE" || fail "initial home-summary publication failed"
jq -e --arg home "$HOME_DIR" --arg now "$NOW_ONE" --argjson epoch "$EPOCH_ONE" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and .generated == $now
  and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "initial ledger did not expose the extended producer schema"

PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_TEST_NM_MARKER="$TMP_ROOT/status-refresh-nm.pid" FM_TEST_NM_SLEEP=2 \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$HOME_DIR/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$HOME_DIR/state/.last-watcher-beat" ] \
  || fail "the real watcher did not begin polling: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
printf 'blocked [key=fixture-dependency]: waiting for the fixture dependency\n' \
  >> "$HOME_DIR/state/ledger-task.status"
wait_for_ledger_generation "$NOW_TWO" \
  || fail "a status append did not refresh the ledger within the watcher cadence"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
[ -s "$TMP_ROOT/status-refresh-nm.pid" ] \
  || fail "the status-triggered producer did not reach its delayed dependency"
jq -e 'any(.decisions_open[]; .id == "ledger-task" and .key == "fixture-dependency")' \
  "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "the status-triggered ledger lost the actionable decision"

run_producer "$NOW_TWO" "$EPOCH_TWO" > "$TMP_ROOT/fresh-summary.json" \
  || fail "fresh secondmate-home-summary production failed"
jq -S 'del(.generated, .generated_epoch)' "$HOME_DIR/state/home-summary.json" \
  > "$TMP_ROOT/published-normalized.json"
jq -S 'del(.generated, .generated_epoch)' "$TMP_ROOT/fresh-summary.json" \
  > "$TMP_ROOT/fresh-normalized.json"
cmp -s "$TMP_ROOT/published-normalized.json" "$TMP_ROOT/fresh-normalized.json" \
  || fail "the status-triggered ledger differed from the real fresh producer"
pass "watcher-carried status append publishes the real home summary"


MANY_HOME="$TMP_ROOT/many-task-home"
mkdir -p "$MANY_HOME/state" "$MANY_HOME/data" "$MANY_HOME/config"
printf '## In flight\n' > "$MANY_HOME/data/backlog.md"
i=1
while [ "$i" -le 64 ]; do
  id=$(printf 'task-%02d' "$i")
  printf -- '- [ ] %s - Many task fixture (repo: firstmate) (kind: ship)\n' "$id" \
    >> "$MANY_HOME/data/backlog.md"
  fm_write_meta "$MANY_HOME/state/$id.meta" \
    'kind=scout' 'kind=ship' 'harness=codex' 'remote_host=example.invalid' \
    'remote_root=/remote home' 'remote_backend=herdr' "remote_target=remote:$id" \
    'project=firstmate' 'mode=direct-PR' 'spawn_gen=many-generation'
  : > "$MANY_HOME/state/$id.status"
  j=1
  while [ "$j" -le 20 ]; do
    printf 'needs-decision [key=history]: prior gate\nresolved [key=history]: settled\n' \
      >> "$MANY_HOME/state/$id.status"
    j=$((j + 1))
  done
  printf 'needs-decision [key=closed]: old choice\nresolved [key=closed]: settled\nblocked [key=dependency]: wait for "fixture" \\ input\n' \
    >> "$MANY_HOME/state/$id.status"
  i=$((i + 1))
done
printf '\n## Queued\n\n## Done\n' >> "$MANY_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MANY_HOME" \
  FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=08 \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/many-summary.json" \
  || fail "many-task home summary failed"
jq -n --arg home "$MANY_HOME" --arg now "$NOW_ONE" --argjson epoch "$EPOCH_ONE" '
  [range(1;65) | "task-" + (if . < 10 then "0" else "" end) + tostring] as $ids
  | {
      schema:"fm-secondmate-home-summary.v1",
      hold_classifier_schema:"fm-captain-hold-buckets.v1",
      contributions:{known:0,checked:0,counts:{captain:0,fleet:0,maintainer:0,nobody:0},
        unmeasured:0,complete:true,proven_clear:true,stale_verdicts:0,missing_verdicts:0,
        unreadable_records:0,valid_until:900,captain:[],captain_omitted:0},
      generated:$now,generated_epoch:$epoch,home:$home,valid:false,
      reason:("child current state unavailable: " + ($ids | join(", "))),
      invalidity:{kind:"child_current_unavailable",ids:$ids},state:"unknown",
      active_children:[],
      decisions_open:[$ids[:20][] | {id:.,key:"dependency",verb:"blocked",
        summary:"wait for \"fixture\" \\ input",reason:null,source:"status"}],
      holds:[],queued:[],landed:[],
      endpoints:[$ids[:20][] | {id:.,state:"unknown",source:"none",
        endpoint:{target:("remote:" + .),exists:null,agent_alive:"unknown",status:"unknown",
          observed_at:$now,freshness:"fresh"}}],
      counts:{active_children:0,decisions_open:64,holds:0,queued:0,landed:0,endpoints:64},
      omitted:[{surface:"decisions_open",count:44},{surface:"endpoints",count:44}]
    }
' > "$TMP_ROOT/many-expected.json"
diff -u "$TMP_ROOT/many-expected.json" "$TMP_ROOT/many-summary.json" \
  || fail "many-task summary changed its complete document"
pass "many-task summary preserves bounded output, duplicate metadata, and keyed status text"

# A structured in-flight inventory above Linux MAX_ARG_STRLEN must remain
# publishable through every fleet snapshot mode and the real home-summary writer.
mkdir -p "$LARGE_HOME/state" "$LARGE_HOME/data" "$LARGE_HOME/config" \
  "$LARGE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$LARGE_HOME/AGENTS.md"
printf 'large\n' > "$LARGE_HOME/.fm-secondmate-home"
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 1200 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_HOME/data/backlog.md"
[ "$(wc -c < "$LARGE_HOME/data/backlog.md")" -gt 131072 ] \
  || fail "large in-flight fixture did not exceed the per-argument limit"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-snapshot.json" \
  || fail "fleet snapshot json mode failed for a large backlog"
jq -e '.schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | length) == 1200
  and (.main_inventory.orphan_in_flight | length) == 1200' \
  "$TMP_ROOT/large-snapshot.json" >/dev/null \
  || fail "large fleet snapshot did not preserve the orphan inventory"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/large-summary.json" \
  || fail "secondmate home-summary mode failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$TMP_ROOT/large-summary.json" \
  >/dev/null || fail "large secondmate home-summary output was not valid"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --contribution-input > "$TMP_ROOT/large-contribution-input.json" \
  || fail "contribution-input mode failed for a large backlog"
jq -e '(.backlog.records | length) == 1200 and (.tasks | type) == "array"' \
  "$TMP_ROOT/large-contribution-input.json" >/dev/null \
  || fail "large contribution input did not preserve the backlog records"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "home-summary writer failed for a large backlog"
jq -e '.schema == "fm-secondmate-home-summary.v1"' \
  "$LARGE_HOME/state/home-summary.json" >/dev/null \
  || fail "large secondmate home-summary was not published"
pass "large backlog snapshots and home-summary publication stay within exec limits"

mkdir -p "$STATELESS_HOME/data" "$STATELESS_HOME/config" \
  "$STATELESS_HOME/projects"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$STATELESS_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STATELESS_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/stateless-snapshot.json" \
  || fail "fleet snapshot json mode failed without a state directory"
jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | length) == 0' \
  "$TMP_ROOT/stateless-snapshot.json" >/dev/null \
  || fail "stateless fleet snapshot output was not valid"
[ ! -e "$STATELESS_HOME/state" ] \
  || fail "fleet snapshot created operational state for transport files"
pass "fleet snapshot transport does not require or mutate operational state"

mkdir -p "$LARGE_CHILD_HOME/state" "$LARGE_CHILD_HOME/data" \
  "$LARGE_CHILD_HOME/config" "$LARGE_CHILD_HOME/projects" "$LARGE_CHILD_HOME/bin"
printf '# Seeded Firstmate home\n' > "$LARGE_CHILD_HOME/AGENTS.md"
printf 'large-child\n' > "$LARGE_CHILD_HOME/.fm-secondmate-home"
{
  printf '%s\n' '## In flight'
  i=1
  while [ "$i" -le 600 ]; do
    printf '%s\n' "- [ ] orphan-$i-$large_id_suffix - Missing metadata (repo: firstmate) (kind: ship)"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Queued' '' '## Done'
} > "$LARGE_CHILD_HOME/data/backlog.md"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_CHILD_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "large child home-summary publication failed"
large_child_bytes=$(wc -c < "$LARGE_CHILD_HOME/state/home-summary.json")
[ "$large_child_bytes" -gt 131072 ] && [ "$large_child_bytes" -le 262144 ] \
  || fail "large child ledger did not cross only the per-argument limit: $large_child_bytes"
mkdir -p "$LARGE_PARENT_HOME/state" "$LARGE_PARENT_HOME/data" \
  "$LARGE_PARENT_HOME/config" "$LARGE_PARENT_HOME/projects"
printf -- '- large-child - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$LARGE_CHILD_HOME" > "$LARGE_PARENT_HOME/data/secondmates.md"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
  > "$LARGE_PARENT_HOME/data/backlog.md"
fm_write_secondmate_meta "$LARGE_PARENT_HOME/state/large-child.meta" \
  "$LARGE_CHILD_HOME" "fmtest:fm-large-child" firstmate claude
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity"
pass "parent snapshot consumes large child ledgers without argument transport"

mkdir -p "$CADENCE_HOME/state" "$CADENCE_HOME/data" "$CADENCE_HOME/config" \
  "$CADENCE_HOME/projects"
printf '# Seeded Firstmate home\n' > "$CADENCE_HOME/AGENTS.md"
printf 'cadence\n' > "$CADENCE_HOME/.fm-secondmate-home"
cat > "$CADENCE_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not seed the cadence ledger"
touch -t 203801010000 "$CADENCE_HOME/state/home-summary.json"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CADENCE_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/cadence-watch.out" 2> "$TMP_ROOT/cadence-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$CADENCE_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$CADENCE_HOME/state/.last-watcher-beat" ] \
  || fail "the cadence watcher did not complete its initial cycle"
python3 - "$CADENCE_HOME/data/backlog.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("## Queued\n\n## Done", "## Queued\n- [ ] cadence-task - Publish without a status signal (repo: firstmate) (kind: ship)\n\n## Done"))
PY
i=0
while ! jq -e 'any(.queued[]; .id == "cadence-task")' \
  "$CADENCE_HOME/state/home-summary.json" >/dev/null 2>&1; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the cadence watcher exited before publishing the backlog-only change"
  [ "$i" -lt 80 ] \
    || fail "a backlog-only change did not refresh within the configured watcher cadence"
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "live watcher cadence bounds publication staleness without signals"

# Consumer boundary: first serialize behind any watcher-started publication,
# then replace the ledger with a structurally complete but semantically false
# state. The default parent snapshot must consume that publication rather than
# silently recomputing a different view of the owning home.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not settle the ledger before the consumer check"
jq '.state = "no_active_work" | .active_children = [] | .holds = []
    | .counts.active_children = 0 | .counts.holds = 0' \
  "$HOME_DIR/state/home-summary.json" > "$HOME_DIR/state/home-summary.poisoned"
mv -f "$HOME_DIR/state/home-summary.poisoned" "$HOME_DIR/state/home-summary.json"
mkdir -p "$PARENT_HOME/state" "$PARENT_HOME/data" "$PARENT_HOME/config" "$PARENT_HOME/projects"
printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-08-28)\n' \
  "$HOME_DIR" > "$PARENT_HOME/data/secondmates.md"
cat > "$PARENT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
fm_write_secondmate_meta "$PARENT_HOME/state/mate.meta" "$HOME_DIR" \
  "fmtest:fm-mate" firstmate claude
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$SNAPSHOT" --json > "$TMP_ROOT/parent-snapshot.json" \
  || fail "parent fleet snapshot failed"
jq -e '
  .secondmate_current.records[0].provenance.selected == "structured-home"
  and .secondmate_current.records[0].provenance.summary_source == "local-ledger"
  and .secondmate_current.records[0].current.state == "no_active_work"
  and (.secondmate_current.records[0].active_children | length) == 0
  and (.secondmate_current.records[0].holds | length) == 0
' "$TMP_ROOT/parent-snapshot.json" >/dev/null \
  || fail "fleet snapshot did not consume the published local ledger: $(jq -c '.secondmate_current.records[0]' "$TMP_ROOT/parent-snapshot.json")"
pass "fleet snapshot consumes the published local ledger by default"

# Restore the established ledger, then stop a real writer while its real producer
# is blocked in a current-state read. The prior ledger must remain byte-identical
# and valid because no partial producer output is ever published at its path.
run_writer "$NOW_TWO" "$EPOCH_TWO" || fail "could not restore the real ledger"
printf 'working: replacement summary is being computed\n' \
  >> "$HOME_DIR/state/ledger-task.status"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/prior-ledger.json"
SLOW_MARKER="$TMP_ROOT/slow-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SLOW_MARKER" FM_TEST_NM_SLEEP=30 \
  "$WRITER" > "$TMP_ROOT/killed-writer.out" 2> "$TMP_ROOT/killed-writer.err" &
SLOW_WRITER_PID=$!
i=0
while [ ! -s "$SLOW_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$SLOW_WRITER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -s "$SLOW_MARKER" ] || fail "the real producer did not reach the controlled slow current-state read"
SLOW_NM_PID=$(cat "$SLOW_MARKER" 2>/dev/null || true)
writer_pgid=$(ps -o pgid= -p "$SLOW_WRITER_PID" 2>/dev/null | tr -d '[:space:]')
ancestor=$SLOW_NM_PID
child_pgid=
i=0
while [ "$i" -lt 20 ]; do
  ancestor_pgid=$(ps -o pgid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  parent=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d '[:space:]')
  if [ "$parent" = "$SLOW_WRITER_PID" ]; then
    if [ "$ancestor_pgid" != "$writer_pgid" ]; then
      SLOW_WORKER_PGID=$ancestor_pgid
    else
      SLOW_WORKER_PGID=$child_pgid
    fi
    break
  fi
  child_pgid=$ancestor_pgid
  ancestor=$parent
  i=$((i + 1))
done
case "$SLOW_WORKER_PGID" in
  ''|*[!0-9]*) fail "the bounded writer did not expose its worker process group" ;;
esac
[ "$SLOW_WORKER_PGID" != "$writer_pgid" ] \
  || fail "the bounded worker did not have an isolated process group"
kill -KILL -- "-$SLOW_WORKER_PGID" >/dev/null 2>&1 \
  || fail "the bounded writer process group could not be terminated"
wait "$SLOW_WRITER_PID" >/dev/null 2>&1 || true
SLOW_WRITER_PID=
SLOW_WORKER_PGID=
SLOW_NM_PID=
jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "killing the writer exposed invalid JSON at the ledger path"
cmp -s "$TMP_ROOT/prior-ledger.json" "$HOME_DIR/state/home-summary.json" \
  || fail "killing the writer replaced the prior complete ledger"

# Observe the ledger continuously through one successful replacement. Every read
# must parse, and the final document must be the newly computed complete summary.
READER_FAILURE="$TMP_ROOT/reader-failure"
SUCCESS_MARKER="$TMP_ROOT/success-no-mistakes.pid"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_TEST_NM_MARKER="$SUCCESS_MARKER" FM_TEST_NM_SLEEP=1 \
  "$WRITER" > "$TMP_ROOT/success-writer.out" 2> "$TMP_ROOT/success-writer.err" &
SLOW_WRITER_PID=$!
while kill -0 "$SLOW_WRITER_PID" 2>/dev/null; do
  if ! jq -e . "$HOME_DIR/state/home-summary.json" >/dev/null 2>&1; then
    : > "$READER_FAILURE"
    break
  fi
done
if ! wait "$SLOW_WRITER_PID"; then
  SLOW_WRITER_PID=
  fail "successful atomic replacement failed: $(cat "$TMP_ROOT/success-writer.err" 2>/dev/null)"
fi
SLOW_WRITER_PID=
[ ! -e "$READER_FAILURE" ] || fail "a reader observed torn JSON during atomic replacement"
jq -e --arg now "$NOW_THREE" --argjson epoch "$EPOCH_THREE" '
  .generated == $now and .generated_epoch == $epoch
' "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "the successful replacement did not publish the new complete document"
pass "writer kill and replacement preserve an atomic JSON ledger"

# Best-effort mode is the contract used by every lifecycle trigger. A failed
# producer records the failure and returns success without touching the ledger.
FAILBIN="$TMP_ROOT/failbin"
mkdir -p "$FAILBIN"
cat > "$FAILBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$FAILBIN/jq"
cp "$HOME_DIR/state/home-summary.json" "$TMP_ROOT/before-best-effort.json"
PATH="$FAILBIN:$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  "$WRITER" --best-effort \
  || fail "best-effort refresh propagated its producer failure"
cmp -s "$TMP_ROOT/before-best-effort.json" "$HOME_DIR/state/home-summary.json" \
  || fail "failed best-effort refresh changed the prior ledger"
grep -F 'summary producer failed' "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "best-effort refresh did not log its failure"
pass "best-effort publication logs and continues"

LOCK_MARKER="$TMP_ROOT/lock-held"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$HOME_DIR" "$LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$LOCK_MARKER" ] || fail "could not hold the publication lock for timeout coverage"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "lock timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on its lock"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_HOME_SUMMARY_TIMEOUT=1 "$WRITER" --best-effort \
  || fail "repeated lock timeout changed the best-effort caller result"
[ "$(grep -c 'refresh exceeded its 1-second deadline' "$HOME_DIR/state/.home-summary-refresh.log" 2>/dev/null || true)" -ge 2 ] \
  || fail "repeated publication lock timeouts vanished from failure reporting"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "best-effort refresh bounds publication lock acquisition"

HANGBIN="$TMP_ROOT/hangbin"
REAL_JQ=$(command -v jq)
VALIDATION_CODE="$TMP_ROOT/validation-code"
VALIDATION_MARKER="$TMP_ROOT/validation-started"
mkdir -p "$HANGBIN" "$VALIDATION_CODE"
# Use an already published document to reach validation within the one-second
# refresh budget, without recomputing the fleet inside this focused check.
for helper in fm-home-summary-refresh.sh fm-timeout-lib.sh fm-wake-lib.sh fm-path-lib.sh; do
  ln -s "$ROOT/bin/$helper" "$VALIDATION_CODE/$helper"
done
cp "$HOME_DIR/state/home-summary.json" "$VALIDATION_CODE/summary.json"
cat > "$VALIDATION_CODE/fm-fleet-snapshot.sh" <<'SH'
#!/bin/sh
exec cat "$FM_TEST_VALIDATION_DOCUMENT"
SH
cat > "$HANGBIN/jq" <<'SH'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    */.home-summary.json.*)
      printf '%s\n' "$$" > "$FM_TEST_VALIDATION_MARKER"
      sleep 30
      ;;
  esac
done
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$HANGBIN/jq" "$VALIDATION_CODE/fm-fleet-snapshot.sh"
started=$(date +%s)
PATH="$HANGBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" \
  FM_TEST_VALIDATION_DOCUMENT="$VALIDATION_CODE/summary.json" \
  FM_TEST_VALIDATION_MARKER="$VALIDATION_MARKER" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$VALIDATION_CODE/fm-home-summary-refresh.sh" --best-effort \
  || fail "validation timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ -s "$VALIDATION_MARKER" ] || fail "the refresh deadline expired before validation ran"
[ "$elapsed" -lt 4 ] || fail "best-effort refresh waited $elapsed seconds on validation"
grep -F 'refresh exceeded its 1-second deadline' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "publication validation timeout was not logged"
pass "best-effort refresh bounds validation and publication"

MKBIN="$TMP_ROOT/mkdir-hangbin"
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$MKBIN"
cat > "$MKBIN/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_TEST_STALLED_STATE" ]; then
    sleep 30
  fi
done
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
chmod +x "$MKBIN/mkdir"
started=$(date +%s)
PATH="$MKBIN:$FAKEBIN:$PATH" FM_TEST_REAL_MKDIR="$REAL_MKDIR" \
  FM_TEST_STALLED_STATE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$HOME_DIR" FM_HOME_SUMMARY_TIMEOUT=1 \
  "$WRITER" --best-effort >/dev/null 2>"$TMP_ROOT/stalled-state.err" \
  || fail "state initialization timeout changed the best-effort caller result"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 6 ] \
  || fail "best-effort refresh waited $elapsed seconds before bounded state initialization"
pass "best-effort refresh bounds state initialization"

SIGNALBIN="$TMP_ROOT/signalbin"
SIGNAL_MARKER="$TMP_ROOT/worker-signaled"
REAL_ENV=$(command -v env)
mkdir -p "$SIGNALBIN"
cat > "$SIGNALBIN/env" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_TEST_SIGNAL_MARKER" ]; then
  : > "$FM_TEST_SIGNAL_MARKER"
  exit 143
fi
exec "$FM_TEST_REAL_ENV" "$@"
SH
chmod +x "$SIGNALBIN/env"
rm -f "$HOME_DIR/state/.home-summary-refresh.log"
PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" "$WRITER" --best-effort \
  || fail "worker termination changed the best-effort caller result"
grep -F 'refresh worker failed with exit 143' \
  "$HOME_DIR/state/.home-summary-refresh.log" >/dev/null \
  || fail "worker termination was not logged at the parent boundary"
pass "best-effort refresh logs worker termination"

rm -f "$SIGNAL_MARKER" "$HOME_DIR/state/.home-summary-refresh.log"
mkdir "$HOME_DIR/state/.home-summary-refresh.log"
if ! PATH="$SIGNALBIN:$FAKEBIN:$PATH" FM_TEST_REAL_ENV="$REAL_ENV" \
  FM_TEST_SIGNAL_MARKER="$SIGNAL_MARKER" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" WRITER="$WRITER" python3 - <<'PY'
import os
import subprocess
import time

read_fd, write_fd = os.pipe()
os.set_blocking(write_fd, False)
try:
    while True:
        os.write(write_fd, b"x" * 4096)
except BlockingIOError:
    pass
os.set_blocking(write_fd, True)
started = time.monotonic()
try:
    result = subprocess.run(
        [os.environ["WRITER"], "--best-effort"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=write_fd,
        env=os.environ,
        timeout=7,
    )
finally:
    os.close(write_fd)
    os.close(read_fd)
elapsed = time.monotonic() - started
if result.returncode != 0:
    raise SystemExit(f"blocked failure logger changed caller result: {result.returncode}")
if elapsed >= 6:
    raise SystemExit(f"blocked failure logger exceeded its bound: {elapsed:.2f}s")
PY
then
  fail "best-effort failure reporting was not fully bounded"
fi
pass "best-effort refresh bounds failure reporting fallback"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "an unavailable failure record blocked valid publication"
jq -e --arg now "$NOW_ONE" '.generated == $now' \
  "$HOME_DIR/state/home-summary.json" >/dev/null \
  || fail "valid publication did not replace the ledger with an unavailable failure record"
rmdir "$HOME_DIR/state/.home-summary-refresh.log"
pass "valid publication ignores an unavailable failure record"

# --- publication cost, beacon isolation, and failure discoverability ---------
#
# The three regressions below all came from one live incident: in a real home
# whose tasks had accumulated ordinary status history, the producer needed
# minutes, so publication burned its whole deadline on every attempt, never
# published, starved the watcher's liveness beacon while it did, and said
# nothing about any of it because --best-effort is deliberately non-fatal.

# Publication cost must scale with what a home actually accumulates. Status
# history is append-only and unbounded, and the producer folds every task's
# whole stream, so an ordinary long-lived home is the real input - not the
# one-line log a freshly seeded fixture has. This home carries a status log of
# realistic width and depth and must still publish inside a deadline well under
# the default one.
COST_HOME="$TMP_ROOT/cost-home"
mkdir -p "$COST_HOME/state" "$COST_HOME/data" "$COST_HOME/config" \
  "$COST_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$COST_HOME/AGENTS.md"
printf 'cost\n' > "$COST_HOME/.fm-secondmate-home"
fm_git_init_commit "$COST_HOME/projects/task"
cat > "$COST_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] cost-task - Publish from an accumulated home (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$COST_HOME/state/cost-task.meta" \
  "window=fmtest:fm-cost-task" \
  "worktree=$COST_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.cost123456"
cost_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COST_HOME/state" cost-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COST_HOME/state" cost-task idle \
  --gen "$cost_busy_gen" --source claude-hook --event stop
python3 - "$COST_HOME/state/cost-task.status" <<'PY'
import sys
note = ("the crewmate ran validation and reported checks on the branch "
        "after review ") * 25
with open(sys.argv[1], "w") as handle:
    for i in range(300):
        handle.write(f"working: {note}({i})\n")
    handle.write("needs-decision [key=cost-gate]: which base to rebuild from\n")
PY
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COST_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  FM_HOME_SUMMARY_TIMEOUT=30 "$WRITER" --best-effort \
  || fail "accumulated-home publication changed the best-effort caller result"
[ -f "$COST_HOME/state/home-summary.json" ] \
  || fail "an accumulated home did not publish within a 30-second deadline: $(cat "$COST_HOME/state/.home-summary-refresh.log" 2>/dev/null)"
jq -e --arg home "$COST_HOME" '
  .schema == "fm-secondmate-home-summary.v1"
  and .home == $home
  and any(.decisions_open[]; .key == "cost-gate")
' "$COST_HOME/state/home-summary.json" >/dev/null \
  || fail "the accumulated home published a ledger missing its open decision"
pass "publication completes on a home carrying accumulated status history"

# One unreachable home must not extend publication without limit. A remote
# secondmate's current state is read over ssh, and ssh's own dead-peer detection
# deliberately never kills a slow-but-alive remote command, so nothing under the
# producer bounds that read on its own. Point the transport at a stub that never
# answers and require the producer to return anyway, reporting that home as
# unknown rather than waiting on it.
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/state" "$REMOTE_HOME/data" "$REMOTE_HOME/config" \
  "$REMOTE_HOME/projects" "$TMP_ROOT/sshbin"
printf '# Seeded Firstmate home\n' > "$REMOTE_HOME/AGENTS.md"
printf 'remote\n' > "$REMOTE_HOME/.fm-secondmate-home"
cat > "$REMOTE_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] rsm - Read remote current state (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
cat > "$REMOTE_HOME/data/secondmates.md" <<'EOF'
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
fm_write_meta "$REMOTE_HOME/state/rsm.meta" \
  "window=remote:rsm" \
  "endpoint_task_id=rsm" \
  "worktree=/remote/home/never-locally-present" \
  "harness=claude" \
  "kind=secondmate" \
  "mode=secondmate" \
  "home=/remote/home" \
  "remote_host=remote-mac" \
  "remote_root=/remote/root" \
  "remote_backend=herdr" \
  "remote_herdr_session=fm-remote" \
  "remote_target=fm-remote:w1:p1"
cat > "$TMP_ROOT/sshbin/stalled-ssh" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_SSH_CALLED"
cat > /dev/null
sleep 60
SH
chmod +x "$TMP_ROOT/sshbin/stalled-ssh"
started=$(date +%s)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REMOTE_HOME" \
  FM_SSH_BIN="$TMP_ROOT/sshbin/stalled-ssh" FM_TEST_SSH_CALLED="$TMP_ROOT/stalled-ssh.called" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  FM_SNAPSHOT_CREW_STATE_TIMEOUT=2 \
  "$SNAPSHOT" --secondmate-home-summary > "$TMP_ROOT/stalled-summary.json" \
  || fail "an unreachable remote home failed the whole producer"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 40 ] \
  || fail "the producer waited $elapsed seconds despite skipping remote endpoint state"
[ ! -e "$TMP_ROOT/stalled-ssh.called" ] \
  || fail "the producer issued a remote per-task state probe"
jq -e '
  .schema == "fm-secondmate-home-summary.v1"
  and .valid == false
  and .state == "unknown"
  and .invalidity.kind == "child_current_unavailable"
  and (.invalidity.ids == ["rsm"])
  and any(.endpoints[]; .id == "rsm" and .state == "unknown")
' "$TMP_ROOT/stalled-summary.json" >/dev/null \
  || fail "an unreachable remote task was not reported as unknown"
pass "producer skips remote per-task state probes"

# The watcher's beacon is what the rest of supervision reads as proof it is
# alive. Publication is side-band, so no matter how long it takes, the beacon
# must keep advancing. Hold the publication lock for the whole observation
# window, then require the beacon to keep ticking anyway.
BEAT_HOME="$TMP_ROOT/beat-home"
mkdir -p "$BEAT_HOME/state" "$BEAT_HOME/data" "$BEAT_HOME/config" \
  "$BEAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$BEAT_HOME/AGENTS.md"
printf 'beat\n' > "$BEAT_HOME/.fm-secondmate-home"
cat > "$BEAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
BEAT_LOCK_MARKER="$TMP_ROOT/beat-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 120
' _ "$ROOT" "$BEAT_HOME" "$BEAT_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$BEAT_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_LOCK_MARKER" ] || fail "could not stall publication for beacon coverage"
PATH="$FAKEBIN:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=1 FM_HOME_SUMMARY_TIMEOUT=90 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/beat-watch.out" 2> "$TMP_ROOT/beat-watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$BEAT_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$BEAT_HOME/state/.last-watcher-beat" ] \
  || fail "the stalled-publication watcher never beat: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
beat_mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' "$1"; }
seen=0
last=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
i=0
while [ "$seen" -lt 3 ] && [ "$i" -lt 200 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null \
    || fail "the stalled-publication watcher exited: $(cat "$TMP_ROOT/beat-watch.err" 2>/dev/null)"
  sleep 0.1
  now=$(beat_mtime "$BEAT_HOME/state/.last-watcher-beat")
  if [ "$now" != "$last" ]; then
    seen=$((seen + 1))
    last=$now
  fi
  i=$((i + 1))
done
[ "$seen" -ge 3 ] \
  || fail "the beacon advanced only $seen time(s) in 20 seconds while publication was stalled"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
pass "a stalled publication does not delay the watcher liveness beacon"

RESTART_HOME="$TMP_ROOT/restart-home"
mkdir -p "$RESTART_HOME/state" "$RESTART_HOME/data" "$RESTART_HOME/config" \
  "$RESTART_HOME/projects/task"
printf '# Seeded Firstmate home\n' > "$RESTART_HOME/AGENTS.md"
printf 'restart\n' > "$RESTART_HOME/.fm-secondmate-home"
fm_git_init_commit "$RESTART_HOME/projects/task"
cat > "$RESTART_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] restart-task - Preserve publication single flight (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$RESTART_HOME/state/restart-task.meta" \
  "window=fmtest:fm-restart-task" \
  "worktree=$RESTART_HOME/projects/task" \
  "project=firstmate" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "spawn_gen=fm.restart123456"
RESTART_LOCK_MARKER="$TMP_ROOT/restart-lock-held"
# Keep the lock owner alive until explicitly killed below. The real producer
# retains its normal deadline so startup latency is not a lock-queue verdict.
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  exec sleep 180
' _ "$ROOT" "$RESTART_HOME" "$RESTART_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$RESTART_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_LOCK_MARKER" ] || fail "could not hold the publication lock for restart coverage"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=60 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-one.out" 2> "$TMP_ROOT/restart-watch-one.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the first restart watcher did not begin polling"
printf 'needs-decision [key=restart-gate]: restart the watcher\n' \
  > "$RESTART_HOME/state/restart-task.status"
i=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
kill -0 "$WATCH_PID" 2>/dev/null \
  && fail "the first restart watcher did not surface its actionable signal"
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
rm -f "$RESTART_HOME/state/.last-watcher-beat"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=60 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/restart-watch-two.out" 2> "$TMP_ROOT/restart-watch-two.err" &
WATCH_PID=$!
i=0
while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
  || fail "the replacement restart watcher did not begin polling"
sleep 4
[ ! -e "$RESTART_HOME/state/.home-summary-attempt" ] \
  || fail "watcher restart began a publication while the refresh lock was held"
[ -e "$RESTART_HOME/state/.home-summary-dirty" ] \
  || fail "watcher restart lost the pending publication request"
[ ! -s "$RESTART_HOME/state/.home-summary-refresh.log" ] \
  || fail "watcher restart failed before publication lock release: $(cat "$RESTART_HOME/state/.home-summary-refresh.log")"
if ! kill -0 "$WATCH_PID" 2>/dev/null; then
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  rm -f "$RESTART_HOME/state/.last-watcher-beat"
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=60 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/restart-watch-three.out" 2> "$TMP_ROOT/restart-watch-three.err" &
  WATCH_PID=$!
  i=0
  while [ ! -e "$RESTART_HOME/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$RESTART_HOME/state/.last-watcher-beat" ] \
    || fail "the recovery replacement watcher did not begin polling"
fi
kill -KILL "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
# A replacement watcher may still be cancelling its detached refresh here.
# This required publication must wait for that lock; an idle-only attempt can
# legitimately skip it and leave no publisher after the watcher exits.
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$RESTART_HOME" \
  "$WRITER" --best-effort \
  || fail "stale-lock recovery changed the best-effort caller result"
i=0
while [ ! -e "$RESTART_HOME/state/home-summary.json" ] && [ "$i" -lt 1200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -e "$RESTART_HOME/state/home-summary.json" ] \
  || fail "a dead publication lock wedged publication"
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
pass "publication remains single-flight across watcher restart"

# A publication that keeps failing is deliberately non-fatal to its caller, so
# the only way an operator learns about it is a session start saying so. Seed
# the home-local failure record a real failing home would have, and require the
# check a session start already runs to name it - then go quiet once the ledger
# is published again.
REPORT_HOME="$TMP_ROOT/report-home"
mkdir -p "$REPORT_HOME/state" "$REPORT_HOME/data" "$REPORT_HOME/config" \
  "$REPORT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$REPORT_HOME/AGENTS.md"
printf 'report\n' > "$REPORT_HOME/.fm-secondmate-home"
cat > "$REPORT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat > "$REPORT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] refresh exceeded its 60-second deadline
[2026-08-28T09:59:00Z] refresh exceeded its 60-second deadline
EOF
run_bootstrap_detect() {
  local threshold=${2:-2}
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_HOME_SUMMARY_FAILURE_REPORT="$threshold" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

COMPAT_HOME="$TMP_ROOT/compat-home"
mkdir -p "$COMPAT_HOME/state" "$COMPAT_HOME/data" "$COMPAT_HOME/config" \
  "$COMPAT_HOME/projects"
printf '# Seeded Firstmate home\n' > "$COMPAT_HOME/AGENTS.md"
printf 'compat\n' > "$COMPAT_HOME/.fm-secondmate-home"
cat > "$COMPAT_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$WRITER" || fail "could not seed the compatibility ledger"
cat > "$COMPAT_HOME/state/.home-summary-refresh.log" <<'EOF'
[2026-08-28T09:58:00Z] historical failure before publication
[2026-08-28T09:59:00Z] historical failure before publication
[2026-08-28T10:01:00Z] first failure after publication
EOF
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "historical failures satisfied the current publication threshold: $compat_out"
    ;;
esac
printf '[2026-08-28T10:02:00Z] second failure after publication\n' \
  >> "$COMPAT_HOME/state/.home-summary-refresh.log"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
printf '%s\n' "$compat_out" | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "current publication failures did not satisfy the report threshold: $compat_out"
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$COMPAT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not republish the compatibility ledger"
compat_out=$(run_bootstrap_detect "$COMPAT_HOME")
case "$compat_out" in
  *HOME_SUMMARY:*)
    fail "republishing did not scope retained failure history: $compat_out"
    ;;
esac
pass "bootstrap scopes retained failures to the current publication"

# A timed-out attempt can finish recording after a newer ledger is published.
# Its record must retain the attempt's ordering rather than look like a failure
# of the newer publication and keep the session-start diagnostic active.
ORDER_HOME="$TMP_ROOT/order-home"
ORDER_DATE_BIN="$TMP_ROOT/order-date-bin"
mkdir -p "$ORDER_HOME/state" "$ORDER_HOME/data" "$ORDER_HOME/config" \
  "$ORDER_HOME/projects" "$ORDER_DATE_BIN"
printf '# Seeded Firstmate home\n' > "$ORDER_HOME/AGENTS.md"
printf 'order\n' > "$ORDER_HOME/.fm-secondmate-home"
cat > "$ORDER_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
REAL_DATE=$(command -v date)
cat > "$ORDER_DATE_BIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = -u ] && [ "$2" = +%Y-%m-%dT%H:%M:%SZ ]; then
  python3 - "$FM_TEST_ORDER_START" "$FM_TEST_ORDER_EARLY" "$FM_TEST_ORDER_LATE" <<'PY'
import sys
import time

started = float(sys.argv[1])
print(sys.argv[2] if time.time() - started < 1 else sys.argv[3])
PY
  exit 0
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
chmod +x "$ORDER_DATE_BIN/date"
ORDER_LOCK_MARKER="$TMP_ROOT/order-lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$ORDER_HOME" "$ORDER_LOCK_MARKER" &
LOCK_HOLDER_PID=$!
i=0
while [ ! -e "$ORDER_LOCK_MARKER" ] && [ "$i" -lt 100 ]; do
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
  sleep 0.05
  i=$((i + 1))
done
[ -e "$ORDER_LOCK_MARKER" ] || fail "could not hold the publication lock for ordering coverage"
order_started=$(python3 -c 'import time; print(time.time())')
PATH="$ORDER_DATE_BIN:$FAKEBIN:$PATH" FM_TEST_REAL_DATE="$REAL_DATE" \
  FM_TEST_ORDER_START="$order_started" FM_TEST_ORDER_EARLY="$NOW_ONE" \
  FM_TEST_ORDER_LATE="$NOW_THREE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ORDER_HOME" FM_HOME_SUMMARY_TIMEOUT=2 \
  "$WRITER" --best-effort \
  || fail "ordered timeout changed the best-effort caller result"
kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
LOCK_HOLDER_PID=
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ORDER_HOME" \
  FM_SNAPSHOT_NOW="$NOW_TWO" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_TWO" \
  "$WRITER" || fail "could not publish after the ordered timeout"
order_out=$(run_bootstrap_detect "$ORDER_HOME" 1)
case "$order_out" in
  *HOME_SUMMARY:*)
    fail "a pre-publication attempt was reported after the newer ledger: $order_out"
    ;;
esac
pass "failure records preserve refresh attempt ordering"

report_out=$(run_bootstrap_detect "$REPORT_HOME")
printf '%s\n' "$report_out" \
  | grep -F 'HOME_SUMMARY: this home has never published state/home-summary.json' \
    >/dev/null \
  || fail "a home that never published its ledger was reported as silent: $report_out"
printf '%s\n' "$report_out" \
  | grep -F '2 failed attempt(s)' >/dev/null \
  || fail "the publication report omitted the recorded failure count: $report_out"
printf '%s\n' "$report_out" \
  | grep -F 'refresh exceeded its 60-second deadline' >/dev/null \
  || fail "the publication report omitted the recorded reason: $report_out"

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REPORT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_THREE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_THREE" \
  "$WRITER" || fail "could not publish the ledger that clears the report"
report_out=$(run_bootstrap_detect "$REPORT_HOME")
case "$report_out" in
  *HOME_SUMMARY:*)
    fail "a published ledger still reported stale publication failures: $report_out"
    ;;
esac
pass "repeated publication failure is reported at session start until it clears"

REQUEST_BIN="$TMP_ROOT/request-bin"
mkdir -p "$REQUEST_BIN"
for library in fm-home-summary-refresh.sh fm-wake-lib.sh fm-path-lib.sh fm-timeout-lib.sh; do
  ln -s "$ROOT/bin/$library" "$REQUEST_BIN/$library"
done
REQUEST_WRITER="$REQUEST_BIN/fm-home-summary-refresh.sh"
REQUEST_REAL_STAT=$(command -v stat)
REQUEST_REAL_RM=$(command -v rm)
cat > "$REQUEST_BIN/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
event=$(cat "$FM_HOME/state/event")
printf '%s\n' "$event" >> "$FM_HOME/state/walks"
if [ -e "$FM_HOME/state/hold" ]; then
  : > "$FM_HOME/state/producer-started"
  while [ "$(cat "$FM_HOME/state/hold")" = wait ]; do sleep 0.05; done
fi
if [ -e "$FM_HOME/state/signal" ]; then
  kill -TERM "$PPID"
  exit 0
fi
if [ -e "$FM_HOME/state/delay" ]; then sleep 30; fi
[ ! -e "$FM_HOME/state/fail" ] || exit 23
jq -n --arg home "$FM_HOME" --arg event "$event" '{
  schema:"fm-secondmate-home-summary.v1",hold_classifier_schema:"fm-captain-hold-buckets.v1",
  home:$home,generated:"2026-08-28T10:00:00Z",generated_epoch:1787911200,
  valid:true,state:$event,invalidity:{},active_children:[],decisions_open:[],
  holds:[],queued:[],landed:[],endpoints:[],counts:{},omitted:[]
}'
SH
cat > "$REQUEST_BIN/stat" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_HOME/state/home-summary.json" ] && [ -e "$FM_HOME/state/ledger-time" ]; then
  stamp=$(cat "$FM_HOME/state/ledger-time")
  if [ "$stamp" = now ]; then date +%s; else printf '%s\n' "$stamp"; fi
  exit 0
fi
exec "$FM_TEST_REQUEST_STAT" "$@"
SH
cat > "$REQUEST_BIN/rm" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_HOME/state/.home-summary-drain.lock" ] \
  && [ -e "$FM_HOME/state/handoff-armed" ] && [ ! -e "$FM_HOME/state/.home-summary-dirty" ]; then
  mv "$FM_HOME/state/handoff-armed" "$FM_HOME/state/handoff-fired"
  printf 'after\n' > "$FM_HOME/state/event"
  "$FM_TEST_REQUEST_WRITER" --request || exit 1
fi
exec "$FM_TEST_REQUEST_RM" "$@"
SH
chmod +x "$REQUEST_BIN/fm-fleet-snapshot.sh" "$REQUEST_BIN/stat" "$REQUEST_BIN/rm"

request_fixture() {
  local home="$TMP_ROOT/request-$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  printf 'before\n' > "$home/state/event"
  printf '%s\n' "$home"
}

run_request_writer() {
  local home=$1 interval=$2
  shift 2
  PATH="$REQUEST_BIN:$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_HOME_SUMMARY_IF_IDLE=0 FM_HOME_SUMMARY_INTERVAL="$interval" \
    FM_HOME_SUMMARY_TIMEOUT="${FM_TEST_REQUEST_TIMEOUT:-5}" \
    FM_TEST_REQUEST_STAT="$REQUEST_REAL_STAT" FM_TEST_REQUEST_RM="$REQUEST_REAL_RM" \
    FM_TEST_REQUEST_WRITER="$REQUEST_WRITER" "$REQUEST_WRITER" "$@"
}

wait_request_condition() {
  local tries=0
  until "$@"; do
    [ "$tries" -lt 200 ] || return 1
    sleep 0.05
    tries=$((tries + 1))
  done
}

request_walks_equal() {
  local count=0
  [ ! -f "$1/state/walks" ] || count=$(wc -l < "$1/state/walks")
  [ "$count" -eq "$2" ]
}

request_is_idle() {
  [ ! -e "$1/state/.home-summary-drain.lock" ] && [ ! -e "$1/state/.home-summary-dirty" ]
}

REQUEST_HOME=$(request_fixture zero-age)
printf '{}\n' > "$REQUEST_HOME/state/home-summary.json"
printf 'now\n' > "$REQUEST_HOME/state/ledger-time"
run_request_writer "$REQUEST_HOME" 30 --request || fail "zero-age request failed"
wait_request_condition test -e "$REQUEST_HOME/state/.home-summary-drain.lock" \
  || fail "zero-age request did not start its drain"
sleep 1
request_walks_equal "$REQUEST_HOME" 0 || fail "zero-age ledger permitted another walk"
printf '0\n' > "$REQUEST_HOME/state/ledger-time"
wait_request_condition request_walks_equal "$REQUEST_HOME" 1 \
  || fail "the due ledger did not publish"
wait_request_condition request_is_idle "$REQUEST_HOME" || fail "zero-age drain did not finish"
pass "a ledger in the current second defers publication for the interval"

REQUEST_HOME=$(request_fixture future)
printf '{}\n' > "$REQUEST_HOME/state/home-summary.json"
printf '4102444800\n' > "$REQUEST_HOME/state/ledger-time"
run_request_writer "$REQUEST_HOME" 30 --request || fail "future-ledger request failed"
wait_request_condition request_walks_equal "$REQUEST_HOME" 1 \
  || fail "a strictly future ledger was not immediately due"
wait_request_condition request_is_idle "$REQUEST_HOME" || fail "future-ledger drain did not finish"
pass "a strictly future ledger remains immediately due"

for entry in request request-worker; do
  for future in ledger attempt; do
    REQUEST_HOME=$(request_fixture "$entry-future-$future")
    printf '{}\n' > "$REQUEST_HOME/state/home-summary.json"
    if [ "$future" = ledger ]; then
      printf '4102444800\n' > "$REQUEST_HOME/state/ledger-time"
      date +%s > "$REQUEST_HOME/state/.home-summary-attempt"
    else
      printf 'now\n' > "$REQUEST_HOME/state/ledger-time"
      printf '4102444800\n' > "$REQUEST_HOME/state/.home-summary-attempt"
    fi
    if [ "$entry" = request ]; then
      run_request_writer "$REQUEST_HOME" 30 --request || fail "future-$future request failed"
      wait_request_condition test -e "$REQUEST_HOME/state/.home-summary-drain.lock" \
        || fail "future-$future request did not start its drain"
      sleep 1
    else
      : > "$REQUEST_HOME/state/.home-summary-dirty"
      run_request_writer "$REQUEST_HOME" 30 --_request-worker \
        || fail "future-$future locked worker failed"
    fi
    request_walks_equal "$REQUEST_HOME" 0 \
      || fail "$entry let a future $future bypass the other timestamp's cooldown"
    [ -e "$REQUEST_HOME/state/.home-summary-dirty" ] \
      || fail "$entry consumed a mark during a valid cooldown"
    printf '0\n' > "$REQUEST_HOME/state/ledger-time"
    printf '0\n' > "$REQUEST_HOME/state/.home-summary-attempt"
    run_request_writer "$REQUEST_HOME" 30 --request || fail "due $entry request failed"
    wait_request_condition request_walks_equal "$REQUEST_HOME" 1 \
      || fail "$entry did not publish after both cooldowns elapsed"
    wait_request_condition request_is_idle "$REQUEST_HOME" || fail "$entry drain did not finish"
  done
done
pass "future timestamps cannot mask valid cooldowns in the drain or locked worker"

# Allow worker startup before bounding the fixture's deliberate 30-second stall.
for result in success failure timeout; do
  REQUEST_HOME=$(request_fixture "restart-$result")
  case "$result" in
    failure)
      : > "$REQUEST_HOME/state/fail"
      printf '{}\n' > "$REQUEST_HOME/state/home-summary.json"
      printf '0\n' > "$REQUEST_HOME/state/ledger-time"
      ;;
    timeout) : > "$REQUEST_HOME/state/delay" ;;
  esac
  FM_TEST_REQUEST_TIMEOUT=5 run_request_writer "$REQUEST_HOME" 30 --request \
    || fail "$result request failed"
  wait_request_condition request_walks_equal "$REQUEST_HOME" 1 \
    || fail "$result producer did not start"
  wait_request_condition request_is_idle "$REQUEST_HOME" \
    || fail "$result drain did not finish"
  if [ "$result" = success ]; then
    mv "$REQUEST_HOME/state/home-summary.json" "$REQUEST_HOME/state/previous-ledger.json"
  fi
  FM_TEST_REQUEST_TIMEOUT=5 run_request_writer "$REQUEST_HOME" 30 --request \
    || fail "$result successor request failed"
  wait_request_condition test -e "$REQUEST_HOME/state/.home-summary-drain.lock" \
    || fail "$result successor drain did not start"
  sleep 1
  request_walks_equal "$REQUEST_HOME" 1 \
    || fail "$result drain exit discarded the publication cooldown"
  printf '0\n' > "$REQUEST_HOME/state/.home-summary-attempt"
  wait_request_condition request_walks_equal "$REQUEST_HOME" 2 \
    || fail "$result successor did not publish when due"
  wait_request_condition request_is_idle "$REQUEST_HOME" \
    || fail "$result successor drain did not finish"
  if [ "$result" = timeout ]; then
    timeout_report=$(run_bootstrap_detect "$REQUEST_HOME")
    assert_contains "$timeout_report" '2 failed attempt(s)' "drain timeouts did not reach the bootstrap diagnostic"
    assert_contains "$timeout_report" 'refresh exceeded its 5-second deadline' "drain timeout reason was not recorded"
    python3 - "$REQUEST_HOME/state/.home-summary-refresh.log" \
      "$REQUEST_HOME/state/.home-summary-attempt" <<'PY' || fail "drain failure lost its attempt ordering"
from datetime import datetime, timezone
from pathlib import Path
import sys

last_failure = Path(sys.argv[1]).read_text().splitlines()[-1]
stamp = last_failure.split("]", 1)[0][1:]
failure_epoch = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
attempt_epoch = int(Path(sys.argv[2]).read_text())
if failure_epoch > attempt_epoch:
    raise SystemExit("timeout was stamped after the publication attempt")
PY
  fi
done
pass "successful, failed, and timed-out attempts retain cooldown across drain exit"

REQUEST_HOME=$(request_fixture signal)
: > "$REQUEST_HOME/state/signal"
run_request_writer "$REQUEST_HOME" 30 --request || fail "signaled request failed"
wait_request_condition request_walks_equal "$REQUEST_HOME" 1 || fail "signaled producer did not start"
wait_request_condition request_is_idle "$REQUEST_HOME" || fail "signaled drain did not finish"
signal_report=$(run_bootstrap_detect "$REQUEST_HOME" 1)
assert_contains "$signal_report" '1 failed attempt(s)' "drain signal did not reach the bootstrap diagnostic"
assert_contains "$signal_report" 'refresh worker failed with exit 143' "drain signal reason was not recorded"
pass "drain timeout and signal failures reach the bounded bootstrap diagnostic"

REQUEST_HOME=$(request_fixture busy)
printf 'wait\n' > "$REQUEST_HOME/state/hold"
run_request_writer "$REQUEST_HOME" 1 &
SLOW_WRITER_PID=$!
wait_request_condition test -e "$REQUEST_HOME/state/producer-started" \
  || fail "synchronous publication did not start"
printf 'after\n' > "$REQUEST_HOME/state/event"
run_request_writer "$REQUEST_HOME" 1 --request || fail "busy publication request failed"
sleep 2
[ -e "$REQUEST_HOME/state/.home-summary-dirty" ] \
  || fail "a busy publication discarded its pending request"
request_walks_equal "$REQUEST_HOME" 1 || fail "a request overlapped the synchronous publication"
printf 'release\n' > "$REQUEST_HOME/state/hold"
wait "$SLOW_WRITER_PID" || fail "synchronous publication failed"
SLOW_WRITER_PID=
wait_request_condition request_walks_equal "$REQUEST_HOME" 2 \
  || fail "the pending request did not publish after lock release"
wait_request_condition request_is_idle "$REQUEST_HOME" || fail "busy publication drain did not finish"
jq -e '.state == "after"' "$REQUEST_HOME/state/home-summary.json" >/dev/null \
  || fail "the pending event was absent from the ledger"
pass "a request survives an older synchronous publication and publishes its own event"

REQUEST_HOME=$(request_fixture handoff)
: > "$REQUEST_HOME/state/handoff-armed"
run_request_writer "$REQUEST_HOME" 1 --request || fail "handoff request failed"
wait_request_condition test -e "$REQUEST_HOME/state/handoff-fired" \
  || fail "the request did not arrive during drain shutdown"
wait_request_condition request_walks_equal "$REQUEST_HOME" 2 \
  || fail "a request during drain shutdown was stranded"
wait_request_condition request_is_idle "$REQUEST_HOME" || fail "handoff drain did not finish"
jq -e '.state == "after"' "$REQUEST_HOME/state/home-summary.json" >/dev/null \
  || fail "the shutdown request was absent from the ledger"
pass "a request arriving during drain shutdown is published without another trigger"
