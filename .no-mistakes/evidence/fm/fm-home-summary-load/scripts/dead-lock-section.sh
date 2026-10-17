#!/usr/bin/env bash
# dead-lock-section.sh <tree> <label> - instrumented copy of the
# "publication remains single-flight across watcher restart" stale-lock step in
# tests/fm-home-summary-refresh.test.sh (same one-task restart home, fake tmux
# and no-mistakes, watcher at FM_POLL=1 with its 2 s refresh bound), run from
# <tree>. After the live lock holder is SIGKILLed it runs the same
# FM_HOME_SUMMARY_IF_IDLE=1 best-effort writer and waits the same 10 s for the
# ledger, then reports what happened instead of only pass/fail: the writer's
# wall time, whether the ledger appeared and when, and the home's refresh
# failure log (watcher attempts that hit their 2 s bound are recorded there).
# It also times the bare producer on that home three times.
set -u
tree=$1 label=$2
# shellcheck disable=SC1091
. "$tree/tests/lib.sh"
ROOT=$tree
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-dead-lock-section)
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

prod=''
for _ in 1 2 3; do
  t0=$(now)
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary >/dev/null 2>&1
  prod="$prod $(echo "$(now) - $t0" | bc)s"
done

marker="$TMP_ROOT/lock-held"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 30
' _ "$ROOT" "$H" "$marker" &
LOCK_HOLDER_PID=$!
until [ -e "$marker" ]; do sleep 0.05; done
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
  FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_HOME_SUMMARY_TIMEOUT=2 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -e "$H/state/.last-watcher-beat" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
sleep 4
live_log=$(cat "$H/state/.home-summary-refresh.log" 2>/dev/null | wc -l | tr -d ' ')
l0=$(load1)
kill -KILL "$LOCK_HOLDER_PID"; wait "$LOCK_HOLDER_PID" 2>/dev/null; LOCK_HOLDER_PID=
t0=$(now)
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" \
  FM_HOME_SUMMARY_IF_IDLE=1 "$WRITER" --best-effort
wrc=$?
t1=$(now)
writer_published=no; [ -e "$H/state/home-summary.json" ] && writer_published=yes
i=0
while [ ! -e "$H/state/home-summary.json" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
t2=$(now)
if [ -e "$H/state/home-summary.json" ]; then verdict=PUBLISHED; else verdict=WEDGED; fi
printf '%s: producer%s | load1 %s | writer rc=%s %.2fs published-by-writer-return=%s | ledger %s at +%.2fs | live-hold log lines=%s\n' \
  "$label" "$prod" "$l0" "$wrc" "$(echo "$t1 - $t0" | bc)" "$writer_published" "$verdict" "$(echo "$t2 - $t0" | bc)" "$live_log"
sed 's/^/    refresh-log: /' "$H/state/.home-summary-refresh.log" 2>/dev/null | tail -6
