#!/usr/bin/env bash
# Shared builders for the Treehouse root-switch live scenarios.
# Every path lives under a disposable directory the caller passes in; every
# Treehouse call is the real binary first on PATH (v2.3.0 by default, or the
# pinned v2.0.1 when TH_BIN_DIR points at it), with the pool root set by the
# project's own treehouse.toml exactly as the incident's project had it.
set -u

gitq() { git -c user.name='Root Switch Lab' -c user.email='lab@example.invalid' "$@"; }

# mk_project <case-dir>: a bare origin with one commit on main, and the
# project clone at <case-dir>/proj with origin/HEAD set and treehouse.toml
# excluded so the primary checkout stays clean.
mk_project() {
  local dir=$1
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/proj" 2>/dev/null
  git -C "$dir/proj" checkout -q -b main
  printf 'root switch lab\n' > "$dir/proj/README.md"
  git -C "$dir/proj" add README.md
  gitq -C "$dir/proj" commit -qm init
  git -C "$dir/proj" push -q origin main 2>/dev/null
  git -C "$dir/proj" remote set-head origin main >/dev/null
  printf 'treehouse.toml\n' >> "$dir/proj/.git/info/exclude"
}

# set_root <proj> <root>: point the project's treehouse.toml at <root>, the
# same edit that moved the incident project's pool.
set_root() {
  printf 'max_trees = 16\nroot = "%s"\n' "$2" > "$1/treehouse.toml"
}

# lease <proj>: durably lease (or create) a slot in the configured pool; prints its path.
lease() {
  (cd "$1" && treehouse get --lease --lease-holder root-switch-lab </dev/null 2>/dev/null)
}

# release <proj> <slot>: return a leased slot so the pool records it free.
release() {
  (cd "$1" && treehouse return "$2" </dev/null >/dev/null 2>&1)
}

# build_layout <name> <case-dir>: build one named pool shape for project <case-dir>/proj.
#   incident     old pool 1,2 leased + 3 free; root moved; new pool slot 1 busy
#   empty-new    old pool slot 1 free; root moved; new pool has no slot yet
#   new-free     old pool slot 1 free; root moved; new pool 1 busy + 2 free
#   no-switch    one pool, never moved: slot 1 busy + slot 2 free
build_layout() {
  local layout=$1 dir=$2 proj a b c
  proj="$dir/proj"
  mk_project "$dir"
  case "$layout" in
    incident)
      set_root "$proj" "$dir/root-old"
      a=$(lease "$proj"); b=$(lease "$proj"); c=$(lease "$proj")
      release "$proj" "$c"
      set_root "$proj" "$dir/root-new"
      a=$(lease "$proj")
      ;;
    empty-new)
      set_root "$proj" "$dir/root-old"
      a=$(lease "$proj")
      release "$proj" "$a"
      set_root "$proj" "$dir/root-new"
      ;;
    new-free)
      set_root "$proj" "$dir/root-old"
      a=$(lease "$proj")
      release "$proj" "$a"
      set_root "$proj" "$dir/root-new"
      b=$(lease "$proj"); c=$(lease "$proj")
      release "$proj" "$c"
      ;;
    no-switch)
      set_root "$proj" "$dir/root-old"
      a=$(lease "$proj"); b=$(lease "$proj")
      release "$proj" "$b"
      ;;
    mixed)
      # A second clone of the same origin, same basename, shares the pool:
      # its slot 1 is free and first, the project's own slot 2 is free.
      git clone -q "$dir/origin.git" "$dir/other/proj" 2>/dev/null
      printf 'treehouse.toml\n' >> "$dir/other/proj/.git/info/exclude"
      set_root "$proj" "$dir/root-old"
      set_root "$dir/other/proj" "$dir/root-old"
      a=$(lease "$dir/other/proj")
      b=$(lease "$proj")
      release "$dir/other/proj" "$a"
      release "$proj" "$b"
      printf 'foreign clone slot: %s\nown clone slot:     %s\n' "$a" "$b"
      ;;
    *) echo "unknown layout $layout" >&2; return 2 ;;
  esac
}

# describe_layout <case-dir>: print what Treehouse and git report for the shape.
describe_layout() {
  local dir=$1 proj
  proj="$dir/proj"
  printf 'configured root (treehouse.toml): %s\n' "$(sed -n 's/^root = //p' "$proj/treehouse.toml")"
  printf 'treehouse %s status --json in the project:\n' "$(treehouse --version 2>/dev/null | tr -d '[:space:]')"
  local out err
  err=$(mktemp "${TMPDIR:-/tmp}/rs-err.XXXXXX")
  if out=$(cd "$proj" && treehouse status --json </dev/null 2>"$err"); then
    printf '%s\n' "$out" | jq -c '.[] | {name, path, status}' 2>/dev/null | sed 's/^/  /'
    [ "$(printf '%s' "$out" | jq -c . 2>/dev/null)" != '[]' ] || printf '  []  (configured pool has no slot)\n'
  else
    printf '  (status --json unavailable, exit %s: %s)\n' "$?" "$(grep -v 'new version\|treehouse update' "$err" | head -1)"
  fi
  rm -f "$err"
  printf 'own-clone slots in git worktree list, with their pool state:\n'
  git -C "$proj" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ "$wt" != "$(cd "$proj" && pwd -P)" ] && [ "$wt" != "$proj" ] || continue
    local pool name state
    pool=$(dirname "$(dirname "$wt")"); name=$(basename "$(dirname "$wt")")
    state=$(jq -r --arg n "$name" '.worktrees[]? | select(.name == $n) | if (.leased // false) then "leased (busy)" elif (.owner_pid // null) != null then "owner pid \(.owner_pid)" else "free" end' "$pool/treehouse-state.json" 2>/dev/null)
    printf '  %s  [%s]\n' "$wt" "${state:-unknown}"
  done
}
