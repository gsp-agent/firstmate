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
# shellcheck disable=SC2030 # Each forced answer stays inside its own subshell.
(export FM_TEST_SEAM=1 FM_TEST_NO_STAT_BUILTIN=1; settled_per_log fallback) || exit 1
pass "the external-stat fallback presents and settles as before"
# A volume not proven APFS keeps the full identity read, verdicts unchanged.
# shellcheck disable=SC2030,SC2031 # Each forced answer stays inside its own subshell.
(export FM_TEST_SEAM=1 FM_TEST_STATUS_VOLUME=other; settled_per_log non-apfs) || exit 1
pass "a volume not proven APFS presents and settles as before"
settled_per_log builtin
if [ "$STAT_BUILTIN" = 1 ]; then
  # Base 02ce380f: 53 per added log. Now 2: the open-decisions cursor is still
  # read with cat, so a failed read fails the cache rather than parsing short.
  [ "$PER_LOG" -le 3 ] || fail "a settled drain starts $PER_LOG processes per unchanged status log; budget is 3"
  pass "a settled drain's cost does not grow with unchanged status logs"
else
  echo "skip: no Bash stat loadable beside $BASH, so the per-log budget is not enforced here"
fi

# chip's review case on a volume that may recycle inode numbers: a log replaced
# in place by same-size bytes whose recorded birth time (111.0) no longer matches
# the file's own. Device, inode and size all still match, so only a forced
# non-APFS answer can show it: the full read must see the new birth time, treat
# the log as replaced, and present the new bytes.
cat > "$TMP_ROOT/ident-probe.sh" <<'SH'
. "$1/bin/fm-classify-lib.sh"
f=$2
real=$(_fm_open_decisions_file_ident "$f") || exit 1
size=$(LC_ALL=C wc -c < "$f" | tr -d ' ')
stale="strong:${real#strong:}"
stale="${stale%:*}:111.0"
_fm_open_decisions_file_ident_to got "$f" "$stale" "$size" || exit 1
if [ "$got" = "$real" ]; then echo full; elif [ "$got" = "$stale" ]; then echo kept; else echo other; fi
SH
probe_log="$TMP_ROOT/ident-probe.status"
printf 'note: twelve\n' > "$probe_log"
if [ "$(uname -s)" = Darwin ] && [ "$STAT_BUILTIN" = 1 ]; then
  verdict=$(FM_TEST_SEAM=1 FM_TEST_STATUS_VOLUME=other "$BASH" "$TMP_ROOT/ident-probe.sh" "$ROOT" "$probe_log")
  assert_equals full "$verdict" "a non-APFS volume reads the current birth time instead of the recorded one"
  verdict=$(FM_TEST_SEAM=1 FM_TEST_STATUS_VOLUME=apfs "$BASH" "$TMP_ROOT/ident-probe.sh" "$ROOT" "$probe_log")
  assert_equals kept "$verdict" "a proven APFS volume keeps the recorded identity"
  pass "the recorded strong identity is kept only on a proven APFS volume"

  replaced=$(make_drain_home replaced 3)
  drain_once "$replaced" replaced-first
  drain_once "$replaced" replaced-settled
  manifest="$replaced/state/.status-presentation-cursor"
  awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "task2" { sub(/:[0-9.]+$/, ":111.0", $2) } { print }' "$manifest" > "$manifest.new" \
    || fail "replaced: could not age the recorded birth time"
  mv "$manifest.new" "$manifest" || fail "replaced: could not replace the manifest"
  cursor="$replaced/state/.task2.open-decisions-cursor"
  sed 's/^\(ident=strong:.*:\)[0-9.]*$/\1111.0/' "$cursor" > "$cursor.new" \
    || fail "replaced: could not age the open-decisions cursor"
  mv "$cursor.new" "$cursor" || fail "replaced: could not replace the cursor"
  log="$replaced/state/task2.status"
  bytes=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  printf 'working: step Y\nnote: shipped Z\n' > "$log"
  [ "$(LC_ALL=C wc -c < "$log" | tr -d ' ')" = "$bytes" ] || fail "replaced: the rewrite changed the size"
  # shellcheck disable=SC2031 # The forced answer stays inside this subshell.
  (
    export FM_TEST_SEAM=1 FM_TEST_STATUS_VOLUME=other
    drain_once "$replaced" replaced-non-apfs
    assert_contains "$DRAIN_OUT" "task2 note: shipped Z" "a same-size replacement on a non-APFS volume is presented"
  ) || exit 1
  pass "a same-size replacement with a new birth time is presented off APFS"
fi

# The latest-event read stays bounded to the captured endpoint: it reads exactly
# that many bytes, only from a file of exactly that size, and otherwise defers
# to the bounded perl reader, matching it byte for byte where it answers.
cat > "$TMP_ROOT/latest-probe.sh" <<'SH'
. "$1/bin/fm-classify-lib.sh"
case "$2" in
  shell)
    _fm_status_latest_line_read "$3" "$4" 65536
    rc=$?
    printf '%s\t%s\t%s\n' "$rc" "$_FM_STATUS_LATEST_END" "$_FM_STATUS_LATEST_LINE"
    ;;
  span)
    _fm_status_read_span "$3" 0 "$4" | LC_ALL=C wc -c | tr -d ' '
    ;;
  event)
    ident=$(_fm_open_decisions_file_ident "$3") || exit 1
    if status_snapshot_latest_event "$3" "$4" "$ident"; then
      printf '0\t%s\t%s\n' "$FM_STATUS_SNAPSHOT_EVENT_ENDPOINT" "$FM_STATUS_SNAPSHOT_EVENT_LINE"
    else
      printf '1\t\t\n'
    fi
    ;;
esac
SH
cat > "$TMP_ROOT/span-reader.sh" <<'SH'
#!/usr/bin/env bash
tail -c "+$(($2 + 1))" "$1" | head -c "$3"
SH
chmod +x "$TMP_ROOT/span-reader.sh"
latest() { "$BASH" "$TMP_ROOT/latest-probe.sh" "$ROOT" "$@"; }
if [ "$STAT_BUILTIN" = 1 ]; then
  nul="$TMP_ROOT/nul-after.status"
  printf 'note: x\n\000tail\n' > "$nul"
  assert_equals "2" "$(latest shell "$nul" 8 | cut -f1)" "a file longer than its endpoint defers to the bounded reader"
  assert_equals "8" "$(latest span "$nul" 8)" "the bounded span reader returns exactly the endpoint's bytes"
  grown="$TMP_ROOT/grown.status"
  printf 'note: before\n' > "$grown"
  endpoint=$(LC_ALL=C wc -c < "$grown" | tr -d ' ')
  printf 'note: appended after the size check\n' >> "$grown"
  assert_equals "2" "$(latest shell "$grown" "$endpoint" | cut -f1)" "a file grown past its endpoint is not read by the shell"
  assert_equals "1" "$(latest event "$grown" "$endpoint" | cut -f1)" "a grown file yields no event, as before"
  inside="$TMP_ROOT/nul-inside.status"
  printf 'no\000te: y\n' > "$inside"
  assert_equals "2" "$(latest shell "$inside" 10 | cut -f1)" "a NUL inside the span defers to the bounded reader"
  i=0
  for body in 'note: a\n' 'note: a\n\n  \n' 'note: a\r\r\n' 'note: a\nworking: b' $'note: caf\xc3\xa9\n \t\n' 'x\n\f\v\n' ' lead\ttab \n'; do
    i=$((i + 1))
    f="$TMP_ROOT/same-$i.status"
    printf '%b' "$body" > "$f"
    size=$(LC_ALL=C wc -c < "$f" | tr -d ' ')
    shell=$(latest event "$f" "$size")
    perl=$(FM_STATUS_SPAN_READER="$TMP_ROOT/span-reader.sh" latest event "$f" "$size")
    assert_equals "$perl" "$shell" "latest event of case $i matches the perl reader"
    assert_equals "0" "$(latest shell "$f" "$size" | cut -f1)" "case $i is answered in the shell"
  done
  pass "the latest-event read is bounded to its endpoint and matches the perl reader"
fi

# Reading a long unread span stays linear in its bytes. A log of only routine
# working: lines keeps its presentation cursor at byte 0, a reachable settled
# state that every drain reads twice, so 2,000 vs 10,000 such lines must take
# about five times as long, not twenty-five (chip's review of ddb65445: 0.14 s on
# 2f8ac29b, 7.76 s there). The same holds for the 64 KiB latest-event read.
# A ratio of best-of-three timings, not an absolute bound, so machine load
# cannot fail it. Needs EPOCHREALTIME (Bash 5).
cat > "$TMP_ROOT/scale-probe.sh" <<'SH'
# A C locale keeps EPOCHREALTIME's decimal point a dot.
export LC_ALL=C
. "$1/bin/fm-classify-lib.sh"
best=
for _ in 1 2 3; do
  start=$EPOCHREALTIME
  case "$2" in
    unread) status_new_lines_since_cursor "$3" > /dev/null || exit 1 ;;
    latest) _fm_status_latest_line_read "$3" "$4" 65536 || exit 1 ;;
  esac
  end=$EPOCHREALTIME
  took=$(( (${end%.*} - ${start%.*}) * 1000000 + 10#${end#*.} - 10#${start#*.} ))
  if [ -z "$best" ] || [ "$took" -lt "$best" ]; then best=$took; fi
done
printf '%s\n' "$best"
SH
if [ -n "${EPOCHREALTIME:-}" ]; then
  scale="$TMP_ROOT/scale"
  mkdir -p "$scale"
  awk 'BEGIN { for (i = 1; i <= 2000; i++) printf "working: step %d of the routine loop\n", i }' > "$scale/small.status"
  awk 'BEGIN { for (i = 1; i <= 10000; i++) printf "working: step %d of the routine loop\n", i }' > "$scale/large.status"
  small=$("$BASH" "$TMP_ROOT/scale-probe.sh" "$ROOT" unread "$scale/small.status") || fail "scale: unread read failed"
  large=$("$BASH" "$TMP_ROOT/scale-probe.sh" "$ROOT" unread "$scale/large.status") || fail "scale: unread read failed"
  printf 'unread span: 2,000 lines %s us, 10,000 lines %s us (budget 10x)\n' "$small" "$large"
  [ "$large" -le $((small * 10 + 20000)) ] \
    || fail "unread span: 10,000 lines took $large us against $small us for 2,000; the read is not linear"
  pass "an unread span of routine lines is read in time linear in its length"
  if [ "$STAT_BUILTIN" = 1 ]; then
    awk 'BEGIN { for (i = 1; i <= 3200; i++) printf "w %d\n", i % 10 }' > "$scale/small-latest.status"
    awk 'BEGIN { for (i = 1; i <= 16000; i++) printf "w %d\n", i % 10 }' > "$scale/large-latest.status"
    small=$("$BASH" "$TMP_ROOT/scale-probe.sh" "$ROOT" latest "$scale/small-latest.status" 12800) || fail "scale: latest read failed"
    large=$("$BASH" "$TMP_ROOT/scale-probe.sh" "$ROOT" latest "$scale/large-latest.status" 64000) || fail "scale: latest read failed"
    printf 'latest-event span: 12,800 bytes %s us, 64,000 bytes %s us (budget 10x)\n' "$small" "$large"
    [ "$large" -le $((small * 10 + 20000)) ] \
      || fail "latest-event span: 64,000 bytes took $large us against $small us for 12,800; the read is not linear"
    pass "the latest-event read is linear in its 64 KiB span"
  fi
else
  echo "skip: no EPOCHREALTIME in $BASH, so the linear-read ratios are not measured"
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
