#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
# None where a Bash built for Darwin names the kernel (fm-classify-lib.sh).
[ "$calls" -le 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name at most once per process"
}

test_read_text_helper_matches_cat() {
  local script="$TMP_ROOT/read-text.sh" cases="$TMP_ROOT/read-text-cases"
  mkdir -p "$cases/a-dir"
  printf 'one line\n' > "$cases/line"
  printf 'no newline' > "$cases/bare"
  printf 'two\nlines\n\n\n' > "$cases/trailing"
  printf '\n\n' > "$cases/newlines"
  : > "$cases/empty"
  printf ' padded \t\n' > "$cases/spaces"
  printf 'caf\303\251\n' > "$cases/utf8"
  printf 'a\0b\n' > "$cases/nul"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for f in "$2"/* "$2/missing"; do
  { want=$(cat "$f" 2>/dev/null || true); } 2>/dev/null
  { fm_read_text_to got "$f"; } 2>/dev/null
  [ "$got" = "$want" ] || printf 'read %s: helper %q, cat %q\n' "${f##*/}" "$got" "$want"
done
fm_read_text_to got "$2/missing" && printf 'a missing file read as present\n'
:
SH
  run_everywhere "read text helper" "$script" "$cases"
  pass "fm_read_text_to reads every file exactly as \$(cat file 2>/dev/null || true) does"
}

test_one_stat_snapshot_matches_the_per_file_signatures() {
  local script="$TMP_ROOT/snapshot.sh" dir="$TMP_ROOT/snapshot-state"
  mkdir -p "$dir"
  printf 'working: a\nneeds-decision: b\n' > "$dir/a.status"
  : > "$dir/empty.status"
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "line %d of a long status log\n", i }' > "$dir/long.status"
  printf 'caf\303\251: utf8\n' > "$dir/utf8.status"
  printf 'x\n' > "$dir/unread.status"
  chmod 000 "$dir/unread.status"
  ln -s a.status "$dir/link.status"
  mkfifo "$dir/fifo.status" 2>/dev/null || true
  printf 'turn\n' > "$dir/a.turn-ended"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-classify-lib.sh"
d=$2
files=("$d"/*.status "$d"/*.turn-ended "$d/missing.status")
fm_stat_snapshot "${files[@]}"
i=0
fast=0
for f in "${files[@]}"; do
  { want=$(fm_wake_signal_sig "$f"); } 2>/dev/null || want=
  case "$f" in
    *.turn-ended)
      [ "${FM_STAT_SNAPSHOT_TESIG[$i]}" = "$want" ] \
        || printf 'turn-ended %s: snapshot %q, per file %q\n' "${f##*/}" "${FM_STAT_SNAPSHOT_TESIG[$i]}" "$want"
      ;;
    *)
      if [ "${FM_STAT_SNAPSHOT_OK[$i]}" = 1 ] && status_observed_signature_from_fields_to got "$f" \
        "${FM_STAT_SNAPSHOT_STATE[$i]}" "${FM_STAT_SNAPSHOT_SIZE[$i]}" "${FM_STAT_SNAPSHOT_IDENT[$i]}"; then
        fast=$((fast + 1))
        [ "$got" = "$want" ] || printf 'status %s: snapshot %q, per file %q\n' "${f##*/}" "$got" "$want"
        # A second read is answered from the per-process encoding memo.
        status_observed_signature_from_fields_to again "$f" \
          "${FM_STAT_SNAPSHOT_STATE[$i]}" "${FM_STAT_SNAPSHOT_SIZE[$i]}" "${FM_STAT_SNAPSHOT_IDENT[$i]}"
        [ "$again" = "$want" ] || printf 'status %s: second read %q\n' "${f##*/}" "$again"
      else
        case "${f##*/}" in
          link.status|fifo.status|missing.status) ;;
          *) printf 'regular status %s took the per-file path\n' "${f##*/}" ;;
        esac
      fi
      ;;
  esac
  if [ "${FM_STAT_SNAPSHOT_OK[$i]}" = 1 ]; then
    m=$(fm_path_mtime "$f")
    [ "${FM_STAT_SNAPSHOT_MTIME[$i]}" = "$m" ] || printf 'mtime %s: snapshot %q, per file %q\n' "${f##*/}" "${FM_STAT_SNAPSHOT_MTIME[$i]}" "$m"
  fi
  i=$((i + 1))
done
fm_stat_snapshot_find "$d/a.status" || printf 'a snapshot path was not found\n'
fm_stat_snapshot_find "$d/never.status" && printf 'a path outside the snapshot was found\n'
[ "$fast" -ge 4 ] || printf 'only %s regular status logs took the one-stat path\n' "$fast"
:
SH
  run_everywhere "one-stat snapshot" "$script" "$dir"
  chmod 600 "$dir/unread.status"
  pass "one stat of every scanned file yields the signatures, turn-ended stamps, and mtimes the per-file reads print"
}

test_target_of_meta_to_matches_the_printing_form() {
  local script="$TMP_ROOT/target.sh" dir="$TMP_ROOT/target-metas"
  mkdir -p "$dir"
  printf 'window=sess:w1\n' > "$dir/plain.meta"
  printf 'backend=orca\nwindow=sess:w2\nterminal=term-2\n' > "$dir/orca.meta"
  printf 'backend=orca\nwindow=sess:w3\n' > "$dir/orca-bare.meta"
  printf 'backend=herdr\nwindow=w4:p1\nterminal=t4\n' > "$dir/herdr.meta"
  : > "$dir/empty.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-backend.sh"
for meta in "$2"/*.meta "$2/missing.meta"; do
  want=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_of_meta_to got "$meta"
  [ "$got" = "$want" ] || printf 'target %s: helper %q, printing form %q\n' "${meta##*/}" "$got" "$want"
done
:
SH
  run_everywhere "meta target" "$script" "$dir"
  pass "fm_backend_target_of_meta_to reads every meta's target as the printing form does"
}

# fm-crew-state.sh reads every run field, table row and ledger row through
# these (.agent-config-8c70c); each must answer as the subshell or pipeline it
# replaced did.
test_nm_field_and_trim_helpers_match_the_pipelines() {
  local script="$TMP_ROOT/nm-field.sh"
  cat > "$script" <<'SH'
. "$1/bin/fm-nm-run-lib.sh"
ref_trim() {  # the replaced fm_nm_trim
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
ref_strip_quotes() {  # the replaced fm_nm_strip_quotes
  local s
  s=$(ref_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  ref_trim "$s"
}
ref_field() {  # the replaced printf | sed | head read
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}
toon=$'run:\n  id: "01RUN"\n  status:running\n  status: second\n\tbranch:\t fm/x y \n  pr: ""\n  head: "abc\r"\n  status_x: no\n  gate :spaced\n  note: héllo "q" \n  empty:\n  blank:   \nkey: "a" b "c"\n  dotted: v.1'
for key in id status branch pr head status_x gate note empty blank key dotted missing run; do
  for text in "$toon" '' $'id: only\n' $'\n\n  id:   "  x  "  '; do
    want=$(ref_strip_quotes "$(ref_field "$text" "$key")")
    fm_nm_qfield_to got "$text" "$key"
    [ "$got" = "$want" ] || printf 'qfield %q: helper %q, pipeline %q\n' "$key" "$got" "$want"
    want=$(ref_field "$text" "$key")
    fm_nm_field_to got "$text" "$key"
    [ "$got" = "$want" ] || printf 'field %q: helper %q, pipeline %q\n' "$key" "$got" "$want"
  done
done
for s in '' ' ' '  "a"  ' '"a' 'a"' '""' '" "' $'\t"x y"\n' $'\r"x"\r' '"a"b"' 'plain' $'two\nlines '; do
  want=$(ref_trim "$s"); fm_nm_trim_to got "$s"
  [ "$got" = "$want" ] || printf 'trim %q: helper %q, subshell %q\n' "$s" "$got" "$want"
  want=$(ref_strip_quotes "$s"); fm_nm_strip_quotes_to got "$s"
  [ "$got" = "$want" ] || printf 'strip %q: helper %q, subshell %q\n' "$s" "$got" "$want"
  [ "$(fm_nm_strip_quotes "$s")" = "$want" ] || printf 'strip printing form %q differs\n' "$s"
done
:
SH
  run_everywhere "run field reads" "$script"
  pass "run field, trim and quote reads match the sed pipeline and the subshell trims"
}

test_nm_first_line_matches_grep() {
  local script="$TMP_ROOT/nm-line.sh"
  cat > "$script" <<'SH'
. "$1/bin/fm-nm-run-lib.sh"
text=$'run:\n  status: "awaiting_approval"\n  awaiting_agent: parked 2m\n  findings[2]{id,severity,file,line,action,description}:\n    r1,warning,a.go,,auto-fix,x\n  steps[3]{step,status,findings,duration_ms}:\n    review, "fix_review" ,0,1\n    ci,"running",0,2\n  gate:\n    step: review\n  state: fix_review \nfindings[0]: none\n  ci, fixing ,0,3'
for re in "$FM_NM_GATE_LINE_RE" "$FM_NM_AWAITING_AGENT_RE" "$FM_NM_GATE_SCALAR_RE" "$FM_NM_GATE_ROW_RE" \
  "$FM_NM_GATE_LINE_RE|$FM_NM_AWAITING_AGENT_RE|$FM_NM_GATE_SCALAR_RE|$FM_NM_GATE_ROW_RE" \
  'findings\[[0-9]+\]' '^[[:space:]]*findings\[[0-9]+\]\{[^}]*\}:' \
  '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' 'never-present'; do
  for t in "$text" '' $'gate: x\n' $'  ci,running,0,1\r'; do
    want=$(printf '%s\n' "$t" | grep -E "$re" | head -1)
    want_rc=0; printf '%s\n' "$t" | grep -Eq "$re" || want_rc=1
    got_rc=0; fm_nm_first_line_to got "$t" "$re" || got_rc=1
    [ "$got" = "$want" ] || printf 'line %q: helper %q, grep %q\n' "$re" "$got" "$want"
    [ "$got_rc" = "$want_rc" ] || printf 'line %q: helper status %s, grep %s\n' "$re" "$got_rc" "$want_rc"
  done
done
fm_nm_run_is_parked $'run:\n  status: running' && printf 'running run read as parked\n'
fm_nm_run_is_parked $'run:\n  awaiting_agent: parked' || printf 'awaiting run not read as parked\n'
:
SH
  run_everywhere "run line reads" "$script"
  pass "first-matching-line reads agree with grep -E | head -1 for every run regex"
}

test_meta_exact_value_matches_the_grep_pipeline() {
  local script="$TMP_ROOT/exact.sh" dir="$TMP_ROOT/exact-metas"
  mkdir -p "$dir/dir.meta"
  printf 'schema=v1\ntask_id=a\n' > "$dir/once.meta"
  printf 'task_id=a\ntask_id=b\n' > "$dir/twice.meta"
  printf 'task_id=\n' > "$dir/empty.meta"
  printf 'task_id=a=b=c\nstate=done' > "$dir/equals-no-newline.meta"
  printf 'task_id=a\r\n task_id=b\ntask_id_x=c\n' > "$dir/crlf.meta"
  printf 'other=1\n' > "$dir/absent.meta"
  printf 'task_id=x\n' > "$dir/unreadable.meta"
  chmod 000 "$dir/unreadable.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-backend.sh"
ref_exact() {  # the replaced grep -c / grep | cut read
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] 2>/dev/null || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}
for meta in "$2"/*.meta "$2/missing.meta"; do
  for key in task_id schema state task_id_x; do
    want_rc=0; want=$(ref_exact "$meta" "$key") || want_rc=1
    rc=0; got=$(fm_backend_meta_exact_value "$meta" "$key") || rc=1
    [ "$got/$rc" = "$want/$want_rc" ] || printf '%s %s: printing %q/%s, grep %q/%s\n' "${meta##*/}" "$key" "$got" "$rc" "$want" "$want_rc"
    rc=0; got=stale; fm_backend_meta_exact_value "$meta" "$key" got || rc=1
    [ "$got/$rc" = "$want/$want_rc" ] || printf '%s %s: out-var %q/%s, grep %q/%s\n' "${meta##*/}" "$key" "$got" "$rc" "$want" "$want_rc"
  done
done
:
SH
  run_everywhere "exact meta value" "$script" "$dir"
  chmod 600 "$dir/unreadable.meta"
  pass "fm_backend_meta_exact_value answers as the grep -c / grep | cut read for every record shape"
}

test_watch_read_helpers_preserve_results() {
  local script="$TMP_ROOT/watch-reads.sh" home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state" "$home/config"
  cat > "$script" <<'SH'
case_home=$(mktemp -d "$2/read-case.XXXXXX")
export FM_HOME=$case_home FM_STATE_OVERRIDE=$case_home/state FM_CONFIG_OVERRIDE=$case_home/config
mkdir -p "$FM_CONFIG_OVERRIDE"
. "$1/bin/fm-watch.sh"
printf 'window=s:fm-a\nharness=claude\nkind=ship\n' > "$STATE/a.meta"
printf 'backend=orca\nterminal=term-b\nharness=codex\nkind=secondmate\n' > "$STATE/b.meta"
printf 'window=s:fm-a\n' > "$STATE/c.meta"
window_kind s:fm-a kind
window_backend s:fm-a backend
window_harness s:fm-a harness
[ "$kind|$backend|$harness" = 'ship|tmux|claude' ] || printf 'metadata output-variable collision: %s\n' "$kind|$backend|$harness"
recorded_windows_to listed
[ "$listed" = $'s:fm-a\nterm-b' ] || printf 'window order or dedup differs: %q\n' "$listed"
printf 1 > "$STATE/.count-s_fm-a"
touch -t 202001010000 "$STATE/.count-s_fm-a"
fm_stat_snapshot "$STATE/.count-s_fm-a"
stale_scan_windows_to order
[ "$order" = $'term-b\ns:fm-a' ] || printf 'never-visited window order differs: %q\n' "$order"
printf 1 > "$STATE/.count-term-b"
touch -t 202001010000 "$STATE/.count-term-b"
fm_stat_snapshot "$STATE/.count-s_fm-a" "$STATE/.count-term-b"
stale_scan_windows_to order
[ "$order" = $'s:fm-a\nterm-b' ] || printf 'equal-age ordering was not stable: %q\n' "$order"
# Inbox fast path must leave every cleanup/delivery marker to the owner.
inbox_quiet_without_records a || printf 'absent inbox was not quiet\n'
mkdir -p "$STATE/a.inbox"
for marker in .ring-state .escalated .busy-state .retry-ring 0001.msg; do
  : > "$STATE/a.inbox/$marker"
  inbox_quiet_without_records a && printf 'ignored inbox marker %s\n' "$marker"
  rm -f "$STATE/a.inbox/$marker"
done
ln -s absent "$STATE/a.inbox/.ring-state"
inbox_quiet_without_records a && printf 'ignored broken inbox marker symlink\n'
# Status reads must notice writes and replacements, including between snapshots.
printf 'paused: external wait\n' > "$STATE/a.status"
fm_stat_snapshot "$STATE/a.status"
for reader in last_status_line status_declared_wait_line; do
  status_line_to value "$reader" "$STATE/a.status"
  want=$("$reader" "$STATE/a.status")
  [ "$value" = "$want" ] || printf '%s read differs initially\n' "$reader"
  status_line_to value "$reader" "$STATE/a.status"
  [ "$value" = "$want" ] || printf '%s repeated read differs\n' "$reader"
done
printf 'working: resumed\n' >> "$STATE/a.status"
fm_stat_snapshot "$STATE/a.status"
status_line_to value status_declared_wait_line "$STATE/a.status"
[ -z "$value" ] || printf 'resumed status retained its wait: %q\n' "$value"
printf 'done: complete\n' > "$STATE/replacement"
mv "$STATE/replacement" "$STATE/a.status"
fm_stat_snapshot "$STATE/a.status"
status_line_to value last_status_line "$STATE/a.status"
[ "$value" = 'done: complete' ] || printf 'replacement status retained cached value: %q\n' "$value"
printf 'working: changed after snapshot\n' > "$STATE/a.status"
status_line_to value last_status_line "$STATE/a.status"
[ "$value" = 'working: changed after snapshot' ] || printf 'stale snapshot suppressed a read: %q\n' "$value"
pane_hash_to first s_fm-a 'pane one'
pane_hash_to again s_fm-a 'pane one'
pane_hash_to changed s_fm-a 'pane two'
[ "$first" = "$again" ] && [ "$first" != "$changed" ] || printf 'pane hash memo ignored changed text\n'
:
SH
  run_everywhere "watch read helpers" "$script" "$home"
  pass "watch reads preserve metadata, visit order, inbox bookkeeping and changed status/pane results"
}

test_status_reads_notice_same_stamp_rewrites() {
  local script="$TMP_ROOT/status-rewrite.sh" home="$TMP_ROOT/rewrite-home"
  mkdir -p "$home"
  cat > "$script" <<'SH'
case_home=$(mktemp -d "$2/case.XXXXXX")
export FM_HOME=$case_home FM_STATE_OVERRIDE=$case_home/state FM_CONFIG_OVERRIDE=$case_home/config
mkdir -p "$FM_CONFIG_OVERRIDE"
. "$1/bin/fm-watch.sh"
printf 'paused: waiting on A\n' > "$STATE/task.status"
cp -p "$STATE/task.status" "$STATE/stamp"
fm_stat_snapshot "$STATE/task.status"
status_line_to value status_declared_wait_line "$STATE/task.status"
[ "$value" = 'paused: waiting on A' ] || printf 'initial status differs\n'
# GNU stat's second-resolution snapshot permits an ordinary same-size rewrite
# in the same second to keep this stamp. Pin it on all platforms for the proof.
printf 'paused: waiting on B\n' > "$STATE/task.status"
touch -r "$STATE/stamp" "$STATE/task.status"
fm_stat_snapshot "$STATE/task.status"
status_line_to value status_declared_wait_line "$STATE/task.status"
want=$(status_declared_wait_line "$STATE/task.status")
[ "$value" = "$want" ] || printf 'status %q differs from current reader %q after same-stamp rewrite\n' "$value" "$want"
:
SH
  run_everywhere "same-stamp status rewrite" "$script" "$home"
  pass "status reads notice same-size rewrites even when the recorded timestamp is unchanged"
}

test_inactive_cadence_skips_only_a_known_idle_main_home() {
  local script="$TMP_ROOT/inactive-cadence.sh" home="$TMP_ROOT/inactive-home"
  mkdir -p "$home"
  cat > "$script" <<'SH'
case_home=$(mktemp -d "$2/cadence-case.XXXXXX")
export FM_HOME=$case_home FM_STATE_OVERRIDE=$case_home/state FM_CONFIG_OVERRIDE=$case_home/config
mkdir -p "$FM_CONFIG_OVERRIDE"
. "$1/bin/fm-watch.sh"
marker="$STATE/.inactive-outcome-reconcile"
mkdir -p "$STATE/terminal-outcomes"
: > "$marker"
fm_stat_snapshot "$marker"
fm_stat_snapshot_find "$marker"
stamp=${FM_STAT_SNAPSHOT_MTIME[$FM_STAT_SNAPSHOT_AT]}
FM_INACTIVE_RECONCILE_NOW=$((stamp + 299))
inactive_reconcile_idle || printf 'a main-home scan ran before the default 300-second cadence\n'
FM_INACTIVE_RECONCILE_NOW=$((stamp + 300))
inactive_reconcile_idle && printf 'a due scan was skipped\n'
FM_INACTIVE_RECONCILE_NOW=$((stamp - 1))
inactive_reconcile_idle || printf 'future marker did not match the scanner zero-age rule\n'
FM_INACTIVE_RECONCILE_NOW=$stamp
for secs in 0 59 1801 invalid; do
  FM_INACTIVE_RECONCILE_SECS=$secs inactive_reconcile_idle && printf 'invalid interval %s was hidden\n' "$secs"
done
for budget in 0 31 invalid; do
  FM_INACTIVE_RECONCILE_BUDGET_SECS=$budget inactive_reconcile_idle && printf 'invalid budget %s was hidden\n' "$budget"
done
: > "$FM_HOME/.fm-secondmate-home"
inactive_reconcile_idle && printf 'secondmate ledger delivery was skipped\n'
mv "$FM_HOME/.fm-secondmate-home" "$FM_HOME/secondmate-marker"
ln -s missing "$FM_HOME/.fm-secondmate-home"
inactive_reconcile_idle && printf 'broken secondmate marker bypassed diagnostics\n'
mv "$FM_HOME/.fm-secondmate-home" "$FM_HOME/secondmate-link"
mv "$STATE/terminal-outcomes" "$STATE/saved-outcomes"
inactive_reconcile_idle && printf 'missing outcome directory was not created by the scanner\n'
ln -s saved-outcomes "$STATE/terminal-outcomes"
inactive_reconcile_idle && printf 'symlink outcome directory bypassed scanner validation\n'
mv "$STATE/terminal-outcomes" "$STATE/outcomes-link"
mv "$STATE/saved-outcomes" "$STATE/terminal-outcomes"
mv "$marker" "$STATE/saved-marker"
inactive_reconcile_idle && printf 'missing cadence marker was skipped\n'
ln -s saved-marker "$marker"
fm_stat_snapshot "$marker"
inactive_reconcile_idle && printf 'symlink cadence marker was trusted\n'
mv "$marker" "$STATE/marker-link"
mv "$STATE/saved-marker" "$marker"
fm_stat_snapshot "$STATE/not-the-marker"
inactive_reconcile_idle && printf 'marker outside the snapshot was skipped\n'
:
SH
  run_everywhere "inactive reconciliation cadence" "$script" "$home"
  pass "only a known idle main-home scan is skipped; due scans, secondmates and uncertain state keep the existing path"
}

test_touch_helper_moves_the_mtime_like_touch() {
  local script="$TMP_ROOT/touch.sh" dir="$TMP_ROOT/touch-cases"
  mkdir -p "$dir"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
d=$2
rm -f "$d"/beat "$d"/full "$d"/link "$d"/new
: > "$d/beat"
printf 'kept\n' > "$d/full"
ln -s full "$d/link"
touch -t 202001010000 "$d/beat" "$d/full"
fm_epoch_seconds_to before
for f in beat full link new; do
  fm_touch_empty "$d/$f" || printf 'fm_touch_empty %s failed\n' "$f"
done
for f in beat full new; do
  m=$(fm_path_mtime "$d/$f")
  [ "$m" -ge $((before - 2)) ] || printf '%s mtime %s did not move to now (%s)\n' "$f" "$m" "$before"
done
[ ! -s "$d/beat" ] || printf 'the empty beacon gained content\n'
[ ! -s "$d/new" ] && [ -f "$d/new" ] || printf 'a missing marker was not created empty\n'
[ "$(cat "$d/full")" = kept ] || printf 'a file with content lost it\n'
[ -L "$d/link" ] && [ "$(cat "$d/link")" = kept ] || printf 'a symlink was followed into truncation\n'
:
SH
  run_everywhere "touch helper" "$script" "$dir"
  pass "fm_touch_empty moves an empty marker's mtime and leaves content and symlink targets alone"
}

test_fixed_read_helpers_match_the_existing_readers() {
  local script="$TMP_ROOT/fixed-reads.sh" home="$TMP_ROOT/fixed-home"
  mkdir -p "$home"
  cat > "$script" <<'SH'
case_home=$(mktemp -d "$2/fixed-case.XXXXXX")
export FM_HOME=$case_home FM_STATE_OVERRIDE=$case_home/state FM_CONFIG_OVERRIDE=$case_home/config
mkdir -p "$FM_CONFIG_OVERRIDE"
. "$1/bin/fm-watch.sh"
for override in '' '/a path' $'/with\ninside' $'/with\n\n' $'\n\n'; do
  FM_PENDING_REPLY_DIR_OVERRIDE=$override
  want=$(fm_pending_reply_dir "$STATE")
  fm_pending_reply_dir_to got "$STATE"
  [ "$got" = "$want" ] || printf 'pending directory helper differs: %q versus %q\n' "$got" "$want"
done
printf 'check\tordinary\tprose\n' > "$FM_WAKE_QUEUE"
procevent_queue_may_hold_key && printf 'ordinary row unnecessarily took process-event path\n'
printf 'check\tprocevent:source:1\tresult\n' >> "$FM_WAKE_QUEUE"
procevent_queue_may_hold_key || printf 'queued process-event was missed\n'
printf 'check\tprocevent:partial' > "$FM_WAKE_QUEUE"
procevent_queue_may_hold_key || printf 'unterminated candidate was missed\n'
:
SH
  run_everywhere "fixed poll reads" "$script" "$home"
  pass "pending directory reads and the conservative process-event precheck preserve results"
}

test_sleep_helper_waits_without_a_process() {
  local script="$TMP_ROOT/sleep.sh" shim="$TMP_ROOT/sleep-shim" log="$TMP_ROOT/sleep.log"
  mkdir -p "$shim"
  cat > "$shim/sleep" <<SH
#!/bin/sh
printf 'sleep\n' >> "$log"
exec $(command -v sleep) "\$@"
SH
  chmod +x "$shim/sleep"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
PATH="$2:$PATH"
: > "$3"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
start=$(now)
fm_sleep 0.3
mid=$(now)
fm_sleep 0
( fm_sleep 0.2 )
end=$(now)
perl -e 'exit !($ARGV[1] - $ARGV[0] >= 0.28 && $ARGV[1] - $ARGV[0] < 3)' "$start" "$mid" \
  || printf 'fm_sleep 0.3 took %s to %s\n' "$start" "$mid"
perl -e 'exit !($ARGV[1] - $ARGV[0] >= 0.18 && $ARGV[1] - $ARGV[0] < 3)' "$mid" "$end" \
  || printf 'fm_sleep 0 then a subshell fm_sleep 0.2 took %s to %s\n' "$mid" "$end"
sleeps=$(grep -c . "$3" || true)
if fm_sleep_builtin_available; then
  [ "$sleeps" -eq 0 ] || printf 'bash %s with its sleep builtin ran sleep %s times\n' "$BASH_VERSION" "$sleeps"
else
  # Without the builtin every wait runs sleep(1), as before, including sleep 0.
  [ "$sleeps" -eq 3 ] || printf 'bash %s ran sleep %s times, not once per wait\n' "$BASH_VERSION" "$sleeps"
fi
# The builtin is enabled only for the wait, so later sleeps reach PATH.
[ "$(type -t sleep)" = file ] || printf 'sleep resolves to %s after fm_sleep\n' "$(type -t sleep)"
SH
  command -v perl >/dev/null 2>&1 || { pass "fm_sleep: skipped (perl absent for sub-second timing)"; return 0; }
  run_everywhere "sleep helper" "$script" "$shim" "$log"
  pass "fm_sleep waits the requested time, returns at once for 0, and starts no process where the sleep builtin exists"
}

test_sleep_signal_cleanup_runs_to_completion() {
  local script="$TMP_ROOT/sleep-signal.sh" dir="$TMP_ROOT/sleep-signal"
  mkdir -p "$dir"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
CASE_DIR=$2
set -T
trap 'if [ "${FUNCNAME[0]:-}" = fm_sleep ] && [ "$BASH_COMMAND" = '\''sleep "$@"'\'' ]; then : > "$CASE_DIR/ready"; fi' DEBUG
trap 'printf started > "$CASE_DIR/cleanup"; sleep 3; printf completed >> "$CASE_DIR/cleanup"; exit 143' TERM
fm_sleep 2
printf 'continued' > "$CASE_DIR/continued"
SH
  (
    child=
    trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi' EXIT
    while IFS= read -r interpreter; do
      for fallback in '' 1; do
        case_dir=$(mktemp -d "$dir/case.XXXXXX")
        FM_TEST_SEAM=1 FM_TEST_NO_SLEEP_BUILTIN=$fallback FM_STATE_OVERRIDE="$case_dir/state" \
          "$interpreter" "$script" "$ROOT" "$case_dir" > "$case_dir/output" 2>&1 &
        child=$!
        tries=0
        while [ ! -e "$case_dir/ready" ] && [ "$tries" -lt 300 ]; do
          sleep 0.01
          tries=$((tries + 1))
        done
        [ -e "$case_dir/ready" ] || fail "sleep signal: wait was not entered"
        sleep 0.1
        kill -TERM "$child" || fail "sleep signal: child exited before TERM"
        rc=0
        wait "$child" || rc=$?
        child=
        [ "$rc" = 143 ] || fail "sleep signal: expected 143, got $rc"
        [ "$(cat "$case_dir/cleanup")" = startedcompleted ] || fail "sleep signal: cleanup was interrupted"
        [ ! -e "$case_dir/continued" ] || fail "sleep signal: normal execution resumed after TERM"
      done
    done < <(test_interpreters)
  ) || fail "sleep signal cleanup regression"
  pass "TERM completes cleanup even beyond the interrupted wait, with builtin and external sleep"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_read_text_helper_matches_cat
  test_sleep_helper_waits_without_a_process
  test_sleep_signal_cleanup_runs_to_completion
  test_touch_helper_moves_the_mtime_like_touch
  test_one_stat_snapshot_matches_the_per_file_signatures
  test_target_of_meta_to_matches_the_printing_form
  test_watch_read_helpers_preserve_results
  test_status_reads_notice_same_stamp_rewrites
  test_inactive_cadence_skips_only_a_known_idle_main_home
  test_fixed_read_helpers_match_the_existing_readers
  test_nm_field_and_trim_helpers_match_the_pipelines
  test_nm_first_line_matches_grep
  test_meta_exact_value_matches_the_grep_pipeline
fi
