#!/usr/bin/env bash
# Behavioral coverage for per-home summary publication through the real
# producer, writer, watcher-carried status trigger, and snapshot ledger consumer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5H6NCKQJM2YC31BBNGTSVQQ/tests/lib.sh"

WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-refresh)
TEST_CODE_ROOT="$TMP_ROOT/code-root"
mkdir -p "$TEST_CODE_ROOT"
ln -s "$ROOT/bin" "$TEST_CODE_ROOT/bin"
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


NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
large_id_suffix=$(printf 'i%.0s' $(seq 1 110))
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
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TEST_CODE_ROOT" FM_HOME="$LARGE_CHILD_HOME" \
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
PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$TEST_CODE_ROOT" FM_HOME="$LARGE_PARENT_HOME" \
  FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
  "$SNAPSHOT" --json > "$TMP_ROOT/large-parent-snapshot.json" \
  || fail "parent fleet snapshot failed for a large child ledger"
cp "$TMP_ROOT/large-parent-snapshot.json" "/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/large-parent-snapshot-r6.json"
cp "$LARGE_CHILD_HOME/state/home-summary.json" "/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ/large-child-summary-r6.json"
jq -e '.secondmate_current.records[0]
  | .provenance.summary_source == "local-ledger"
    and .invalidity.kind == "orphan_in_flight"
    and (.invalidity.ids | length) == 600' \
  "$TMP_ROOT/large-parent-snapshot.json" >/dev/null \
  || fail "parent fleet snapshot did not preserve the large child invalidity"
pass "parent snapshot consumes large child ledgers without argument transport"

