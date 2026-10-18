#!/usr/bin/env bash
# Stand up a disposable project-capacity lab: a marked lab home, a private tmux
# server, a lab-local treehouse pool, and two real projects (alpha, beta) each
# cloned from its own local bare origin. Prints the lab root.
set -eu
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M56X9093NEEWZJH7PFGG0YPN
ROOT=$(cd "$(mktemp -d /tmp/fmcap.XXXXXX)" && pwd -P)
LAB=$ROOT/home
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
mkdir -p "$ROOT/treehouse" "$ROOT/shim" "$ROOT/readings"
printf 'tmux\n' > "$LAB/config/backend"
for p in alpha beta; do
  seed=$ROOT/seed-$p
  git init -q -b main "$seed"
  printf '# %s\n' "$p" > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m "seed $p"
  git clone -q --bare "$seed" "$ROOT/$p.origin.git"
  rm -rf "${seed:?}"
  git clone -q "$ROOT/$p.origin.git" "$LAB/projects/$p"
done
printf '# Projects\n\n- alpha [local-only +yolo] - lab alpha\n- beta [local-only +yolo] - lab beta\n' > "$LAB/data/projects.md"
# A tasks-axi shim on the lab PATH: it runs the real tasks-axi, except that
# `start` fails while $ROOT/fail-start exists (a fault injected after launch).
real_tasks_axi=$(command -v tasks-axi)
cat > "$ROOT/shim/tasks-axi" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = start ] && [ -e "$ROOT/fail-start" ]; then
    echo "lab shim: tasks-axi start refused (injected)" >&2
    exit 1
  fi
done
exec "$real_tasks_axi" "\$@"
SH
chmod +x "$ROOT/shim/tasks-axi"
printf '%s\n' "$TMUXD" > "$ROOT/tmux-dir"
# The pane shells run `treehouse get`, so the server's environment must carry
# the lab pool root; otherwise slots land in ~/.treehouse.
env -i HOME="$HOME" PATH="$ROOT/shim:$PATH" TMUX_TMPDIR="$TMUXD" TERM=xterm-256color \
  TREEHOUSE_ROOT="$ROOT/treehouse" \
  tmux -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT"
env -u TMUX TMUX_TMPDIR="$TMUXD" tmux set-environment -g TREEHOUSE_ROOT "$ROOT/treehouse"
printf '%s\n' "$ROOT"
