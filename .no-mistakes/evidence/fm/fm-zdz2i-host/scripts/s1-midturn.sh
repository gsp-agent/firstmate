#!/usr/bin/env bash
# S1: drive the real lab Claude primary into the coordinator's state - main
# busy in a turn while its watcher cycle closes on a wake and nothing re-arms
# until the turn ends - and probe fm-inbox.sh ready (change vs pre-change).
# The primary runs with FM_CHECK_INTERVAL=5 so the registered labprobe check
# sweeps every 5s; writing $LAB/labprobe.fire makes it print, which is a
# "check:" close (main-only, so the host passes it through to main).
# Usage: s1-midturn.sh <lab>
set -u
LAB=$1
D=$(cd "$(dirname "$0")" && pwd)
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
say() { T send-keys -t primary -l "$1"; T send-keys -t primary Enter; }
probe() { bash "$D/probe.sh" "$LAB/fmroot" "$LAB" "$1"; }
wpid() { cat "$LAB/state/.watch.lock/pid" 2>/dev/null; }
watcher_alive() { local p; p=$(wpid) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
busy() { pgrep -f 'ping -c 100 -i 1 127.0.0.1' >/dev/null 2>&1; }

say 'Lab test. Reply with only the word ok and do nothing else.'
for _ in $(seq 1 90); do watcher_alive && break; sleep 1; done
sleep 3
probe "idle after a turn end: the Stop auto-arm's host is parked on a live watcher"
say 'Lab test. Run exactly this one bash command in the foreground and wait for it: ping -c 100 -i 1 127.0.0.1 >/dev/null ; then reply with only the word ok.'
for _ in $(seq 1 60); do busy && break; sleep 1; done
busy && echo "--- main is mid-turn: its Bash tool is running ping -c 100 (pid $(pgrep -f 'ping -c 100 -i 1 127.0.0.1'))" \
  || echo "--- WARNING: main never started the long command"
probe "mid-turn, host still parked on the watcher from the last Stop"
first=$(wpid)
printf 'lab wake 1\n' > "$LAB/labprobe.fire"
echo "--- fired custom check wake 1 at $(date -u +%H:%M:%SZ)"
for _ in $(seq 1 40); do { [ "$(wpid)" != "$first" ] || ! watcher_alive; } && break; sleep 1; done
sleep 2
probe "mid-turn, after wake 1 closed the first cycle"
printf 'lab wake 2\n' > "$LAB/labprobe.fire"
echo "--- fired custom check wake 2 at $(date -u +%H:%M:%SZ)"
for _ in $(seq 1 40); do watcher_alive || break; sleep 1; done
rm -f "$LAB/labprobe.fire"
echo "--- no live watcher since $(date -u +%H:%M:%SZ); fire file removed"
probe "mid-turn, the last cycle closed on its wake: no watcher runs until main's turn ends"
sleep 15
probe "mid-turn, 15s later: still no watcher, beacon still within grace"
echo "--- main still mid-turn? $(busy && echo yes || echo no)"
cat "$LAB/state/.supervision-host.log" 2>/dev/null | tail -8 | sed 's/^/host log: /'
