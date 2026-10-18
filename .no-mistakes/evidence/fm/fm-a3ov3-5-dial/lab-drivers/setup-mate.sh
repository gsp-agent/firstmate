#!/usr/bin/env bash
# A third lab project and a local secondmate home registered under the lab root
# home, with its own clone of that project (same directory name, same origin).
set -eu
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56CCG2561MPB8N9JBX9TJ70
. /tmp/fm-cap-drive/lab.env
seed="$LAB/origins/labproj3-seed"
git init -q -b main "$seed"
printf '# labproj3\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m init
git clone -q --bare "$seed" "$LAB/origins/labproj3.git"
git clone -q "$LAB/origins/labproj3.git" "$LAB/projects/labproj3"
MATE="$LAB/mate"
"$WT/bin/fm-lab-home.sh" create "$MATE" >/dev/null
git clone -q "$LAB/origins/labproj3.git" "$MATE/projects/labproj3"
for d in "$LAB/projects/labproj3" "$MATE/projects/labproj3"; do
  git -C "$d" config user.name lab; git -C "$d" config user.email lab@example.invalid
done
printf 'tmux\n' > "$MATE/config/backend"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$MATE/data/backlog.md"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$MATE/.tasks.toml"
touch "$MATE/state/.last-watcher-beat"
printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$LAB" > "$MATE/.fm-secondmate-parent"
printf -- '- mate - a local lab mate (home: %s; scope: lab project work; projects: labproj3; added 2026-10-17)\n' "$MATE" > "$LAB/data/secondmates.md"
printf '%s\n' 'labproj 2' 'labproj2 1' 'labproj3 1' > "$LAB/config/project-capacity"
echo "MATE=$MATE"
