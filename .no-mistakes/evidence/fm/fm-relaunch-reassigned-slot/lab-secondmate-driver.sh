#!/usr/bin/env bash
# Secondmate homes leased from a pool slot that still carries an older ship
# task's claim. A matching home marker must relaunch as before; a home marked
# for another secondmate must still refuse. Real tmux on the lab socket.
set -u
REPO=$1 LAB=$2 POOL=${3:-$2/pool} PFX=${4:-nmlab-sm}
cd "$REPO" || exit 1
TD=$(cat "$LAB/state/.fm-lab-tmux-dir")
labtmux() { env TMUX_TMPDIR="$TD" tmux "$@"; }
labrun() {
  env -u TMUX FM_HOME="$LAB" TMUX_TMPDIR="$TD" HOME="$LAB/user-home" \
    CLAUDE_CONFIG_DIR="$LAB/claude-config" FM_SPAWN_NO_GUARD=1 FM_CONTROL_LAUNCH_WAIT=180 "$@"
}
mkdir -p "$LAB/config"
printf 'claude\n' > "$LAB/config/secondmate-harness"
first=1
for spec in $PFX-own:6:$PFX-own $PFX-wrong:7:someone-else; do
  id=${spec%%:*}; rest=${spec#*:}; n=${rest%%:*}; marker=${rest#*:}
  home="$POOL/demo-$n/demo"
  mkdir -p "$POOL/demo-$n"
  git -C "$LAB/projects/demo" worktree add -q -b "sm/$id" "$home"
  mkdir -p "$home/state" "$home/data" "$home/bin" "$LAB/data/$id"
  printf '# agents\n' > "$home/AGENTS.md"
  printf '# secondmate brief\n' > "$LAB/data/$id/brief.md"
  printf '%s\n' "$marker" > "$home/.fm-secondmate-home"
  # Stale claim from an earlier ship task that held this slot before the lease.
  printf 'task=gsp-dc9j6-lab\nhome=%s\n' "$LAB" > "$POOL/demo-$n/.fm-slot-owner"
  {
    echo "window=fmlab:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$home"
    echo "project=$home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$home"
    echo "projects="
  } > "$LAB/state/$id.meta"
  if [ "$first" = 1 ]; then
    labtmux new-session -d -s fmlab -n "fm-$id" -c "$home" \
      env HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$LAB/claude-config" /bin/bash --noprofile --norc
    first=0
  else
    labtmux new-window -d -t fmlab -n "fm-$id" -c "$home" \
      env HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$LAB/claude-config" /bin/bash --noprofile --norc
  fi
  echo "secondmate $id: slot demo-$n claim=$(sed -n "s/^task=//p" "$POOL/demo-$n/.fm-slot-owner") home marker=$marker"
done
echo
for id in $PFX-wrong $PFX-own; do
  cp -p "$LAB/state/$id.meta" "$LAB/$id.meta-before"
  echo "=== bin/fm-control.sh $id relaunch"
  rc=0; labrun bin/fm-control.sh "$id" relaunch 2>&1 || rc=$?
  echo "exit=$rc"
  cmp -s "$LAB/$id.meta-before" "$LAB/state/$id.meta" && echo "task record: unchanged" || echo "task record: republished"
  echo "endpoint now runs: $(labtmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
  if [ "$id" = "$PFX-wrong" ]; then
    echo "=== bin/fm-spawn.sh $id --relaunch (direct caller)"
    rc=0; labrun bin/fm-spawn.sh "$id" --relaunch 2>&1 || rc=$?
    echo "exit=$rc"
    echo "endpoint now runs: $(labtmux display-message -p -t "fmlab:fm-$id" '#{pane_current_command}')"
  fi
  echo
done
