#!/usr/bin/env bash
# pick-live.sh <work-dir> <head-root> <base-root> [treehouse-bin-dir] [layout...]
# Builds each pool layout with the real Treehouse binary, then asks the real
# fm_treehouse_free_own_slot from the base commit and from the fix which free
# own-clone slot a spawn would enter, and whether `treehouse enter <name>`
# (the exact lookup the spawn pane performs) resolves that name to that slot.
set -u
W=$1 HEAD_ROOT=$2 BASE_ROOT=$3 TH_DIR=${4:-}
shift 4 2>/dev/null || shift $#
LAYOUTS=("$@")
[ "${#LAYOUTS[@]}" -gt 0 ] || LAYOUTS=(incident empty-new new-free no-switch)
[ -z "$TH_DIR" ] || PATH="$TH_DIR:$PATH"
export PATH
. "$(dirname "${BASH_SOURCE[0]}")/scenario-lib.sh"

pick() {  # <fm-root> <proj>
  FM_HOME="$W/pick-home" FM_ROOT_OVERRIDE='' bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_free_own_slot "$2"' pick "$1" "$2"
}

enter_check() {  # <proj> <slot>
  local proj=$1 slot=$2 name got
  [ -n "$slot" ] || { printf '(nothing chosen: spawn takes Treehouse lease steering in the configured pool)'; return; }
  name=$(basename "$(dirname "$slot")")
  if got=$(cd "$proj" && treehouse enter --print-path "$name" </dev/null 2>/dev/null) && [ -n "$got" ]; then
    got=$(cd "$got" && pwd -P)
    if [ "$got" = "$slot" ]; then
      printf "treehouse enter '%s' -> %s (the chosen slot)" "$name" "$got"
    else
      printf "treehouse enter '%s' -> %s (a DIFFERENT slot than the one chosen)" "$name" "$got"
    fi
  else
    printf "treehouse enter '%s' -> no such worktree in the configured pool (pane never moves)" "$name"
  fi
}

printf 'treehouse on PATH: %s %s\n' "$(command -v treehouse)" "$(treehouse --version 2>/dev/null | tr -d '[:space:]')"
for layout in "${LAYOUTS[@]}"; do
  dir="$W/pick/$layout${TH_DIR:+-th201}"
  build_layout "$layout" "$dir" || { echo "layout $layout failed to build"; continue; }
  printf '\n=== layout: %s ===\n' "$layout"
  describe_layout "$dir"
  base_pick=$(pick "$BASE_ROOT" "$dir/proj")
  head_pick=$(pick "$HEAD_ROOT" "$dir/proj")
  printf 'base %s picks: %s\n' "cfd72172" "${base_pick:-<nothing>}"
  printf '  %s\n' "$(enter_check "$dir/proj" "$base_pick")"
  printf 'fix  %s picks: %s\n' "072d88f0" "${head_pick:-<nothing>}"
  printf '  %s\n' "$(enter_check "$dir/proj" "$head_pick")"
done
