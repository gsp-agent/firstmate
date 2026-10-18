#!/usr/bin/env bash
# The root home and its local secondmate home both dispatch the same full
# project at the same moment, with an open window and a slow reading that
# reports room. Only one extra start may launch.
set -u
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56CCG2561MPB8N9JBX9TJ70
. /tmp/fm-cap-drive/lab.env
MATE="$LAB/mate"
cd "$WT" || exit 1
for pair in "$LAB:lab3-r" "$MATE:lab3-m"; do
  h=${pair%%:*}; id=${pair##*:}
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$h" "$WT/bin/fm-brief.sh" "$id" labproj3 --mode local-only >/dev/null
  python3 -I - "$h/data/$id/brief.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Lab task for project-capacity headroom admission; a stand-in worker idles in its pane.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Nothing to build; this task exists so the spawn can be admitted or deferred.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  tasks-axi add "$id" "lab item $id" --kind ship --file "$h/data/backlog.md" >/dev/null
done
: > "$LAB/out/reading-slow.log"
SPAWN_PROJECT=labproj3 /tmp/fm-cap-drive/spawn.sh lab3-r --no-brief > /tmp/fm-cap-drive/s10-conc-root.log 2>&1 &
p1=$!
SPAWN_HOME="$MATE" SPAWN_PROJECT=labproj3 /tmp/fm-cap-drive/spawn.sh lab3-m --no-brief > /tmp/fm-cap-drive/s10-conc-mate.log 2>&1 &
p2=$!
wait "$p1"; wait "$p2"
for f in /tmp/fm-cap-drive/s10-conc-root.log /tmp/fm-cap-drive/s10-conc-mate.log; do echo "=== $(basename "$f")"; grep -v '^●' "$f"; done
echo "slow reading runs: $(wc -l < "$LAB/out/reading-slow.log" | tr -d ' ')"
for r in "$LAB/state/project-capacity-overshare/labproj3" "$MATE/state/project-capacity-overshare/labproj3"; do
  [ -f "$r" ] && echo "record $r epoch=$(cat "$r")" || echo "no record at $r"
done
echo "labproj3 task records: $(ls "$LAB"/state/lab3-*.meta "$MATE"/state/lab3-*.meta 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
