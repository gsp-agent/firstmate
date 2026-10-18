#!/usr/bin/env bash
# Build a disposable lab home for project-capacity headroom scenarios.
set -eu
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56CCG2561MPB8N9JBX9TJ70
LAB=$1
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCK=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
mkdir -p "$LAB/origins" "$LAB/treehouse" "$LAB/out"
seed="$LAB/origins/labproj-seed"
git init -q -b main "$seed"
printf '# labproj\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m init
git clone -q --bare "$seed" "$LAB/origins/labproj.git"
git clone -q "$LAB/origins/labproj.git" "$LAB/projects/labproj"
git -C "$LAB/projects/labproj" config user.name lab
git -C "$LAB/projects/labproj" config user.email lab@example.invalid
printf 'tmux\n' > "$LAB/config/backend"
printf 'labproj 1\n' > "$LAB/config/project-capacity"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$LAB/.tasks.toml"
# The stand-in worker: records that it started in its task's pane, then idles.
cat > "$LAB/worker.sh" <<'W'
#!/usr/bin/env bash
printf '%s started in %s at %s\n' "${FM_TASK_ID:-?}" "$PWD" "$(date -u +%H:%M:%SZ)" >> "$(dirname "$0")/out/workers.log"
exec sleep 3600
W
chmod +x "$LAB/worker.sh"
env -i HOME="$HOME" USER="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=en_US.UTF-8 \
  TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$LAB/treehouse" FM_BACKEND=tmux \
  tmux -L fm-lab -f /dev/null new-session -d -s primary -x 220 -y 60 -c "$WT" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse"
printf 'LAB=%s\nSOCK=%s\n' "$LAB" "$SOCK"
