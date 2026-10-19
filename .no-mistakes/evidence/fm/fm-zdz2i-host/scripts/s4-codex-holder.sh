#!/usr/bin/env bash
# S4 (adversarial): a lab home whose session lock is held by a real, live Codex
# CLI process (codex sandbox running a long command - no model call), with a
# beacon a watcher left behind and no watcher running. A persistent-model home
# needs its live watcher, so fm-inbox.sh ready must read down/no-watcher even
# when the caller is a Claude session (CLAUDECODE=1).
# Usage: s4-codex-holder.sh <worktree>
set -u
WT=$(cd "$1" && pwd -P)
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
/opt/homebrew/bin/codex sandbox -- /bin/sleep 120 >/dev/null 2>&1 &
TOP=$!
sleep 3
echo "codex process tree:"
ps -o pid,ppid,comm,args -p "$TOP" | cut -c1-160
ps -A -o pid,ppid,comm | awk -v p="$TOP" '$2 == p' | cut -c1-160
HOLDER=$TOP
printf '%s\n' "$HOLDER" > "$LAB/state/.lock"
touch "$LAB/state/.last-watcher-beat"
echo "harness ancestry of lock pid $HOLDER: $(bin/fm-harness.sh ancestry "$HOLDER" 2>&1)"
for caller in "plain shell" "Claude session (CLAUDECODE=1)"; do
  if [ "$caller" = "plain shell" ]; then
    out=$(env -u FM_SUPERVISION_MODEL -u CLAUDECODE FM_HOME="$LAB" bin/fm-inbox.sh ready)
  else
    out=$(env -u FM_SUPERVISION_MODEL CLAUDECODE=1 FM_HOME="$LAB" bin/fm-inbox.sh ready)
  fi
  printf '%-30s %s\n' "$caller:" "$(printf '%s' "$out" | jq -c '{lock: .lock.state, live_harness: .lock.live_harness, wake_consumer, can_receive}')"
done
kill "$TOP" 2>/dev/null
pkill -P "$TOP" 2>/dev/null
wait "$TOP" 2>/dev/null
echo "LAB=$LAB"
