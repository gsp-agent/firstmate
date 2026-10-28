#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
fm_test_trap_process_cleanup "$TMP_ROOT"
export NODE_NO_WARNINGS=1

run_case() {
  "$@"
  fm_test_stop_processes
}

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages node_pid
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  fm_test_track_watcher_state "$home/state"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
printf '%s\t%s\n' "\$\$" "\$(LC_ALL=C ps -o lstart= -p "\$\$")" >> "\$FM_TEST_PIDS"
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  # This exercises recovery delivery, not the startup deadline. Keep the Pi
  # readiness bound above the arm's while loaded hosts schedule startup helpers.
  PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_ARM_CONFIRM_TIMEOUT=60 FM_PI_ARM_READY_TIMEOUT_MS=65000 \
      FM_WATCH_EXTENSION_LOG_KEEP_LINES=100 \
      node --input-type=module > "$home/node.out" 2>&1 <<'EOF' &
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
const armed = await tool.execute("tool-call-t1", {}, undefined, undefined, {});
if (!armed.details.ok) throw new Error(`Pi did not arm: ${armed.details.message}`);
const deadline = Date.now() + 150000;
let firstAt = 0;
while (firstAt ? Date.now() - firstAt < 55000 : Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  const evidence = [".watch-extension.log", ".watch-cycle-exits.log", ".watcher-down", ".wake-queue"]
    .map((name) => `${name}: ${existsSync(`${process.env.FM_HOME}/state/${name}`) ? readFileSync(`${process.env.FM_HOME}/state/${name}`, "utf8") : "absent"}`)
    .join("\n");
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}\n${evidence}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  node_pid=$!
  fm_test_track_pid "$node_pid"
  status=0
  wait "$node_pid" || status=$?
  out=$(cat "$home/node.out")
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$!"
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  # The assertion is a real crew wake, never the old synthetic recovery exit.
  # Allow startup's short-lived helpers headroom on a contended host.
  while [ "$now" -lt 120 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_ELAPSED_SECONDS=%s\n' "$(( $(date +%s) - event_start ))"
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# The supervision host starts an engine turn only on a watcher close, so on a
# host home a recovery over branch-owned rows closes on the oldest row as
# itself instead of being absorbed as it is where the away daemon reads rows.
# A row a live PM owns is that PM's to read, so the close passes over it.
test_host_recovery_closes_on_its_oldest_branch_row() {
  local dir home state child now out status
  dir=$(make_case recovery-host-branch-rows)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$home/config"
  : > "$home/config/supervision-host"
  printf 'pending:downtime:host.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf 'bead=test-bead\npid=%s\ntask=pm-demo\n' "$$" > "$state/.pm-live-pm-demo"
  append_wake "$state" signal pm-demo.status "signal: $state/pm-demo.status" \
    || fail "could not append the live-PM-owned durable wake"
  append_wake "$state" signal demo.status "signal: $state/demo.status" \
    || fail "could not append the first branch-owned durable wake"
  append_wake "$state" signal other.status "signal: $state/other.status" \
    || fail "could not append the second branch-owned durable wake"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_DAEMON_OWNS_SUPERVISION='' "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$!"
  now=0
  while [ "$now" -lt 40 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.5
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a host recovery over branch rows did not close: $(cat "$out")"
  fi
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "host branch-row recovery watcher exit"
  [ "$(grep -cE '^(signal|stale|check|heartbeat)' "$out" || true)" -eq 1 ] \
    || fail "a host recovery over branch rows did not close exactly once: $(cat "$out")"
  grep -qx "signal: $state/demo.status" "$out" \
    || fail "a host recovery did not close on its oldest row as itself: $(cat "$out")"
  [ "$(grep -c "$(printf '\tsignal\t')" "$state/.wake-queue")" -eq 3 ] \
    || fail "the recovery close consumed durable rows its owner's drain must read"
  pass "a host recovery over branch-owned rows closes on the oldest row as itself"
}

# On a plain home main owns every row a live PM does not, and those reach
# main as the generic resurface, so a queue holding only live-PM-owned rows
# stays absorbed in the poll loop exactly as before.
test_plain_recovery_over_live_pm_rows_stays_quiet() {
  local dir home state child now out
  dir=$(make_case recovery-plain-pm-rows)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$home/config"
  printf 'pending:downtime:plain.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf 'bead=test-bead\npid=%s\ntask=pm-demo\n' "$$" > "$state/.pm-live-pm-demo"
  append_wake "$state" signal pm-demo.status "signal: $state/pm-demo.status" \
    || fail "could not append the live-PM-owned durable wake"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_DAEMON_OWNS_SUPERVISION='' "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$!"
  now=0
  while [ "$now" -lt 10 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.5
    now=$((now + 1))
  done
  kill -0 "$child" 2>/dev/null \
    || fail "a plain-home recovery over live-PM rows closed: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if grep -qE '^(signal|stale|check|heartbeat)' "$out"; then
    fail "a plain-home recovery over live-PM rows woke main: $(cat "$out")"
  fi
  grep -q "$(printf '\tsignal\tpm-demo.status\t')" "$state/.wake-queue" \
    || fail "the live-PM-owned durable wake was not retained"
  pass "a plain-home recovery over live-PM-owned rows stays in its poll loop"
}

# A resurface whose wake line never reached stdout (the checkpoint's output
# is unwritable) delivered nothing, so cleanup must not preserve the marker
# as announced: the episode goes back to pending and a later watcher closes
# on the oldest row again.
test_host_recovery_with_failed_output_retries_the_close() {
  local dir home state child now out status
  dir=$(make_case recovery-host-failed-output)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$home/config"
  : > "$home/config/supervision-host"
  printf 'pending:downtime:host.2.bbb\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  append_wake "$state" signal demo.status "signal: $state/demo.status" \
    || fail "could not append the branch-owned durable wake"
  mkfifo "$dir/watch.fifo"
  ( trap '' PIPE
    PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
      FM_DAEMON_OWNS_SUPERVISION='' exec "$WATCH" ) > "$dir/watch.fifo" 2> "$dir/watch.err" &
  child=$!
  fm_test_track_pid "$!"
  # Unblock the writer's open, then leave it no reader: its wake write fails.
  exec 9< "$dir/watch.fifo"
  exec 9<&-
  now=0
  while [ "$now" -lt 40 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.5
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a host recovery with unwritable output did not exit: $(cat "$dir/watch.err")"
  fi
  status=0
  wait "$child" || status=$?
  [ "$status" -ne 0 ] \
    || fail "a host recovery whose wake could not be written exited 0"
  grep -q '^pending:downtime:' "$state/.watcher-down" \
    || fail "a failed resurface left the episode announced instead of pending: $(cat "$state/.watcher-down")"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_FOREGROUND_CHECKPOINT=1 \
    FM_DAEMON_OWNS_SUPERVISION='' "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$!"
  now=0
  while [ "$now" -lt 40 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.5
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "the retried host recovery did not close: $(cat "$out")"
  fi
  status=0
  wait "$child" || status=$?
  expect_code 0 "$status" "retried host recovery watcher exit"
  grep -qx "signal: $state/demo.status" "$out" \
    || fail "the retried host recovery did not close on its oldest row: $(cat "$out")"
  pass "a host recovery whose wake could not be written retries the close"
}

# The old row's sequence is the counter at start. A later note is a higher
# sequence, so only that note closes this successor.
test_handling_successor_closes_on_a_row_newer_than_its_start() {
  local dir home state child now out old new
  dir=$(make_case successor-newer-row)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$home/config"
  printf 'pending:downtime:park.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  old='check: old row queued before the successor started'
  new='check: captain inbox note n1 - hello'
  printf '%s\t4\tcheck\told\t%s\n' "$(date +%s)" "$old" > "$state/.wake-queue"
  printf '4\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$child"
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
      && [ -f "$state/.last-watcher-beat" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    && [ -f "$state/.last-watcher-beat" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not reach its first poll"; }
  kill -0 "$child" 2>/dev/null \
    || { fail "the row queued before start closed the successor: $(cat "$out")"; }
  ! grep -F "$old" "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "the row queued before start was delivered: $(cat "$out")"; }
  append_wake "$state" check "inbox:n1" "$new" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the newer note"; }
  now=0
  while [ "$now" -lt 40 ]; do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.5
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a note newer than the successor start did not close it: $(cat "$out")"
  fi
  wait "$child" 2>/dev/null || true
  grep -Fx "$new" "$out" >/dev/null \
    || fail "the successor did not close on the newer note: $(cat "$out")"
  ! grep -F "$old" "$out" >/dev/null \
    || fail "the successor also delivered the older row: $(cat "$out")"
  pass "a handling successor closes on a main row newer than its start and leaves the older row"
}

# fm-procevent.sh reconcile re-appends an unhandled result every cycle under a
# fresh sequence. That twin of a row queued at the successor's start is the old
# row again, so it must not close the successor. A later row that differs only
# in payload is new work and still does.
test_handling_successor_ignores_a_reappended_start_row() {
  local dir home state child now out old new appended beat first second
  dir=$(make_case successor-reappended-row)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data" "$home/config"
  printf 'pending:downtime:park.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  old='check: captain inbox note n1 - queued before the successor started'
  new='check: captain inbox note n1 - edited after the successor started'
  printf '%s\t4\tcheck\tinbox:n1\t%s\n' "$(date +%s)" "$old" > "$state/.wake-queue"
  printf '4\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_pid "$child"
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
      && [ -f "$state/.last-watcher-beat" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    && [ -f "$state/.last-watcher-beat" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not reach its first poll"; }
  append_wake "$state" check "inbox:n1" "$old" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not re-append the start row"; }
  grep -c "$(printf '\tcheck\tinbox:n1\t')" "$state/.wake-queue" | grep -qx 2 \
    || { kill -TERM "$child" 2>/dev/null || true; fail "the re-append did not queue a second row"; }
  # The beacon is stamped at the top of each poll, before the resurface check,
  # so a second beacon stamped after the append proves one whole poll saw it.
  appended=$(date +%s)
  first=
  second=
  now=0
  while [ "$now" -lt 240 ]; do
    kill -0 "$child" 2>/dev/null || break
    if [ "$(uname)" = Darwin ]; then
      beat=$(stat -f %m "$state/.last-watcher-beat" 2>/dev/null || true)
    else
      beat=$(stat -c %Y "$state/.last-watcher-beat" 2>/dev/null || true)
    fi
    if [ -n "$beat" ] && [ "$beat" -gt "$appended" ]; then
      if [ -z "$first" ]; then
        first=$beat
      elif [ "$beat" != "$first" ]; then
        second=$beat
        break
      fi
    fi
    sleep 0.25
    now=$((now + 1))
  done
  kill -0 "$child" 2>/dev/null \
    || fail "a re-append of the row queued at start closed the successor: $(cat "$out")"
  [ -n "$second" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "the successor never completed a poll after the re-append"; }
  ! grep -F "$old" "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "the re-appended start row was delivered: $(cat "$out")"; }
  append_wake "$state" check "inbox:n1" "$new" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "could not append the edited note"; }
  now=0
  while [ "$now" -lt 40 ]; do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.5
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "a note differing only in payload did not close the successor: $(cat "$out")"
  fi
  wait "$child" 2>/dev/null || true
  grep -Fx "$new" "$out" >/dev/null \
    || fail "the successor did not close on the edited note: $(cat "$out")"
  ! grep -F "$old" "$out" >/dev/null \
    || fail "the successor also delivered the start row: $(cat "$out")"
  pass "a handling successor ignores a re-append of its start row and still closes on new work"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  run_case "$FM_TEST_ONLY"
  exit
fi

run_case test_handling_successor_does_not_go_blind
run_case test_unacknowledged_recovery_is_announced_once_per_generation
run_case test_host_recovery_closes_on_its_oldest_branch_row
run_case test_plain_recovery_over_live_pm_rows_stays_quiet
run_case test_host_recovery_with_failed_output_retries_the_close
run_case test_handling_successor_closes_on_a_row_newer_than_its_start
run_case test_handling_successor_ignores_a_reappended_start_row
