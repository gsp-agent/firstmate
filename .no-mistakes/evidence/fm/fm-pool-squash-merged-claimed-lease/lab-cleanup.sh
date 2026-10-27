#!/usr/bin/env bash
# Remove only this run's leftover live-lab directories: lab homes that hold the
# live script's scratch origin and stub shim (or, after a partial removal,
# only a lablease* task's read-only git-hooks dir), and the spawn's /tmp task
# dirs for lablease* ids. fm makes a task's git-hooks dir read-only, so
# restore write permission before removing.
set -u
for d in "${TMPDIR%/}"/fm-lab.*; do
  if [ -d "$d/scratch/origin.git" ] && [ -f "$d/shim/codex" ]; then :
  elif [ "$(ls -A "$d" 2>/dev/null)" = state ] && ls -d "$d"/state/lablease*.git-hooks >/dev/null 2>&1 &&
    [ "$(ls -A "$d/state" | grep -vc '^lablease.*\.git-hooks$')" = 0 ]; then :
  else continue
  fi
  echo "removing lab ${d##*/}"
  chmod -R u+w "${d:?}"
  rm -rf "${d:?}"
done
for d in /tmp/fm-lablease*; do
  [ -e "$d" ] || continue
  echo "removing task temp ${d##*/}"
  chmod -R u+w "${d:?}"
  rm -rf "${d:?}"
done
