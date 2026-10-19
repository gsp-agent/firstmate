#!/usr/bin/env bash
# S2: a teardown keeps the home's lease-command lock while the real lab Claude
# primary ends a turn with no watcher running, so the Stop auto-arm activates a
# new supervision host behind that lock. Records, every 10s while the teardown
# holds the lock, whether a watcher runs and what fm-inbox.sh ready reads, then
# ends the teardown and records the deferred branch-lease release.
# Usage: s2-teardown-lock.sh <lab> <label>
set -u
LAB=$1 LABEL=$2
HOLD=${S2_HOLD:-60}
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$LAB/fmroot" && pwd -P)
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
say() { T send-keys -t primary -l "$1"; T send-keys -t primary Enter; }
probe() { bash "$D/probe.sh" "$LAB/fmroot" "$LAB" "$1"; }
wpid() { cat "$LAB/state/.watch.lock/pid" 2>/dev/null; }
watcher_alive() { local p; p=$(wpid) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
busy() { pgrep -f 'ping -c 50 -i 1 127.0.0.1' >/dev/null 2>&1; }
hostpid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$LAB/state/.supervision-host" 2>/dev/null; }

echo "##### $LABEL"
echo "host script under test: $(shasum "$ROOT/bin/fm-supervision-host.sh" | cut -c1-12)"
for _ in $(seq 1 120); do watcher_alive && ! busy && break; sleep 1; done
probe "start: main idle, host parked on a live watcher"
lockpid=$(head -n 1 "$LAB/state/.lock")
# A live branch lease, as an engine turn that ended without releasing leaves.
printf 'branch\t%s\t%s\n' "$lockpid" "$(date +%s)" > "$LAB/state/.lease-labdemo"
say 'Lab test. Run exactly this one bash command in the foreground and wait for it: ping -c 50 -i 1 127.0.0.1 >/dev/null ; then reply with only the word ok.'
for _ in $(seq 1 60); do busy && break; sleep 1; done
busy && echo "--- main is mid-turn (ping -c 50)" || echo "--- WARNING: main never started the long command"
first=$(wpid)
passes=$(grep -c 'pass-through' "$LAB/state/.supervision-host.log" 2>/dev/null)
printf 'lab wake A\n' > "$LAB/labprobe.fire"
# Wake A closes the parked cycle; the host passes it to main and leaves a
# successor cycle running. Wait for that successor before firing wake B.
for _ in $(seq 1 60); do
  [ "$(grep -c 'pass-through' "$LAB/state/.supervision-host.log" 2>/dev/null)" -gt "$passes" ] \
    && watcher_alive && [ "$(wpid)" != "$first" ] && break
  sleep 1
done
echo "--- $(date -u +%H:%M:%SZ) wake A passed through to main; successor watcher $(wpid) left running"
printf 'lab wake B\n' > "$LAB/labprobe.fire"
for _ in $(seq 1 40); do watcher_alive || break; sleep 1; done
rm -f "$LAB/labprobe.fire"
echo "--- $(date -u +%H:%M:%SZ) the last cycle closed on its wake; no watcher while main is mid-turn"
# The teardown: holds the lease-command lock (fm_lease_guard, as fm-teardown.sh)
# until $LAB/teardown.done.
rm -f "$LAB/teardown.held" "$LAB/teardown.done"
FM_HOME="$LAB" FM_SUPERVISION_ACTOR=main bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-lease-lib.sh"
  fm_lease_guard other-task "teardown (fixture)"
  printf "%s\n" "$$" > "$FM_HOME/teardown.held"
  while [ ! -e "$FM_HOME/teardown.done" ]; do sleep 0.2; done
  fm_lease_guard_release' _ "$ROOT" &
TD=$!
for _ in $(seq 1 50); do [ -s "$LAB/teardown.held" ] && break; sleep 0.2; done
echo "--- $(date -u +%H:%M:%SZ) teardown fixture pid $(cat "$LAB/teardown.held") took the lease-command lock"
probe "mid-turn, teardown holding the lease lock, no watcher"
for _ in $(seq 1 90); do busy || break; sleep 1; done
ended=$(date -u +%H:%M:%SZ)
echo "--- $ended main's long command finished; its turn ends and the Stop auto-arm activates a host behind the teardown"
s=$SECONDS
while [ $((SECONDS - s)) -lt "$HOLD" ]; do
  sleep 10
  probe "teardown still holding the lease lock, $((SECONDS - s))s after main's turn ended (host pid $(hostpid || true))"
done
: > "$LAB/teardown.done"; wait "$TD" 2>/dev/null
echo "--- $(date -u +%H:%M:%SZ) teardown ended"
for _ in $(seq 1 30); do [ ! -e "$LAB/state/.lease-labdemo" ] && break; sleep 1; done
echo "--- branch lease after the teardown: $([ -e "$LAB/state/.lease-labdemo" ] && echo "still present: $(cat "$LAB/state/.lease-labdemo")" || echo released)"
probe "after the teardown ended"
sed 's/^/host log: /' "$LAB/state/.supervision-host.log" 2>/dev/null | tail -12
