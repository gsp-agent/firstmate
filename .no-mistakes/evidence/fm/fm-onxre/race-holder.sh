#!/usr/bin/env bash
set -eu
. "$LAB_ROOT/bin/fm-wake-lib.sh"
lock=$(fm_treehouse_project_lock_path "$LAB_PROJECT")
fm_lock_try_acquire "$lock"
trap 'fm_lock_release "$lock"' EXIT
printf 'state=%s\nspawn-pid=%s\n' "$STATE" "$LAB_SPAWN_PID"
touch "$FM_HOME/race-ready"
python3 "$LAB_ROOT/.test-runtime/wait-return.py"
for kind in spawn meta; do
 tasklock="$STATE/.$kind-$LAB_TASK.lock"
 if fm_lock_try_acquire "$tasklock"; then
  fm_lock_release "$tasklock"
  echo "UNLOCKED $kind"
  exit 2
 fi
 echo "held $kind"
done
case "$LAB_MODE" in
 race-meta) printf 'worktree=%s\nreplacement=yes\n' "$LAB_SLOT" > "$STATE/$LAB_TASK.meta" ;;
 race-branch) git -C "$LAB_SLOT" checkout --quiet -b replacement ;;
 race-dirty) printf 'preserve dirty work\n' > "$LAB_SLOT/keep-me.txt" ;;
 race-commits)
  printf 'preserve task commit\n' > "$LAB_SLOT/extra.txt"
  git -C "$LAB_SLOT" add extra.txt
  git -C "$LAB_SLOT" -c user.name=Lab -c user.email=lab@example.invalid commit -qm task-work ;;
 race-owner) printf 'task=replacement\nhome=%s\n' "$FM_HOME" > "${LAB_SLOT%/*}/.fm-slot-owner" ;;
esac
echo 'replacement mutation complete'
