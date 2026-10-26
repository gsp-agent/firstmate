#!/usr/bin/env bash
# Deterministic replay of the two Stop-claim races, independent of host load.
# Same fixtures and ordering as the head's replays in tests/fm-claude-wake.test.sh,
# except the Stop hook's claim-retry `sleep 0.2` is gated by a PATH shim that
# holds until this driver releases it, so the waker rewake always lands while
# the Stop hook waits in its claim retry (no 0.8 s window to hit).
# Usage: gated-race.sh <worktree> <commit> <outdir>
set -u
wt=$1 commit=$2 out=$3
cd "$wt" || exit 1
git archive --format=tar "$commit" bin tests | tar -x -C "$out"
git show HEAD:tests/fm-claude-wake.test.sh \
  | awk '/^test_[a-z0-9_]+$/ { next } { print }' > "$out/tests/gated-race.test.sh"
cat >> "$out/tests/gated-race.test.sh" <<'DRIVER'

GATEBIN="$TMP_ROOT/gatebin"
mkdir -p "$GATEBIN"
cat > "$GATEBIN/sleep" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = 0.2 ] && [ -n "${FM_GATE_DIR:-}" ] && [ ! -e "$FM_GATE_DIR/released" ]; then
  : > "$FM_GATE_DIR/sleeping"
  while [ ! -e "$FM_GATE_DIR/released" ]; do /bin/sleep 0.05; done
  exit 0
fi
exec /bin/sleep "$@"
SHIM
chmod +x "$GATEBIN/sleep"
cat > "$HELPERS/wait-gate" <<'SHIM'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 2400 ]; do
  [ -e "$1/sleeping" ] && exit 0
  kill -0 "$2" 2>/dev/null || exit 1
  /bin/sleep 0.05
  i=$((i + 1))
done
exit 1
SHIM
chmod +x "$HELPERS/wait-gate"
export GATEBIN

gated_after_read() {
  local dir out
  dir=$(make_home "$TMP_ROOT/gated-after")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" race-note
    "$HELPERS/old-claim" "$S" || echo OLD_CLAIM_FAILED
    . "$FM_HOME/bin/fm-wake-lib.sh"
    printf "SEEDED_LEDGER=%s\n" "$(sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/\1 \2/p" "$S/.claude-autoarm-epoch")"
    printf "epoch=2 owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\n%s\n" \
      "$$" "$(date +%s)" "$LOCK_PID" "$(fm_pid_identity "$$")" > "$S/.late-rewake"
    fm_lock_try_acquire "$S/.claude-autoarm.lock" || echo MUTEX_FAILED
    mkdir -p "$S/gate"
    "$P" sess-1 Stop | FM_GATE_DIR="$S/gate" PATH="$GATEBIN:$PATH" "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/stop-err" &
    h=$!
    "$HELPERS/wait-gate" "$S/gate" "$h" && echo STOP_WAITING_IN_CLAIM_RETRY=yes || echo STOP_DID_NOT_WAIT
    mv -f "$S/.late-rewake" "$S/.claude-autoarm-epoch"
    echo "WAKER_REWAKE_COMMITTED=epoch 2"
    fm_lock_release "$S/.claude-autoarm.lock"
    : > "$S/gate/released"
    wait "$h"; echo "STOP_RC=$?"
    sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/LEDGER=\1 \2/p" "$S/.claude-autoarm-epoch"
    printf "STOP_BANNER_LINES=%s\n" "$(grep -c "firstmate watcher wake" "$S/stop-err")"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  printf '%s\n' "$out"
}

gated_inflight() {
  local dir out
  dir=$(make_home "$TMP_ROOT/gated-inflight")
  out=$(run_body "$dir" '
    "$P" sess-1 UserPromptSubmit | "$FM_HOME/bin/fm-claude-turn.sh"
    "$P" sess-1 Stop | "$FM_HOME/bin/fm-claude-turn.sh"
    "$HELPERS/append" "$S" inflight-note
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$S" 300 || echo CLAIM_FAILED
    printf "SEEDED_LEDGER=%s\n" "$(sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/\1 \2/p" "$S/.claude-autoarm-epoch")"
    printf "epoch=%s owner_pid=%s outcome=rewake updated_at=%s session_pid=%s\n%s\n" \
      "$FM_AUTOARM_MY_GEN" "$$" "$(date +%s)" "$LOCK_PID" "$(sed -n 2p "$S/.claude-autoarm-epoch")" > "$S/.inflight-rewake"
    "$HELPERS/set-mtime" "$S/.claude-autoarm-epoch" "$(( $(date +%s) - 1000 ))"
    fm_lock_try_acquire "$S/.claude-autoarm.lock" || echo MUTEX_FAILED
    mkdir -p "$S/gate"
    "$P" sess-1 Stop | FM_GATE_DIR="$S/gate" PATH="$GATEBIN:$PATH" "$FM_HOME/bin/fm-claude-stop-autoarm.sh" 2>"$S/stop-err" &
    h=$!
    "$HELPERS/wait-gate" "$S/gate" "$h" && echo STOP_WAITING_IN_CLAIM_RETRY=yes || echo STOP_DID_NOT_WAIT
    mv -f "$S/.inflight-rewake" "$S/.claude-autoarm-epoch"
    echo "WAKER_REWAKE_COMMITTED=epoch 1 (same generation the pending read saw arming)"
    fm_lock_release "$S/.claude-autoarm.lock"
    : > "$S/gate/released"
    wait "$h"; echo "STOP_RC=$?"
    sed -n "1s/^epoch=\([0-9]*\) .*outcome=\([a-z-]*\).*/LEDGER=\1 \2/p" "$S/.claude-autoarm-epoch"
    printf "STOP_BANNER_LINES=%s\n" "$(grep -c "firstmate watcher wake" "$S/stop-err")"
    "$P" sess-1 FileChanged | "$FM_HOME/bin/fm-claude-wake.sh" 2>/dev/null; echo "LATE_RC=$?"
  ')
  printf '%s\n' "$out"
}

printf -- '--- race A: waker rewake committed at a newer generation after the Stop pending read\n'
gated_after_read
printf -- '--- race B: waker claim read as arming by the Stop pending read, rewake committed at that same generation\n'
gated_inflight
DRIVER
printf '=== gated race replay @ %s\n' "$(git rev-parse --short "$commit")"
bash "$out/tests/gated-race.test.sh" 2>&1
printf '=== exit %s\n' "$?"
