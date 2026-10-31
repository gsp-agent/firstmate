#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting), fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment), and fm-dod-lib.sh
# (the custody check a Gerrit no-mistakes ready report must pass). Crew-state binds
# an EXECUTING run (pending, running, fixing or ci) on the task's branch
# regardless of head (fm_nm_run_is_executing); every other run still needs
# strict branch-and-head identity. Both callers then recognize a provable
# pipeline-owned continuation through fm_nm_runs_status_for_worktree below:
# crew-state for an ACTIVE run - parked, or executing with the daemon answered
# down - so a fix round never reads as an older
# failed run, and teardown for a run PARKED at a gate, so cleanup concludes it
# instead of orphaning it. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
# fm_nm_run_wait owns the proof that a working run waits on someone else,
# which fm-crew-state.sh names for the place count.
#
# Bounded call to an arbitrary command in dir $1, timeout $2 seconds, and its
# `no-mistakes "$@"` specialization. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
# bin/fm-timeout-lib.sh's fm_run_timed owns timeout mechanisms, exit-status
# normalization, and process-group cleanup; its header defines their limits.
# An absolute, already-normal path is its own logical directory; only a
# relative or unnormalized one needs the cd/pwd subshell.
_FM_NM_RUN_LIB_DIR=${BASH_SOURCE[0]%/*}
case "$_FM_NM_RUN_LIB_DIR/" in
  */./*|*/../*|*//*|[!/]*|/) _FM_NM_RUN_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) ;;
esac
# That library declares `set -u` for its own hygiene, which a sourced sibling
# must not impose on this library's consumers, so the caller's setting is
# restored around the source.
case $- in *u*) _fm_nm_run_nounset=on ;; *) _fm_nm_run_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_NM_RUN_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_nm_run_nounset" = on ] || set +u
unset _fm_nm_run_nounset

fm_nm_bounded() {  # <dir> <timeout_secs> <command> <args...>
  local dir=$1 timeout_secs=$2
  shift 2
  ( cd "$dir" && fm_run_timed "$timeout_secs" "$@" )
}

fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2
  shift 2
  # Keep this no-mistakes invocation's object probes local: a partial clone
  # would otherwise lazy-fetch a missing pipeline head during a status read.
  # The subshell confines this policy to no-mistakes and its children, without
  # changing the caller or requiring an env binary on a restricted PATH. It is
  # fm_nm_bounded's own subshell, inlined, so one call starts one subshell.
  ( export GIT_NO_LAZY_FETCH=1; cd "$dir" && fm_run_timed "$timeout_secs" no-mistakes "$@" )
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

# The _to forms assign <out-var> and start no process: fm-crew-state.sh trims
# every row of a run's steps table and of the runs ledger on each call, which
# cost a subshell per value (.agent-config-8c70c). The printing forms delegate.
fm_nm_trim_to() {  # <out-var> <string>
  local _fm_nm_trim_s=${2:-}
  _fm_nm_trim_s="${_fm_nm_trim_s#"${_fm_nm_trim_s%%[![:space:]]*}"}"
  printf -v "$1" '%s' "${_fm_nm_trim_s%"${_fm_nm_trim_s##*[![:space:]]}"}"
}

fm_nm_trim() {
  local s
  fm_nm_trim_to s "${1:-}"
  printf '%s' "$s"
}

fm_nm_strip_quotes_to() {  # <out-var> <string>
  local _fm_nm_sq_s
  fm_nm_trim_to _fm_nm_sq_s "${2:-}"
  case "$_fm_nm_sq_s" in
    \"*\") _fm_nm_sq_s=${_fm_nm_sq_s#\"}; _fm_nm_sq_s=${_fm_nm_sq_s%\"} ;;
  esac
  fm_nm_trim_to "$1" "$_fm_nm_sq_s"
}

fm_nm_strip_quotes() {
  local s
  fm_nm_strip_quotes_to s "${1:-}"
  printf '%s' "$s"
}

# Path of no-mistakes' local state database as the CLI would see it from
# worktree $1: <NM_HOME>/state.sqlite, with NM_HOME defaulting to
# ~/.no-mistakes and a relative NM_HOME resolving from that worktree. Readers
# open it with SQLite's mode=ro, so a missing database is never created.
fm_nm_state_db() {  # <worktree>
  local root=${NM_HOME:-}
  [ -n "$root" ] || root=~/.no-mistakes
  case "$root" in
    /*) ;;
    *) root="$1/$root" ;;
  esac
  printf '%s/state.sqlite\n' "$root"
}

# Unix seconds of run $2's updated_at in the state database fm_nm_state_db
# locates for worktree $1. That column is the run record's last word, so a
# status line stamped after it is newer evidence than the outcome a terminal
# read would otherwise trust. Empty when the database, the row, or the value
# is missing or not a canonical epoch. Read-only: a missing database is never
# created. The read is bounded at 2 seconds.
fm_nm_run_updated_epoch() {  # <worktree> <run-id>
  local db id epoch
  id=${2:-}
  case "$id" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  db=$(fm_nm_state_db "$1")
  [ -f "$db" ] && [ ! -L "$db" ] || return 0
  epoch=$(fm_nm_bounded "$1" 2 python3 -I - "$db" "$id" 2>/dev/null <<'PY'
import sqlite3
import sys
from pathlib import Path

database, run_id = sys.argv[1:]
try:
    connection = sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=1)
    try:
        row = connection.execute(
            "SELECT updated_at FROM runs WHERE id = ?",
            (run_id,),
        ).fetchone()
    finally:
        connection.close()
except (OSError, sqlite3.Error, ValueError):
    raise SystemExit(0)
if not row or isinstance(row[0], bool) or not isinstance(row[0], int) or row[0] <= 0:
    raise SystemExit(0)
print(row[0])
PY
) || return 0
  case "$epoch" in ''|*[!0-9]*|0*) return 0 ;; esac
  [ "${#epoch}" -le 12 ] || return 0
  printf '%s' "$epoch"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# fm_nm_field's value assigned to <out-var>, starting no process for a plain
# key: the first line whose text after leading whitespace starts <key>:, with
# the whitespace after the colon dropped. A key the sed pattern would read as
# a regex takes fm_nm_field itself.
fm_nm_field_to() {  # <out-var> <toon-output> <key>
  local _fm_nm_line _fm_nm_rest
  case "$3" in
    ''|*[!A-Za-z0-9_]*) printf -v "$1" '%s' "$(fm_nm_field "$2" "$3")"; return 0 ;;
  esac
  while IFS= read -r _fm_nm_line; do
    _fm_nm_rest=${_fm_nm_line#"${_fm_nm_line%%[![:space:]]*}"}
    case "$_fm_nm_rest" in
      "$3:"*)
        _fm_nm_rest=${_fm_nm_rest#"$3:"}
        printf -v "$1" '%s' "${_fm_nm_rest#"${_fm_nm_rest%%[![:space:]]*}"}"
        return 0 ;;
    esac
  done <<< "$2"
  printf -v "$1" '%s' ''
}

# fm_nm_strip_quotes of fm_nm_field, assigned to <out-var>: the run's scalar
# as callers compare it.
fm_nm_qfield_to() {  # <out-var> <toon-output> <key>
  fm_nm_field_to "$1" "$2" "$3"
  fm_nm_strip_quotes_to "$1" "${!1}"
}

# The first line of <text> matching extended regex <ere>, assigned to
# <out-var> ('' and 1 when none). The printf | grep -E | head -1 it replaces
# started three processes per read.
fm_nm_first_line_to() {  # <out-var> <text> <ere>
  local _fm_nm_line
  while IFS= read -r _fm_nm_line; do
    if [[ $_fm_nm_line =~ $3 ]]; then
      printf -v "$1" '%s' "$_fm_nm_line"
      return 0
    fi
  done <<< "$2"
  printf -v "$1" '%s' ''
  return 1
}

# Full commit sha for sha-ish $2 as seen from worktree $1's own object store;
# empty when the object is absent or ambiguous. Read-only: never fetches,
# never moves refs or custody.
fm_nm_resolve_commit() {  # <worktree> <sha-ish>
  git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null || true
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# A run head whose object this copy does not have cannot be proven here and is
# rejected; fm_nm_runs_status_for_worktree below owns the one ledger-anchored
# recognition for that case, fm_nm_run_is_executing below is the current-state
# exemption for a live run on this branch regardless of head, and
# fm_nm_run_is_pipeline_owned_active below carries the custody exemption: ANY
# active run - executing or parked - whose pipeline currently owns the branch
# binds without head equality.
#
# This predicate binds one run at a time, and MORE THAN ONE recorded run can
# bind to the same worktree at once: a run that died at the worktree's exact
# commit still binds by the equal-commit rule while its live successor binds by
# the ancestor rule (observed 2026-08: a crashed validation daemon left a failed
# run at the worktree's own commit while the live run that replaced it validated
# a descendant commit on the same branch).
# Head compatibility alone does not establish precedence between runs.
# fm_nm_select_run below owns identity-aware selection for current-state reads;
# fm_nm_runs_status_for_worktree owns the coarse ledger fallback.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(fm_nm_resolve_commit "$wt" "$run_head")
  [ -n "$run_full" ] || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Liveness class of a recorded ledger status word.
# The coarse `no-mistakes runs` ledger emits database status words; an
# `axi status` run object reports its terminal result through its own outcome
# field as well, which fm_nm_run_is_active below checks directly.
fm_nm_run_status_class() {  # <status_word>
  case "${1:-}" in
    completed|failed|cancelled) printf 'terminal' ;;
    pending|running)            printf 'live' ;;
    *)                          printf 'unknown' ;;
  esac
}

# Select from a complete `no-mistakes axi` overview with the existing awk
# toolchain. A capped overview requires an optional Python 3 sqlite3 reader
# for a read-only same-branch query of the state database fm_nm_state_db
# locates for the worktree.
# Repo identity is the overview's own top-level `repo:` line, which every axi
# release emits: it is the `working_path` the CLI itself resolved for the
# queried worktree. That is NOT the task worktree path in general - a linked
# git worktree resolves to its main clone's registered path (observed
# 2026-09-22 on v1.79.0: every task copy of a firstmate home reports
# `repo: <home clone>`, and looking the repo up by the task worktree path
# matched no row, so every capped read reported the inventory unreadable).
# The recorded spelling is matched exactly, so an overview without exactly one
# absolute `repo:` line, or with one the inventory does not record, reads as
# unreadable rather than guessed among candidates.
# The reader subprocess is bounded by $4 seconds (default 10), so a contended
# database can never outlast the caller's per-read budget.
# If that reader or inventory is unavailable, report unknown with available
# candidate ids rather than treating the displayed window as complete.
# Structural completeness applies to the whole table; semantic validation
# applies only to the requested branch, after complete identity lookup when
# capped. Branch names are matched exactly without a character whitelist.
# Its rows are ordered by creation time descending (not last update), then id.
# The newest same-branch row is the candidate regardless of outcome: an older
# live run must not hide a newer failure. If the newest is live and another
# same-branch live run exists, neither has exclusive authority: report all
# candidate ids as unknown. A newer live row can replace cancelled history,
# but the caller must fetch its full status BY ID and prove branch/head,
# executing status, or active pipeline custody before using its steps.
# Never reuse another run's gate detail.
# This is a read-only selection, not teardown authorization.
#
# Prints selected|id|status|candidate-ids, unknown|reason, absent (no row
# for this branch), or unavailable (CLI has no overview table). Malformed or
# structurally truncated tables report unknown, retaining every readable
# same-branch candidate id.
fm_nm_select_run() {  # <branch> <axi-overview> <worktree> [timeout_secs]
  local selection inventory available_ids timeout_secs=${4:-10}
  case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=10 ;; esac
  selection=$(printf '%s\n' "$2" | awk -v branch="$1" '
    function scalar(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/) s = substr(s, 2, length(s)-2)
      return s
    }
    function row_fields(s, f, i, ch, n, quoted, escaped) {
      for (i in f) delete f[i]
      n = 1; f[n] = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (escaped) { f[n] = f[n] ch; escaped = 0 }
        else if (quoted && ch == "\\") escaped = 1
        else if (ch == "\"") quoted = !quoted
        else if (!quoted && ch == ",") { n++; f[n] = "" }
        else f[n] = f[n] ch
      }
      if (quoted || escaped) return 0
      for (i = 1; i <= n; i++) {
        sub(/^[ \t]+/, "", f[i]); sub(/[ \t]+$/, "", f[i])
      }
      return n
    }
    /^count: / {
      if (counts++) bad = 1
      count = scalar(substr($0, 8))
      if (count !~ /^[0-9]+ of [0-9]+ total$/) bad = 1
      split(count, c, " "); shown = c[1]; total = c[3]
    }
    /^runs\[[0-9]+\]\{id,branch,status,head,pr\}:$/ {
      if (found++) bad = 1
      expected = $0; sub(/^runs\[/, "", expected); sub(/\].*$/, "", expected)
      inrows = 1; next
    }
    /^runs\[/ { bad = 1; found = 1 }
    inrows && /^[ \t]+/ {
      seen++
      n = row_fields($0, f)
      if (n != 5) bad = 1
      id = f[1]; br = f[2]; st = f[3]; head = f[4]
      if (br != branch) next
      if (id ~ /^[A-Za-z0-9_-]+$/) {
        if (known[id]++) invalid_run = 1
        else ids = ids (ids == "" ? "" : ", ") id
      }
      if (n != 5) next
      if (id !~ /^[A-Za-z0-9_-]+$/ ||
          st !~ /^[a-z_-]+$/ || head !~ /^[a-fA-F0-9]+$/ || length(head) < 7 || length(head) > 40) {
        invalid_run = 1; next
      }
      if (first == "") { first = id; first_status = st }
      if (st == "running" || st == "pending") live++
      if (st !~ /^(pending|running|completed|failed|cancelled)$/) unknown_status = 1
      next
    }
    inrows { inrows = 0 }
    END {
      if (!found) print "unavailable"
      else if (bad || counts != 1 || (seen+0) != (expected+0) || (seen+0) != (shown+0) || (total+0) < (shown+0))
        print "unknown|unreadable runs table; run ids: " ids
      else if ((shown+0) < (total+0)) print "incomplete|" ids
      else if (invalid_run) print "unknown|unreadable runs table; run ids: " ids
      else if (unknown_status) print "unknown|unrecognized run status; run ids: " ids
      else if (first == "") print "absent"
      else if ((first_status == "running" || first_status == "pending") && live > 1)
        print "unknown|competing live runs; run ids: " ids
      else print "selected|" first "|" first_status "|" ids
    }
  ')
  case "$selection" in
    incomplete\|*) available_ids=${selection#*|} ;;
    *) printf '%s\n' "$selection"; return ;;
  esac
  if ! inventory=$(fm_nm_bounded "$3" "$timeout_secs" python3 - "$1" "$2" "$available_ids" "$(fm_nm_state_db "$3")" 2>/dev/null <<'PY'
import json
import os
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

branch, overview, available_ids, database = sys.argv[1:]
ids = available_ids.split(", ") if available_ids else []
try:
    repos = [line[6:].strip() for line in overview.splitlines() if line.startswith("repo: ")]
    if len(repos) != 1:
        raise ValueError
    repo_path = json.loads(repos[0]) if repos[0].startswith('"') else repos[0]
    if not isinstance(repo_path, str) or not os.path.isabs(repo_path):
        raise ValueError
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
        db.execute("BEGIN")
        repo = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo_path,)).fetchall()
        if len(repo) != 1:
            raise ValueError
        rows = db.execute(
            "SELECT id, branch, status, head_sha FROM runs WHERE repo_id = ? AND branch = ? "
            "ORDER BY created_at DESC, id DESC", (repo[0][0], branch)
        ).fetchall()
    displayed_ids = set(ids)
    for row in rows:
        if isinstance(row[0], str) and re.fullmatch(r"[A-Za-z0-9_-]+", row[0]) and row[0] not in ids:
            ids.append(row[0])
    if not displayed_ids.issubset(row[0] for row in rows):
        raise ValueError
    for row in rows:
        if (not all(isinstance(value, str) for value in row)
                or not re.fullmatch(r"[A-Za-z0-9_-]+", row[0]) or row[1] != branch
                or not re.fullmatch(r"[a-z_-]+", row[2]) or not re.fullmatch(r"[a-fA-F0-9]{7,40}", row[3])):
            raise ValueError
    print("count: %d of %d total" % (len(rows), len(rows)))
    print("runs[%d]{id,branch,status,head,pr}:" % len(rows))
    for row in rows:
        print("  " + ",".join(json.dumps(value, ensure_ascii=False) for value in row) + ',""')
except (ValueError, OSError, sqlite3.Error):
    print("unknown|complete same-branch run inventory unreadable; run ids: " + ", ".join(ids))
PY
  ); then
    printf 'unknown|complete same-branch run inventory reader unavailable; run ids: %s\n' "$available_ids"
    return
  fi
  case "$inventory" in
    unknown\|*) selection=$inventory ;;
    *) selection=$(fm_nm_select_run "$1" "$inventory" "$3" "$timeout_secs") ;;
  esac
  case "$selection" in
    selected\|*|unknown\|*|absent) printf '%s\n' "$selection" ;;
    *) printf 'unknown|complete same-branch run inventory unreadable; run ids: %s\n' "$available_ids" ;;
  esac
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# One scalar from a nested block of the top-level `branch_sync:` block in
# captured `axi status` TOON $1: `<sub>.<key>` such as `next_action.code` or
# `pipeline.current_head`. Empty when either block or the key is absent.
# Indentation bounds each block, so a same-named key in a sibling sub-block
# (every sub-block of branch_sync carries its own `head`-like keys) is never
# read in its place.
fm_nm_branch_sync_nested() {  # <toon-output> <sub-block> <key>
  local s
  s=$(printf '%s\n' "$1" | awk -v sub_block="$2" -v key="$3" '
    function indent(line) { match(line, /[^ ]/); return RSTART - 1 }
    /^[^[:space:]]/ { in_sync = ($0 ~ /^branch_sync:[[:space:]]*$/); in_sub = 0; next }
    !in_sync { next }
    {
      ind = indent($0)
      if (in_sub && ind <= sub_ind) in_sub = 0
      if (!in_sub && $0 ~ ("^[[:space:]]+" sub_block ":[[:space:]]*$")) { in_sub = 1; sub_ind = ind; next }
      if (in_sub && ind > sub_ind && $0 ~ ("^[[:space:]]+" key ":")) {
        sub(("^[[:space:]]+" key ":[[:space:]]*"), "")
        print
        exit
      }
    }')
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  fm_nm_qfield_to status "$1" status
  fm_nm_qfield_to outcome "$1" outcome
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The custody exemption to the head rule above: while the pipeline OWNS the
# branch (branch_sync.state=pipeline_owned), the daemon's own branch
# attribution IS the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# The gate evidence in an `axi status` TOON, as ONE set of patterns. Both
# readers must agree exactly: fm_nm_run_is_parked below decides whether a run
# keeps the strict head rule, and fm-crew-state.sh's nm_gate_step_row /
# nm_gate_status / nm_has_gate render the `parked at <gate>` detail from the
# same evidence. If a new parked marker is added to one reader only, an
# unverified run's gate detail reaches the crew report.
FM_NM_GATE_LINE_RE='^[[:space:]]*gate:[[:space:]]*'
FM_NM_AWAITING_AGENT_RE='^[[:space:]]*awaiting_agent:'
FM_NM_GATE_SCALAR_RE='^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$'
FM_NM_GATE_ROW_RE='^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,'

# 0 if the run in captured `axi status` TOON $1 carries any of those PARKED
# markers. The top-level `status:` word alone does NOT decide this: the CLI
# leaves it at `running` while a run waits at a gate, so the word and the gate
# markers routinely disagree.
fm_nm_run_is_parked() {  # <toon-output>
  # shellcheck disable=SC2034 # Only the read's status answers; the line is unused.
  local line
  fm_nm_first_line_to line "$1" \
    "$FM_NM_GATE_LINE_RE|$FM_NM_AWAITING_AGENT_RE|$FM_NM_GATE_SCALAR_RE|$FM_NM_GATE_ROW_RE"
}

# 0 if the run in captured `axi status` TOON $1 is EXECUTING: in flight and
# actively working (pending, running, fixing, or ci), not parked at a gate.
# Read-only current-state reporting (fm-crew-state.sh) treats an executing run
# on the task's own branch as authoritative REGARDLESS of head: the pipeline
# rebases the branch and commits fix rounds in its own checkout, so a live run's
# head routinely differs from the task worktree's local head, and falling back
# to an older run that matches the local head reads a working crew as failed.
# A run parked at a gate keeps the strict head rule, and no destructive caller
# uses this predicate: teardown stays on fm_nm_head_matches_worktree and the
# ledger rule below.
# This predicate reads the RECORD only; it cannot tell a live run from one whose
# daemon died still saying `running`. The head-free route through it is the
# caller's to license, and fm-crew-state.sh pairs it with an explicit
# daemon-down probe for exactly that reason.
# All four accepted words reach here on BOTH surfaces. The overview table
# fm_nm_select_run validates carries a narrower column
# (pending|running|completed|failed|cancelled, its unknown_status check), but that column is not
# what this predicate reads: the selected-run route re-reads the run by id and
# passes that DETAIL object, whose own vocabulary check admits `fixing` and `ci`
# as live, and the legacy bare-status route passes the same detail shape.
# Dropping them would report a fix round or a ci wait as idle, which is the
# misreport this predicate exists to prevent.
fm_nm_run_is_executing() {  # <toon-output>
  local status
  fm_nm_run_is_active "$1" || return 1
  fm_nm_run_is_parked "$1" && return 1
  fm_nm_qfield_to status "$1" status
  case "$status" in
    pending|running|fixing|ci) return 0 ;;
  esac
  return 1
}

# The one spelling of the fm-crew-state.sh detail component that names what a
# working run waits on: "waits on: <what>", from fm_nm_run_wait below. The place
# count's fm_project_capacity_is_working (bin/fm-project-capacity-lib.sh) is
# its consumer.
# shellcheck disable=SC2034 # Read by fm-crew-state.sh and the place count, not this lib.
FM_NM_RUN_WAITS_ON='waits on: '

# Print what the run in captured `axi status` TOON $1 waits on when every
# active step is proven to wait on someone else, and nothing otherwise:
#   test suite lock - the Test step, on its first pass or a fix round (which
#     reads fixing), has not started its work: the daemon holds it on the
#     shared test suite lock, so no agent runs and the step's newest activity
#     is the daemon's own waiting line.
#   CI - the ci step watches the PR: it reads running with no agent. A CI
#     repair runs only inside a fix round, whose step reads fixing.
# Columns are found by name in the active_steps header, whose layout differs
# between no-mistakes versions. No table, a header without the step, status or
# agent_pid column, any other active step, or a row that does not hold exactly
# the declared fields or ends inside an open quote or escape is not proof, so
# the run still reads as work: a read cut short can end partway through a row,
# and a missing agent_pid is not an empty one.
fm_nm_run_wait() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    function cells(row, out,    n, i, c, cell, quoted, escaped) {
      n = 0; cell = ""; quoted = 0; escaped = 0
      for (i = 1; i <= length(row); i++) {
        c = substr(row, i, 1)
        if (escaped) { cell = cell c; escaped = 0 }
        else if (quoted && c == "\\") escaped = 1
        else if (c == "\"") quoted = !quoted
        else if (!quoted && c == ",") { out[++n] = cell; cell = "" }
        else cell = cell c
      }
      out[++n] = cell
      return (quoted || escaped) ? -1 : n
    }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*active_steps\[[0-9]+\]\{/ {
      indent = index($0, "active_steps"); inblock = 1
      header = $0; sub(/^[^{]*\{/, "", header); sub(/\}.*$/, "", header)
      split("", col); ncols = split(header, names, ",")
      for (i = 1; i <= ncols; i++) col[names[i]] = i
      usable = ("step" in col) && ("status" in col) && ("agent_pid" in col)
      next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= indent) { inblock = 0; next }
      rows++
      if (!usable) { working = 1; next }
      split("", f)
      if (cells(substr($0, RSTART), f) != ncols) { working = 1; next }
      step = trim(f[col["step"]]); status = trim(f[col["status"]])
      activity = ("last_activity" in col) ? f[col["last_activity"]] : ""
      this = ""
      if (trim(f[col["agent_pid"]]) == "") {
        if (step == "test" && (status == "running" || status == "fixing") &&
          (index(activity, "log: waiting for test suite lock ") ||
          index(activity, "log: still waiting for test suite lock ")))
          this = "test suite lock"
        else if (step == "ci" && status == "running")
          this = "CI"
      }
      if (this == "") working = 1
      else if (wait == "") wait = this
    }
    END { if (rows > 0 && !working) print wait }
  '
}

# ONE owner for attribution from the pipeline's own runs ledger, replacing a
# per-row scan-and-skip. The ledger is the real top-level `no-mistakes runs
# --limit N` listing (plain text, no run id, no quoting, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]"; the `axi` surface has no
# runs-listing subcommand - verified against the installed CLI). Prints the
# status word of the branch's CURRENT run row, or nothing when the ledger
# cannot prove attribution. When optional expected head $4 is supplied, its
# abbreviated commit identity must match the newest row. The branch's NEWEST
# row alone decides; older rows are history and never answer for the present:
#   - newest row's head resolves and matches the worktree (fm_nm_head_matches_worktree):
#     its status word
#   - newest row's head resolves but does not match: nothing (a newer run that
#     is not this worktree's makes every older row stale history)
#   - newest row's head does not resolve in this copy (the pipeline committed
#     its fix round in its own checkout and the task copy never fetched it):
#     recognized ONLY as a provable pipeline-owned continuation of the
#     submitted head, which requires ALL of: the row is ACTIVE (status
#     running), and the immediately older row for the SAME branch resolves to
#     EXACTLY the worktree HEAD. The pipeline's own ledger then proves an
#     unbroken run sequence from a run that ended at the submitted head to an
#     active run on the same branch - the anchored active row's status word is
#     printed. Anything else (no anchor row, an anchor that is merely an
#     ancestor, a terminal unresolvable row) prints nothing, so branch-name
#     coincidence, arbitrary remote state, and other tasks' runs never match.
# An older live row never displaces a newer terminal result.
# There is no branch-name-only acceptance here: a live row whose head this copy
# cannot tie to the worktree is not this worktree's run just because the branch
# name matches. The one live bind is the EXECUTING record on the `axi status`
# route (fm_nm_run_is_executing above), which the caller pairs with its own
# liveness evidence.
# Read-only: git reads resolve objects in place; custody never changes.
fm_nm_runs_status_for_worktree() {  # <worktree> <branch> <runs-list-output> [expected-head]
  local wt=$1 branch=$2 list=$3 expected_head=${4:-}
  local local_full row_full row st br sha day clock pr extra year_num month_num day_num max_day pending_st=''
  local decided=''
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    fm_nm_trim_to row "$row"
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || break
    [ -z "$extra" ] || break
    case "$st" in *[!a-z_-]*|'') break ;; esac
    case "$br" in *[!A-Za-z0-9._/-]*|'') break ;; esac
    case "$sha" in *[!A-Fa-f0-9]*|'') break ;; esac
    case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) break ;; esac
    case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) break ;; esac
    case "$pr" in ''|https://*) ;; *) break ;; esac
    [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || break
    year_num=$((10#${day%%-*}))
    month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
    day_num=$((10#${day##*-}))
    [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || break
    case "$month_num" in
      1|3|5|7|8|10|12) max_day=31 ;;
      4|6|9|11) max_day=30 ;;
      2)
        if (( year_num % 400 == 0 || (year_num % 4 == 0 && year_num % 100 != 0) )); then
          max_day=29
        else
          max_day=28
        fi
        ;;
    esac
    [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || break
    [ "$br" = "$branch" ] || continue
    if [ -n "$pending_st" ]; then
      # This is the row immediately older than the active unresolvable row:
      # the only admissible anchor, and only exact head equality proves the
      # worktree still sits at the submitted head.
      if [ "$(fm_nm_resolve_commit "$wt" "$sha")" = "$local_full" ]; then
        decided=$pending_st
      fi
      break
    fi
    if [ -n "$expected_head" ]; then
      case "$expected_head" in *[!A-Fa-f0-9]*|'') break ;; esac
      [ "${#expected_head}" -ge 7 ] && [ "${#expected_head}" -le 40 ] || break
      case "$expected_head" in
        "$sha"*) ;;
        *) case "$sha" in "$expected_head"*) ;; *) break ;; esac ;;
      esac
    fi
    row_full=$(fm_nm_resolve_commit "$wt" "$sha")
    if [ -n "$row_full" ]; then
      if fm_nm_head_matches_worktree "$wt" "$sha"; then
        decided=$st
      fi
      break
    fi
    [ "$st" = running ] || break
    pending_st=$st
  done <<< "$list"
  printf '%s' "$decided"
  return 0
}
