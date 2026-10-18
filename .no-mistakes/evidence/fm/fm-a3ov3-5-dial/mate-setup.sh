#!/usr/bin/env bash
# Seed a local secondmate home under the lab root home, marked as a lab home,
# with its own clone of alpha from alpha's bare origin.
set -eu
ROOT=$1
. "$(dirname "$0")/lab-lib.sh"
MATE=$ROOT/mate
"$WT/bin/fm-lab-home.sh" create "$MATE" >/dev/null
cp "$WT/AGENTS.md" "$MATE/AGENTS.md"
mkdir -p "$MATE/bin"
(cd "$LAB" && lab_run FM_SECONDMATE_CHARTER='Capacity lab second mate that spawns alpha workers.' \
  FM_SECONDMATE_SCOPE='capacity lab alpha' \
  "$WT/bin/fm-home-seed.sh" capmate "$MATE" --no-projects)
git clone -q "$ROOT/alpha.origin.git" "$MATE/projects/alpha"
printf '# Projects\n\n- alpha [local-only +yolo] - lab alpha\n' > "$MATE/data/projects.md"
printf 'tmux\n' > "$MATE/config/backend"
echo "--- mate home"
ls -A "$MATE"
echo "--- parent binding"
cat "$MATE/.fm-secondmate-parent"
echo "--- mate config (no capacity or headroom file of its own)"
ls -A "$MATE/config"
