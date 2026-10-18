#!/usr/bin/env bash
# Two Firstmate dispatches of the same full project at the same moment, with an
# open extra-start window and a slow reading that reports room.
set -u
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56CCG2561MPB8N9JBX9TJ70
. /tmp/fm-cap-drive/lab.env
cd "$WT" || exit 1
for id in lab2-b lab2-c; do
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" "$WT/bin/fm-brief.sh" "$id" labproj2 --mode local-only >/dev/null
  python3 -I - "$LAB/data/$id/brief.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Lab task for project-capacity headroom admission; a stand-in worker idles in its pane.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Nothing to build; this task exists so the spawn can be admitted or deferred.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  tasks-axi add "$id" "lab item $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
done
cat > "$LAB/readings/slow-room" <<'R'
#!/usr/bin/env bash
printf 'ran %s\n' "$(date -u +%H:%M:%SZ)" >> "$(dirname "$0")/../out/reading-slow.log"
sleep 4
printf '%s\n' 'cpu_idle_pct=33.0 load1=20.00 disk_free_gb=540.0'
R
chmod +x "$LAB/readings/slow-room"
printf '%s\n' "$LAB/readings/slow-room" > "$LAB/config/project-capacity-headroom"
SPAWN_PROJECT=labproj2 /tmp/fm-cap-drive/spawn.sh lab2-b --no-brief > /tmp/fm-cap-drive/s9-conc-lab2-b.log 2>&1 &
p1=$!
SPAWN_PROJECT=labproj2 /tmp/fm-cap-drive/spawn.sh lab2-c --no-brief > /tmp/fm-cap-drive/s9-conc-lab2-c.log 2>&1 &
p2=$!
wait "$p1"; wait "$p2"
for f in /tmp/fm-cap-drive/s9-conc-lab2-b.log /tmp/fm-cap-drive/s9-conc-lab2-c.log; do echo "=== $(basename "$f")"; cat "$f"; done
echo "slow reading runs: $(wc -l < "$LAB/out/reading-slow.log" | tr -d ' ')"
r="$LAB/state/project-capacity-overshare/labproj2"; [ -f "$r" ] && echo "labproj2 record epoch=$(cat "$r")"
