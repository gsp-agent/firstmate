#!/usr/bin/env bash
# fm_backend_meta_for_window walks the meta files and returns the first one
# whose window or terminal matches. The out-var form must agree with the
# printing form, a miss must clear the out-var, and the window text must stay
# data. Stock macOS bash 3.2 is a real target for bin/, so the contract re-runs
# there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-meta-for-window)
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
  # A caller may pass the out-var name "meta". A local of that same name
  # inside the lookup would swallow the path.
  local meta=unset
  fm_backend_meta_for_window "$1" "$2" meta || meta=
  printf '%s' "$meta"
}

test_first_meta_and_terminal_alias() {
  local state=$TMP_ROOT/agree got
  write_pair "$state"

  got=$(fm_backend_meta_for_window 'sess:shared' "$state") \
    || fail "printing form missed the shared window"
  assert_equals "$state/a.meta" "$got" "printing form kept the first meta for a shared window"
  got=$(fm_backend_meta_for_window 'term:only-b' "$state") \
    || fail "printing form missed the terminal alias"
  assert_equals "$state/b.meta" "$got" "printing form resolved the terminal alias"

  got=$(lookup_as_caller 'sess:shared' "$state")
  assert_equals "$state/a.meta" "$got" "out-var form kept the first meta for a shared window"
  got=$(lookup_as_caller 'term:only-b' "$state")
  assert_equals "$state/b.meta" "$got" "out-var form resolved the terminal alias"
  got=$(lookup_as_caller 'sess:plain' "$state")
  assert_equals "$state/c.meta" "$got" "a terminal equal to its window still resolves"

  pass "first meta wins and a terminal alias resolves, printed or through the out-var"
}

test_missing_target_clears_the_out_var() {
  local state=$TMP_ROOT/missing got
  write_pair "$state"
  got=sentinel
  fm_backend_meta_for_window 'sess:missing' "$state" got && fail "missing target returned success"
  assert_equals '' "$got" "missing target cleared the out-var"
  got=$(fm_backend_meta_for_window 'sess:missing' "$state" || true)
  assert_equals '' "$got" "missing target printed nothing"
  pass "a missing target fails, clears the out-var, and prints nothing"
}

test_window_text_is_not_executed() {
  local state=$TMP_ROOT/literal marker=$TMP_ROOT/pwned payload got
  mkdir -p "$state"
  # shellcheck disable=SC2016 # The window value is the characters, not a command.
  payload='$(touch '"$marker"')'
  fm_write_meta "$state/z.meta" "window=$payload" "kind=ship"
  rm -f "$marker"
  got=$(lookup_as_caller "$payload" "$state")
  [ ! -e "$marker" ] || fail "out-var lookup executed the window text"
  assert_equals "$state/z.meta" "$got" "out-var lookup did not return the literal window"
  got=$(fm_backend_meta_for_window "$payload" "$state" || true)
  [ ! -e "$marker" ] || fail "printing lookup executed the window text"
  assert_equals "$state/z.meta" "$got" "printing lookup did not return the literal window"
  pass "window text stays data"
}

test_first_meta_and_terminal_alias
test_missing_target_clears_the_out_var
test_window_text_is_not_executed

if [ "${FM_META_FOR_WINDOW_UNDER_BASH32:-}" != 1 ] && [ -x /bin/bash ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  FM_META_FOR_WINDOW_UNDER_BASH32=1 /bin/bash "$0" \
    || fail "meta-for-window contract failed under /bin/bash"
  pass "meta-for-window contract matches under /bin/bash"
fi
