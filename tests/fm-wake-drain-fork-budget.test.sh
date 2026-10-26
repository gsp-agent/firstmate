#!/usr/bin/env bash
# Per-status-file process budget for a settled bin/fm-wake-drain.sh
# (.agent-config-ks05d.4). The captain drains on every wake, and the drain reads
# every state/*.status log through fm-classify-lib.sh's cursor helpers: on the
# live 356-log home one settled drain started 21,658 processes. An unchanged
# log (same device, inode and size as its cursor) must now cost about nothing,
# while a changed or recreated log still takes the full read and is presented.
# Counted with the shared fork-budget counter (an inherited DEBUG trap plus
# logging PATH shims).
# shellcheck source=tests/watch-fork-budget-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-fork-budget-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
FAKEBIN="$TMP_ROOT/drain-fakebin"
mkdir -p "$FAKEBIN" "$TMP_ROOT/config"
# A home without the supervision host, as tests/fm-wake-drain-unread-status.test.sh pins it.
: > "$TMP_ROOT/config/supervision-host-off"
# shellcheck disable=SC2016 # The stand-ins, not this script, expand $$.
for tool in tmux herdr; do
  printf '#!/bin/sh\nprintf "x %%s %s\\n" "$$" >> "$FM_FORK_LOG"\nexit 1\n' "$tool" > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done

make_drain_home() {  # <name> <status-logs>
  local home="$TMP_ROOT/$1" i
  mkdir -p "$home/state" "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$2" ]; do
    printf 'window=fm:fm-task%s\nharness=claude\nkind=ship\nbackend=tmux\n' "$i" > "$home/state/task$i.meta"
    # A presented note settles the presentation cursor at the end of the log.
    printf 'working: step %s\nnote: shipped %s\n' "$i" "$i" > "$home/state/task$i.status"
    i=$((i + 1))
  done
  printf '%s\n' "$home"
}

# One drain on <home>; DRAIN_PROCS gets its distinct processes, DRAIN_OUT its stdout.
drain_once() {  # <home> <label>
  local log="$TMP_ROOT/$2.forks"
  : > "$log"
  DRAIN_OUT=$(unset TMUX FM_TASK_ID FM_SUPERVISION_ACTOR FM_FORK_MARK
    PATH="$FAKEBIN:$SHIMS:$REAL_PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" FM_DATA_OVERRIDE="$1/data" \
      BASH_ENV="$COUNTER" FM_FORK_LOG="$log" "$BASH" "$DRAIN" 2>/dev/null) \
    || fail "$2: drain failed"
  DRAIN_PROCS=$(awk '($1 == "p" || $1 == "x") && $2 != "" && !seen[$2]++ { c++ } END { print c + 0 }' "$log")
}

DRAIN_OUT=
DRAIN_PROCS=0
# Detect the interpreter's capability independently of the library, so this
# exact test also runs against upstream-lean before the helper exists. Keep the
# installation-relative path and disabled load aligned with _fm_status_stat_load.
cat > "$TMP_ROOT/probe-stat.sh" <<'SH'
lib="${BASH%/*}/../lib/bash/stat"
[ "${BASH_VERSINFO[0]}" -ge 4 ] && [ -f "$lib" ] && enable -n -f "$lib" stat 2>/dev/null
SH
STAT_BUILTIN=0
"$BASH" "$TMP_ROOT/probe-stat.sh" && STAT_BUILTIN=1

settled_per_log() {  # <label>
  local one one_procs
  one=$(make_drain_home "$1-one" 1)
  fifty=$(make_drain_home "$1-fifty" 50)
  drain_once "$one" "$1-one-first"
  assert_contains "$DRAIN_OUT" "task1 note: shipped 1" "$1: the first drain presents the unread note"
  drain_once "$one" "$1-one-settled"
  one_procs=$DRAIN_PROCS
  drain_once "$fifty" "$1-fifty-first"
  assert_contains "$DRAIN_OUT" "task50 note: shipped 50" "$1: the first drain presents every unread note"
  drain_once "$fifty" "$1-fifty-settled"
  assert_not_contains "$DRAIN_OUT" "note: shipped" "$1: a settled drain re-presents nothing"
  PER_LOG=$(( (DRAIN_PROCS - one_procs) / 49 ))
  printf '%s settled drain: 1 log %s processes, 50 logs %s, %s per added unchanged log\n' \
    "$1" "$one_procs" "$DRAIN_PROCS" "$PER_LOG"
}

PER_LOG=0
fifty=
# The external reads the library falls back to, forced even where the builtin
# exists: verdicts are the same, only the per-log cost differs.
(export FM_TEST_SEAM=1 FM_TEST_NO_STAT_BUILTIN=1; settled_per_log fallback) || exit 1
pass "the external-stat fallback presents and settles as before"
settled_per_log builtin
if [ "$STAT_BUILTIN" = 1 ]; then
  # Base 02ce380f: 53 per added log. Now 2: the open-decisions cursor is still
  # read with cat, so a failed read fails the cache rather than parsing short.
  [ "$PER_LOG" -le 3 ] || fail "a settled drain starts $PER_LOG processes per unchanged status log; budget is 3"
  pass "a settled drain's cost does not grow with unchanged status logs"
else
  echo "skip: no Bash stat loadable beside $BASH, so the per-log budget is not enforced here"
fi

# A changed log still takes the full read and its new line is presented.
printf 'note: follow-up 7\n' >> "$fifty/state/task7.status"
drain_once "$fifty" fifty-appended
assert_contains "$DRAIN_OUT" "task7 note: follow-up 7" "an appended note is presented"
assert_not_contains "$DRAIN_OUT" "task8 note:" "an unchanged log stays quiet beside a changed one"
pass "an appended log takes the full read and is presented"

# The premise: a log deleted and recreated at the same path, here with the very
# same bytes and size, gets a new inode on this volume, so its cursor no longer
# matches and the full read presents it from byte 0 again, as before the change.
inode_of() {  # <file>
  # shellcheck disable=SC2012 # ls -i is the one inode read both stat dialects share.
  LC_ALL=C ls -i "$1" | awk '{ print $1 }'
}
status=$fifty/state/task9.status
before=$(inode_of "$status")
cp "$status" "$TMP_ROOT/task9.copy" || fail "recreate: could not copy the log"
rm "$status" || fail "recreate: could not remove the log"
cp "$TMP_ROOT/task9.copy" "$status" || fail "recreate: could not recreate the log"
after=$(inode_of "$status")
[ "$before" != "$after" ] || fail "recreate: the recreated log kept inode $before"
drain_once "$fifty" fifty-recreated
assert_contains "$DRAIN_OUT" "task9 note: shipped 9" "a recreated log is presented from byte 0"
pass "a log deleted and recreated at its path gets a new inode and takes the full read"

# On Darwin a strong identity is reused only on device and inode, so the volume
# must never hand an inode number out again: churn delete-and-recreate and check.
if [ "$(uname -s)" = Darwin ]; then
  probe="$TMP_ROOT/inode-probe"
  mkdir -p "$probe"
  seen=$'\n'
  i=0
  : > "$probe/task.status"
  while [ "$i" -lt 200 ]; do
    ino=$(inode_of "$probe/task.status")
    case "$seen" in *$'\n'"$ino"$'\n'*) fail "inode probe: inode $ino was handed out again" ;; esac
    seen="$seen$ino"$'\n'
    rm "$probe/task.status" || fail "inode probe: could not remove the probe file"
    : > "$probe/other.$((i % 5))" || fail "inode probe: could not churn a sibling"
    : > "$probe/task.status" || fail "inode probe: could not recreate the probe file"
    i=$((i + 1))
  done
  pass "200 delete-and-recreate rounds never reuse an inode number on this volume"
fi
