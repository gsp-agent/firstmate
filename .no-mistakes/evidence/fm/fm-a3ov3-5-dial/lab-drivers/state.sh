#!/usr/bin/env bash
# Print the lab's observable state: worker windows, task records, the
# extra-start record, started workers, and backlog sections.
set -u
. /tmp/fm-cap-drive/lab.env
echo "--- tmux windows (lab socket) ---"
TMUX_TMPDIR="$SOCK" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} pane_cmd=#{pane_current_command} path=#{pane_current_path}'
echo "--- task records (state/*.meta) ---"
for f in "$LAB"/state/*.meta; do [ -e "$f" ] && echo "$(basename "$f")"; done
echo "--- extra-start record ---"
r="$LAB/state/project-capacity-overshare/labproj"
if [ -f "$r" ]; then echo "labproj epoch=$(cat "$r") age=$(( $(date +%s) - $(cat "$r") ))s"; else echo "(none)"; fi
echo "--- workers started ---"
cat "$LAB/out/workers.log" 2>/dev/null || echo "(none)"
echo "--- backlog ---"
grep -v '^$' "$LAB/data/backlog.md"
