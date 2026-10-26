#!/usr/bin/env bash
# fm-dispatch-ready.sh - say, at the moment a place frees, how many places a
# project really has free and which ready backlog rows are waiting for one.
#
# Usage: fm-dispatch-ready.sh [--if-capped] <project-dir>
#        fm-dispatch-ready.sh --freed-by <task-id>
#
# Prints one `Dispatch:` line about <project-dir>, and a second one when ready
# rows name other projects. Each event that frees a place prints it, so the
# wake that frees a place also says what to start in it: bin/fm-teardown.sh
# after a cleanup, bin/fm-pr-check.sh after a recorded PR handoff, and
# bin/fm-supervision-host.sh (through --freed-by below) when a worker's own
# status line takes it off working. Main may run it at any time for any
# project.
#
# Why it exists: main once judged capacity by counting the backlog's in-flight
# rows. That count includes merged rows nobody closed and workers that already
# recorded their PR, so it read "6 open against a limit of 5" while
# bin/fm-spawn.sh's own count had every place free, and ready work waited hours
# beside free places. bin/fm-spawn.sh is the only admitter: it counts under the
# project lock and defers with exit 75 when the project is full. This line is
# that same count (bin/fm-project-capacity-lib.sh, read without the lock, so it
# is a snapshot) and never a reason to skip a spawn the line says to try.
#
# Ready rows are `bin/fm-tasks-axi.sh ready` (unblocked, unheld, queued), in
# backlog order, less `captain` rows, which are decisions held for a person
# rather than work a spawn takes. Free starts are the smaller of the free places
# and the free trees in the project's worktree pool (fm_project_capacity_pool),
# the two limits bin/fm-spawn.sh admits by. A row names this project when its repo is the project's
# registered name (its directory's basename). A row whose repo is `firstmate`
# names it only when the project shares this code root's lineage
# (fm_role_self_repo), whatever the project's directory is called.
#
# Cost: the count is fm-spawn's own admission count and costs what one
# admission costs, nearly all of it one bounded crew-state read per record that
# still names the project. It is taken only when ready rows name the project, so
# a release with nothing to start costs only the declaration and backlog reads.
#
# --if-capped prints nothing for a project that declares no place limit, for a
# caller whose event frees a place only under a declared limit.
#
# Always exits 0 after a valid request, since callers print it beside work that
# already happened; a count or backlog read that fails is named in the line.
# Exit 2 for a bad request. Reads only; changes nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# Rows a list shows before it says how many more there are.
DISPATCH_LIST_MAX=8
# How long the backlog read may take; the line must not hold up its caller.
DISPATCH_READY_TIMEOUT=${FM_DISPATCH_READY_TIMEOUT:-30}
case "$DISPATCH_READY_TIMEOUT" in ''|*[!0-9]*|0) DISPATCH_READY_TIMEOUT=30 ;; esac

# --freed-by <task-id>: the place a worker frees when its own status line takes
# it off working, with no cleanup or PR handoff. bin/fm-supervision-host.sh
# asks this for each signal wake the supervision branch handled, because that
# branch cannot start work. Prints the project's first Dispatch line only when
# the task's record is a worker (not a secondmate) with no recorded pr=, its
# crew state no longer reads working (fm_project_capacity_is_working, the read
# bin/fm-spawn.sh's count uses), and that line says to start something;
# otherwise prints nothing. Exits 0 either way.
if [ "${1:-}" = --freed-by ]; then
  [ "$#" -eq 2 ] || { echo "usage: fm-dispatch-ready.sh --freed-by <task-id>" >&2; exit 2; }
  case "$2" in '' | *[!A-Za-z0-9._-]*) echo "error: invalid task id: $2" >&2; exit 2 ;; esac
  meta="$STATE/$2.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || exit 0
  ! grep -q '^pr=' "$meta" || exit 0
  ! grep -qx 'kind=secondmate' "$meta" || exit 0
  freed_project=$(grep '^project=' "$meta" | tail -n 1 | cut -d= -f2-)
  [ -n "$freed_project" ] && [ -d "$freed_project" ] || exit 0
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  { . "$SCRIPT_DIR/fm-wake-lib.sh" && . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" &&
    . "$SCRIPT_DIR/fm-backend.sh" && . "$SCRIPT_DIR/fm-project-capacity-lib.sh"; } >/dev/null 2>&1 || exit 0
  fm_project_capacity_is_working "$STATE" "$2"
  [ "$?" -eq 1 ] || exit 0
  freed_line=$("$0" "$freed_project" 2>/dev/null | head -n 1)
  case "$freed_line" in *"start it now"*) printf '%s\n' "$freed_line" ;; esac
  exit 0
fi

IF_CAPPED=0
if [ "${1:-}" = --if-capped ]; then
  IF_CAPPED=1
  shift
fi
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: fm-dispatch-ready.sh [--if-capped] <project-dir> | --freed-by <task-id>" >&2
  exit 2
fi
PROJ=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || {
  echo "error: project directory cannot be resolved: $1" >&2
  exit 2
}
NAME=$(basename "$PROJ")

# <list> <max>: the first <max> comma-separated items, then "+N more".
short_list() {
  local list=$1 max=$2 out='' n=0 item rest
  rest=$list
  while [ -n "$rest" ]; do
    item=${rest%%, *}
    if [ "$item" = "$rest" ]; then rest=''; else rest=${rest#*, }; fi
    n=$((n + 1))
    if [ "$n" -le "$max" ]; then out="${out:+$out, }$item"; fi
  done
  [ "$n" -le "$max" ] || out="$out, +$((n - max)) more"
  printf '%s' "$out"
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

# --- the declaration -----------------------------------------------------------
CAP=
FREE=
HOLDERS=
COUNT_ERROR=
if ! { . "$SCRIPT_DIR/fm-wake-lib.sh" && . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" &&
  . "$SCRIPT_DIR/fm-backend.sh" && . "$SCRIPT_DIR/fm-project-capacity-lib.sh"; } >/dev/null 2>&1; then
  COUNT_ERROR="the capacity library did not load"
elif ! CAP_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG" 2>/dev/null); then
  COUNT_ERROR="the root home that declares project capacity cannot be resolved"
elif ! fm_project_capacity_lookup "$CAP_CONFIG" "$NAME"; then
  COUNT_ERROR=$FM_PROJECT_CAPACITY_ERROR
else
  CAP=$FM_PROJECT_CAPACITY
fi
[ "$IF_CAPPED" = 0 ] || [ -n "$CAP" ] || [ -n "$COUNT_ERROR" ] || exit 0

# --- ready rows ---------------------------------------------------------------
MINE=
OTHERS=
OTHER_COUNT=0
READY_ERROR=
SELF_REPO=unknown
if READY_OUT=$(fm_run_timed "$DISPATCH_READY_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>/dev/null </dev/null); then
  while IFS= read -r line; do
    # "  <id>,queued,<kind>,<repo>,<title>"; ids and repos carry no commas.
    case "$line" in '  '*,queued,*) ;; *) continue ;; esac
    line=${line#  }
    id=${line%%,*}
    rest=${line#*,queued,}
    kind=${rest%%,*}
    # A captain row is a decision held for a person, not work a spawn takes.
    [ "$kind" != captain ] || continue
    rest=${rest#*,}
    repo=${rest%%,*}
    match=0
    # A `firstmate` row is decided by lineage alone, never by a directory that
    # happens to be named firstmate: an unrelated repository can be.
    if [ "$repo" = firstmate ]; then
      if [ "$SELF_REPO" = unknown ]; then
        if fm_role_self_repo "$PROJ" "$FM_ROOT"; then SELF_REPO=yes; else SELF_REPO=no; fi
      fi
      [ "$SELF_REPO" = no ] || match=1
    elif [ "$repo" = "$NAME" ]; then
      match=1
    fi
    if [ "$match" = 1 ]; then
      MINE="${MINE:+$MINE, }$id"
    else
      OTHERS="${OTHERS:+$OTHERS, }$id ($repo)"
      OTHER_COUNT=$((OTHER_COUNT + 1))
    fi
  done <<EOF
$READY_OUT
EOF
else
  READY_ERROR="bin/fm-tasks-axi.sh ready failed or ran past ${DISPATCH_READY_TIMEOUT}s"
fi

# --- places, by bin/fm-spawn.sh's own rule ----------------------------------
# The count is fm-spawn's own admission count, the same function over the same
# records, so it costs what one spawn's admission costs: almost all of it is
# one bounded crew-state read per record still naming the project. It runs
# only when ready rows name this project (or the backlog could not be read),
# because a place with nothing to start needs no count.
if [ -z "$COUNT_ERROR" ] && [ -n "$CAP" ] && [ "$CAP" != 0 ] && { [ -n "$MINE" ] || [ -n "$READY_ERROR" ]; }; then
  if ! LOCK=$(fm_treehouse_project_lock_path "$PROJ" 2>/dev/null); then
    COUNT_ERROR="no project lock path for $PROJ"
  elif ! fm_project_capacity_occupants "$LOCK" "$PROJ" "$STATE" ''; then
    COUNT_ERROR=$FM_PROJECT_CAPACITY_ERROR
  else
    FREE=$((CAP - FM_PROJECT_CAPACITY_OCCUPANTS))
    [ "$FREE" -ge 0 ] || FREE=0
    HOLDERS=$FM_PROJECT_CAPACITY_OCCUPANT_IDS
  fi
fi

# --- pool trees, the second limit bin/fm-spawn.sh admits by -------------------
POOL_KNOWN=0
if [ -n "$MINE" ] && [ -z "$READY_ERROR" ] && [ "$CAP" != 0 ]; then
  fm_project_capacity_pool "$PROJ"
  POOL_KNOWN=$FM_PROJECT_CAPACITY_POOL_KNOWN
fi

# --- the line -------------------------------------------------------------------
START="Write each brief and start it now with bin/fm-spawn.sh, in that order, until a spawn defers with exit 75 (its row stays queued); the spawn alone decides capacity, never a count of backlog rows."
if [ -n "$COUNT_ERROR" ]; then
  places="$NAME's places could not be counted ($COUNT_ERROR); bin/fm-spawn.sh counts them itself under the project lock"
elif [ -z "$CAP" ]; then
  places="$NAME declares no place limit"
elif [ "$CAP" = 0 ]; then
  places="$NAME declares 0 places, so nothing starts for it"
elif [ -z "$FREE" ]; then
  places="$NAME declares $CAP places"
else
  places="$NAME has $FREE of $CAP places free by bin/fm-spawn.sh's own count"
  [ -z "$HOLDERS" ] || places="$places (holding: $(short_list "$HOLDERS" 6))"
fi
if [ "$POOL_KNOWN" = 1 ]; then
  places="$places, and $FM_PROJECT_CAPACITY_POOL_FREE of $FM_PROJECT_CAPACITY_POOL_MAX worktree pool trees free"
  [ "$FM_PROJECT_CAPACITY_POOL_FREE" -gt 0 ] || places="$places (held: $(short_list "$FM_PROJECT_CAPACITY_POOL_HELD" 6))"
fi

if [ -n "$READY_ERROR" ]; then
  printf 'Dispatch: %s. Its ready rows could not be read (%s): run bin/fm-tasks-axi.sh ready and start the rows for %s with bin/fm-spawn.sh until one defers with exit 75.\n' \
    "$places" "$READY_ERROR" "$NAME"
  exit 0
fi
if [ -z "$MINE" ]; then
  printf 'Dispatch: %s; no ready backlog row names it, so nothing starts and its places were not counted.\n' "$places"
elif [ "$CAP" = 0 ]; then
  printf 'Dispatch: %s. Ready for it, held back by that declaration: %s.\n' "$places" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")"
elif [ "$POOL_KNOWN" = 1 ] && [ "$FM_PROJECT_CAPACITY_POOL_FREE" -le 0 ]; then
  # bin/fm-spawn.sh defers with 75 on a full pool whatever the places say.
  printf 'Dispatch: %s. Ready for it, in backlog order: %s. Nothing starts until a pool tree is returned; the next cleanup in %s prints this line again.\n' \
    "$places" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")" "$NAME"
elif [ -z "$COUNT_ERROR" ] && [ -n "$CAP" ] && [ "$FREE" -le 0 ]; then
  # At the declared count bin/fm-spawn.sh can still admit one extra start
  # through config/project-capacity-headroom, once per window. Read the same
  # verdict it starts from (fm_project_capacity_overshare_prepare, read-only)
  # so the line never withholds a start the spawn would allow.
  fm_project_capacity_overshare_prepare "$CAP_CONFIG" "$LOCK" >/dev/null 2>&1 || FM_PROJECT_CAPACITY_OVERSHARE=no
  case "${FM_PROJECT_CAPACITY_OVERSHARE:-no}" in
    open)
      printf 'Dispatch: %s, but its headroom reading may admit one start past that count. Ready for it, in backlog order: %s. Write the first brief and start it now with bin/fm-spawn.sh, which runs the reading and decides; a deferral with exit 75 leaves the row queued.\n' \
        "$places" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")"
      ;;
    spent)
      left=
      if IFS= read -r spent_at < "$FM_PROJECT_CAPACITY_OVERSHARE_DIR/$FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY" 2>/dev/null &&
        case "$spent_at" in '' | *[!0-9]* | 0?*) false ;; *) true ;; esac; then
        left=$((spent_at + FM_PROJECT_CAPACITY_OVERSHARE_WINDOW - $(date +%s)))
        [ "$left" -gt 0 ] || left=0
      fi
      printf 'Dispatch: %s, and its one extra start for this window is taken%s. Ready for it, in backlog order: %s. Nothing starts until a place frees or that window passes; the next cleanup, recorded PR or freed place in %s prints this line again.\n' \
        "$places" "${left:+ (the window passes in about ${left}s)}" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")" "$NAME"
      ;;
    *)
      printf 'Dispatch: %s. Ready for it, in backlog order: %s. Nothing starts until a place frees; the next cleanup, recorded PR or freed place in %s prints this line again.\n' \
        "$places" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")" "$NAME"
      ;;
  esac
else
  printf 'Dispatch: %s. Ready for it, in backlog order: %s. %s\n' "$places" "$(short_list "$MINE" "$DISPATCH_LIST_MAX")" "$START"
fi
if [ "$OTHER_COUNT" -gt 0 ]; then
  printf 'Dispatch: %s more ready row(s) name other projects: %s. For each project, run bin/fm-dispatch-ready.sh <project-dir> for its places and start its rows the same way.\n' \
    "$OTHER_COUNT" "$(short_list "$OTHERS" "$DISPATCH_LIST_MAX")"
fi
exit 0
