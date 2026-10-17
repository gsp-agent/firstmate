#!/usr/bin/env bash
# dead-lock-section-full.sh <tree> <label> - instrumented copy of the whole
# "publication remains single-flight across watcher restart" block of
# tests/fm-home-summary-refresh.test.sh, run from <tree>: live lock holder,
# watcher one surfaces a needs-decision and exits, watcher two (and three if
# two exited) polls at FM_POLL=1 with the 2 s refresh bound, the holder is
# SIGKILLed, the FM_HOME_SUMMARY_IF_IDLE=1 best-effort writer runs, and the
# ledger is awaited for the suite's 200 x 0.05 s loop. Reports who published,
# the writer's wall time, the bare producer time on that home (with the open
# decision present), and the home's refresh failure log.
set -u
tree=$1 label=$2
# shellcheck disable=SC1091
. "$tree/tests/lib.sh"
ROOT=$tree
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-dead-lock-full)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
WATCH_PID= LOCK_HOLDER_PID=
cleanup() {
  for pid in "$WATCH_PID" "$LOCK_HOLDER_PID"; do
    [ -n "$pid" ] && kill -KILL "$pid" >/dev/null 2>&1
  done
  fm_test_cleanup
}
trap cleanup EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/no-mistakes"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"
watch_start() {  # <name>
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
    FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/$1.out" 2> "$TMP_ROOT/$1.err" &
  WATCH_PID=$!
  i=0
  while [ ! -e "$H/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.05; i=$((i + 1))
  done
}

H="$TMP_ROOT/restart-home"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/task"
printf '# Seeded Firstmate home\n' > "$H/AGENTS.md"
printf 'restart\n' > "$H/.fm-secondmate-home"
fm_git_init_commit "$H/projects/task"
cat > "$H/data/backlog.md" <<'EOF'
## In flight
- [ ] restart-task - Preserve publication single flight (repo: firstmate) (kind: ship) (since 2026-08-28)

## Queued

## Done
EOF
fm_write_meta "$H/state/restart-task.meta" "window=fmtest:fm-restart-task" \
  "worktree=$H/projects/task" "project=firstmate" "harness=claude" "kind=ship" \
  "mode=no-mistakes" "spawn_gen=fm.restart123456"

marker="$TMP_ROOT/lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$H" "$marker" &
LOCK_HOLDER_PID=$!
until [ -e "$marker" ]; do sleep 0.05; done
watch_start one
printf 'needs-decision [key=restart-gate]: restart the watcher\n' > "$H/state/restart-task.status"
i=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
one_exited=yes; kill -0 "$WATCH_PID" 2>/dev/null && one_exited=no
wait "$WATCH_PID" >/dev/null 2>&1; WATCH_PID=
rm -f "$H/state/.last-watcher-beat"
watch_start two
sleep 4
live_log=$(wc -l < "$H/state/.home-summary-refresh.log" 2>/dev/null | tr -d ' ')
third=no
if ! kill -0 "$WATCH_PID" 2>/dev/null; then
  wait "$WATCH_PID" >/dev/null 2>&1
  rm -f "$H/state/.last-watcher-beat"
  watch_start three
  third=yes
fi
l0=$(load1)
kill -KILL "$LOCK_HOLDER_PID"; wait "$LOCK_HOLDER_PID" 2>/dev/null; LOCK_HOLDER_PID=
t0=$(now)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
  FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort
wrc=$?
t1=$(now)
by_writer=no; [ -e "$H/state/home-summary.json" ] && by_writer=yes
i=0
while [ ! -e "$H/state/home-summary.json" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
t2=$(now)
if [ -e "$H/state/home-summary.json" ]; then verdict=PUBLISHED; else verdict=WEDGED; fi
kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=
prod=''
for _ in 1 2; do
  t=$(now)
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary >/dev/null 2>&1
  prod="$prod $(echo "$(now) - $t" | bc)s"
done
printf '%s: load1 %s | watcher-one exited=%s third-watcher=%s live-hold log=%s | writer rc=%s %.2fs published-by-writer=%s | ledger %s at +%.2fs | producer%s\n' \
  "$label" "$l0" "$one_exited" "$third" "${live_log:-0}" "$wrc" "$(echo "$t1 - $t0" | bc)" "$by_writer" "$verdict" "$(echo "$t2 - $t0" | bc)" "$prod"
sed 's/^/    refresh-log: /' "$H/state/.home-summary-refresh.log" 2>/dev/null | tail -4
