#!/usr/bin/env bash
# One poll used to scan every meta file for every window. The index is that
# scan done once. A lookup through it must return the same first meta as the
# walk, including a terminal alias, and the window text must stay data.
# Stock macOS bash 3.2 is a real target for bin/, so the contract re-runs there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-window-index)
export LC_ALL=C

write_pair() {  # <state-dir>
  local state=$1
  mkdir -p "$state"
  # a.meta sorts first. Both claim the same window; the walk keeps a.meta.
  fm_write_meta "$state/a.meta" \
    "window=sess:shared" \
    "kind=secondmate" \
    "backend=tmux" \
    "harness=codex"
  fm_write_meta "$state/b.meta" \
    "window=sess:shared" \
    "terminal=term:only-b" \
    "kind=ship" \
    "backend=herdr" \
    "harness=claude"
  fm_write_meta "$state/c.meta" \
    "window=sess:plain" \
    "terminal=sess:plain" \
    "kind=ship" \
    "backend=tmux" \
    "harness=pi"
}

lookup_as_caller() {  # <target> <state-dir>
  # window_kind passes the out-var name "meta". A local of that same name
  # inside the lookup would swallow the path.
  local meta=unset
  fm_backend_meta_for_window "$1" "$2" meta || meta=
  printf '%s' "$meta"
}

test_index_matches_the_walk() {
  local state=$TMP_ROOT/agree walk indexed
  write_pair "$state"
  fm_backend_window_index_clear

  walk=$(fm_backend_meta_for_window 'sess:shared' "$state") \
    || fail "walk missed the shared window"
  assert_equals "$state/a.meta" "$walk" "walk kept the first meta for a shared window"

  walk=$(fm_backend_meta_for_window 'term:only-b' "$state") \
    || fail "walk missed the terminal alias"
  assert_equals "$state/b.meta" "$walk" "walk resolved the terminal alias"

  fm_backend_window_index_load "$state" || fail "index load failed"
  indexed=$(lookup_as_caller 'sess:shared' "$state")
  assert_equals "$state/a.meta" "$indexed" "index kept the first meta for a shared window"
  indexed=$(lookup_as_caller 'term:only-b' "$state")
  assert_equals "$state/b.meta" "$indexed" "index resolved the terminal alias"
  indexed=$(lookup_as_caller 'sess:plain' "$state")
  assert_equals "$state/c.meta" "$indexed" "a terminal equal to its window still resolves"

  indexed=sentinel
  fm_backend_meta_for_window 'sess:missing' "$state" indexed && fail "missing target returned success"
  assert_equals '' "$indexed" "missing target cleared the out-var"
  walk=$(fm_backend_meta_for_window 'sess:missing' "$state" || true)
  assert_equals '' "$walk" "missing target printed nothing"

  pass "index and walk agree: first meta, terminal alias, missing target"
}

test_failed_load_does_not_keep_a_stale_index() {
  local state=$TMP_ROOT/stale got
  write_pair "$state"
  fm_backend_window_index_load "$state" || fail "index load failed"
  fm_backend_window_index_load "$TMP_ROOT/no-such-dir" && fail "load of a missing dir returned success"
  fm_write_meta "$state/new.meta" "window=brand-new" "kind=ship"
  got=$(lookup_as_caller 'brand-new' "$state")
  assert_equals "$state/new.meta" "$got" "a failed reload left the previous index in place"
  pass "a failed index load falls back to the walk"
}

test_other_state_dir_is_not_served_from_the_index() {
  local a=$TMP_ROOT/state-a b=$TMP_ROOT/state-b got
  write_pair "$a"
  mkdir -p "$b"
  fm_write_meta "$b/only.meta" "window=sess:shared" "kind=ship"
  fm_backend_window_index_load "$a" || fail "index load failed"
  got=$(lookup_as_caller 'sess:shared' "$b")
  assert_equals "$b/only.meta" "$got" "a lookup in another state dir used the loaded index"
  pass "a loaded index applies only to the state dir it was built from"
}

test_window_text_is_not_executed() {
  local state=$TMP_ROOT/literal marker=$TMP_ROOT/pwned payload got
  mkdir -p "$state"
  # shellcheck disable=SC2016 # The window value is the characters, not a command.
  payload='$(touch '"$marker"')'
  fm_write_meta "$state/z.meta" "window=$payload" "kind=ship"
  fm_backend_window_index_clear
  fm_backend_window_index_load "$state" || fail "index load failed"
  rm -f "$marker"
  got=$(lookup_as_caller "$payload" "$state")
  [ ! -e "$marker" ] || fail "index lookup executed the window text"
  assert_equals "$state/z.meta" "$got" "index lookup did not return the literal window"
  fm_backend_window_index_clear
  got=$(lookup_as_caller "$payload" "$state")
  [ ! -e "$marker" ] || fail "walk executed the window text"
  assert_equals "$state/z.meta" "$got" "walk did not return the literal window"
  pass "window text stays data"
}

test_watch_helpers_skip_grep_and_cut() {
  local home=$TMP_ROOT/watch-home
  local state=$home/state
  local shim=$TMP_ROOT/shim log=$TMP_ROOT/ext.log script=$TMP_ROOT/watch-lookup.sh
  local out err
  mkdir -p "$state" "$shim"
  write_pair "$state"
  : > "$log"
  cat > "$shim/grep" <<SH
#!/bin/sh
printf '%s\n' "grep \$*" >> "$log"
exit 99
SH
  cat > "$shim/cut" <<SH
#!/bin/sh
printf '%s\n' "cut \$*" >> "$log"
exit 99
SH
  chmod 755 "$shim/grep" "$shim/cut"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
export FM_HOME="$home"
export FM_STATE_OVERRIDE="$state"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"
export PATH="$shim:\$PATH"
fm_backend_window_index_load "\$STATE" || exit 2
printf 'shared kind=%s backend=%s harness=%s\n' \
  "\$(window_kind 'sess:shared')" \
  "\$(window_backend 'sess:shared')" \
  "\$(window_harness 'sess:shared')"
printf 'alias kind=%s backend=%s harness=%s\n' \
  "\$(window_kind 'term:only-b')" \
  "\$(window_backend 'term:only-b')" \
  "\$(window_harness 'term:only-b')"
printf 'missing kind=%s backend=%s harness=%s\n' \
  "\$(window_kind 'sess:missing')" \
  "\$(window_backend 'sess:missing')" \
  "\$(window_harness 'sess:missing')"
fm_backend_window_index_clear
printf 'walk kind=%s\n' "\$(window_kind 'sess:plain')"
if [ -s "$log" ]; then
  printf 'external:\n'
  cat "$log"
  exit 3
fi
SH
  chmod 755 "$script"
  err=$TMP_ROOT/watch-lookup.err
  out=$(bash "$script" 2>"$err") || fail "watch helpers failed ($?): ${out:-}$(cat "$err" 2>/dev/null || true)"
  assert_equals 'shared kind=secondmate backend=tmux harness=codex
alias kind=ship backend=herdr harness=claude
missing kind=unknown backend=tmux harness=
walk kind=ship' "$out" "window helpers did not read the indexed meta"
  pass "window_kind, window_backend, and window_harness do not run grep or cut"
}

test_index_matches_the_walk
test_failed_load_does_not_keep_a_stale_index
test_other_state_dir_is_not_served_from_the_index
test_window_text_is_not_executed

if [ "${FM_WINDOW_INDEX_UNDER_BASH32:-}" != 1 ]; then
  test_watch_helpers_skip_grep_and_cut
  if [ -x /bin/bash ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    FM_WINDOW_INDEX_UNDER_BASH32=1 /bin/bash "$0" \
      || fail "window-index contract failed under /bin/bash"
    pass "window-index contract matches under /bin/bash"
  fi
fi
