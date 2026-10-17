#!/usr/bin/env bash
# Build the disposable lab fixtures used by the live teardown scenarios.
# Usage: lab-setup.sh <marked-lab-home>
# Everything lives under the lab: a private HOME with real br databases for
# .agent-config and dev/gsp-beads, a real project git repo with its own br
# database, a markdown backlog, and a private tmux server holding task windows.
set -euo pipefail
LAB=${1:?lab home}
[ -f "$LAB/.fm-lab-home" ] || { echo "not a lab home" >&2; exit 1; }
export HOME="$LAB/home"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid
export GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

mkdir -p "$HOME/.agent-config" "$HOME/dev/gsp-beads" "$LAB/projects/demo"
(cd "$HOME/.agent-config" && [ -d .beads ] || br init --prefix .agent-config -q)
(cd "$HOME/dev/gsp-beads" && br init --prefix gsp -q)
cd "$LAB/projects/demo"
git init -q -b main
git commit -q --allow-empty -m baseline
br init --prefix demo -q

# Firstmate backlog for this home.
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"

# Private tmux server for task windows (never the default server).
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n home 'sleep 86400'
echo "lab ready: $LAB"
