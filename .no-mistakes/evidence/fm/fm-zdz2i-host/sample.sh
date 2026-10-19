#!/usr/bin/env bash
# Sample the lab's watcher/lock state and both readiness readings every
# <interval> seconds for <count> samples, one compact line per reading.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
count=${1:-10} interval=${2:-3} label=${3:-sample}
summ() { python3 -c 'import json,sys; d=json.load(sys.stdin); w=d["wake_consumer"]; print("lock=%s consumer=%s reason=%s beacon=%s can_receive=%s" % (d["lock"]["state"], w["state"], w["reason"], w["beacon_age_seconds"], d["can_receive"]))'; }
for i in $(seq 1 "$count"); do
  ts=$(date -u +%H:%M:%SZ)
  w=$("$EV/lab.sh" watchers 2>/dev/null | tr '\n' ' ')
  procs=$(pgrep -f "fm-root.*/bin/fm-(watch|watch-arm|supervision-host|claude-stop-autoarm)\.sh" | wc -l | tr -d ' ')
  new=$("$EV/lab.sh" ready | summ)
  old=$("$EV/lab.sh" ready-old | summ)
  printf '%s [%s] %s| lab fm procs=%s\n    NEW  %s\n    BASE %s\n' "$ts" "$label" "$w" "$procs" "$new" "$old"
  [ "$i" -eq "$count" ] || sleep "$interval"
done
