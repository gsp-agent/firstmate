#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by bin/fm-spawn.sh after sourcing.
# fm-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Firstmate cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/fm-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, of the optional headroom command, and of the admission verdict.
# docs/configuration.md "Project capacity" is the operator reference, and
# bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is 0 or a positive integer of at most six
# digits. 0 admits no worker. The headroom reading below does not raise it.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/fm-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Occupancy: a place is held by every task record, in any local Firstmate home on
# this machine (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh), that
#   - is not a secondmate, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (fm_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has no recorded PR handoff: the pr= line bin/fm-pr-check.sh records when a
#     worker's PR is ready, after which the worker waits on review or merge and
#     no longer uses local resources, and
#   - is working: bin/fm-crew-state.sh reads the task as working
#     (fm_project_capacity_is_working). A resident record read as parked,
#     paused, done, blocked, failed or unknown holds no place. A record whose
#     crew state cannot be read at all, including a read still running after
#     FM_PROJECT_CAPACITY_CREW_TIMEOUT seconds, holds a place as if working
#     and is listed as "<id> (state unreadable)", so an unreadable state
#     neither undercounts the holders nor fails the count.
# A place therefore frees when a PR-based ship records its ready PR, when the
# holder stops working, or when any task is cleaned up and its record removed.
# A local-only ship and a scout have no recorded handoff and hold their place
# while they work, until they stop or are cleaned up. A worker that is
# steered back into work after its PR handoff is not counted again.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Race safety: bin/fm-spawn.sh evaluates admission while holding the shared
# project lock and keeps holding it until the new task record is published, so
# two concurrent spawns for one project can never both publish from the same
# count. A headroom reading reserves no place; bin/fm-spawn.sh's header owns
# its unlocked reading, locked recount, and the per-home task-set hold around
# publication.
# A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included.
# Removing a record or adding pr= only lowers the count, so admission tolerates
# those concurrent decreases.
#
# Headroom command: config/project-capacity-headroom in that same config
# directory. The file is off when it is absent or has no non-whitespace line,
# and a spawn at the declared count is then deferred exactly as above.
# Otherwise the file holds one line. That line is the program and its
# arguments, split on whitespace, and it is not a shell command. A program
# path that contains whitespace cannot be named. A second non-empty line, a
# file that exists but cannot be read, a program that is not executable, a
# non-zero exit, an exit 0 whose first stdout line is empty, or a run that is
# still going after FM_PROJECT_CAPACITY_HEADROOM_TIMEOUT seconds is no room.
# The spawn is deferred and the window below is not consumed. Standard error
# from the program is discarded. When the extra start is admitted, the
# program's first stdout line, with a trailing carriage return removed and cut
# at 240 characters, is written to standard error as "headroom: <line>". A
# line from a reading that is not admitted is discarded.
# The program runs only when the project is already at its declared count and
# its extra-start window is open. Exit 0 with a non-empty first stdout line
# admits one spawn past that count.
# Before that spawn continues, the epoch second is written as the only line of
# <config-dir>/../state/project-capacity-overshare/<identity>. <identity> is the
# hash that names the project's shared project lock, which is keyed by its
# resolved origin, so the record names the same project the lock serializes.
# A second extra spawn for that project is deferred while that epoch is less
# than FM_PROJECT_CAPACITY_OVERSHARE_WINDOW seconds old. The window is 420
# seconds, about one starter pass. Clones of one origin share one record, and
# two origins cloned under one directory name keep separate records, even
# though that name's declared count applies to both. The window recheck and
# record publication run under the project lock, so two spawns cannot both
# take the extra start. An extra start whose record cannot be written is not
# admitted. Keep a launched start's record until its window passes: deleting
# it earlier would permit another extra start in that window.
# A spawn that fails before its worker launches removes that record again under
# the project lock, so that failed extra start leaves the window open. Once the
# launch is sent, the record stands whatever fails after it. A spawn that
# has already released the lock retakes it for up to
# FM_PROJECT_CAPACITY_RELEASE_WAIT seconds and otherwise leaves the record until
# the window passes. A record that holds a different epoch is left in place.
# Workers already running are never stopped. A project lock whose name does
# not carry that identity cannot be recorded, so it is not admitted past its
# count.
#
# Machine total: the optional config/machine-capacity in that same config
# directory declares how many workers this machine admits at once across
# every project, as one line holding 0 or a positive integer of at most six
# digits. The file is off when it is absent or holds no non-whitespace line,
# and dispatch then has no machine-wide ceiling. A line that is `#`, or that
# begins with `#` followed by whitespace, is a comment and does not count as
# the line. Any other shape - a second non-empty line, a value that is not
# such an integer, or a file that exists but is not a readable regular file -
# makes the declaration unreadable, and bin/fm-spawn.sh then refuses every
# fresh ship or scout spawn exactly as it does for an unreadable
# config/project-capacity. Occupancy is the walk above without the project
# match: every holder of any project's place, in any local home, holds one
# of the machine's places too (fm_project_capacity_occupants counts both in
# its one walk, and only reads crew state for records outside the admitted
# project when a total is declared). A fresh spawn is admitted only while
# both its project's count and the machine total have a free place; the
# total is the outer bound, so the headroom reading's one extra start past a
# project's count still needs a free machine place, and a declared total of
# 0 admits no worker and is not raised either. The total is counted under
# the same shared project lock, so spawns for one project cannot race it.
# Spawns for different projects hold different project locks. Within one
# home, a spawn rechecks the total at publication under that home's task-set
# lock, counting each record its home published after admission counted
# (bin/fm-spawn.sh's header owns that hold), so one home never overshoots.
# Two homes starting different projects in the same moment can each pass a
# count taken before the other's record exists: the total can be overshot by
# at most the spawns racing in that moment, and every later spawn counts the
# published records and defers.
#
# The pool-tree limit beside places is fm_project_capacity_pool below.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first. The headroom reading
# loads bin/fm-timeout-lib.sh when that reading runs. No side effects on source.

# How long one extra start remains that project's extra start. 7 * 60 seconds
# matches one starter pass of about 7 minutes.
FM_PROJECT_CAPACITY_OVERSHARE_WINDOW=420

# How long a spawn that already released the project lock waits to retake it
# and remove the record of an extra start that launched no worker.
FM_PROJECT_CAPACITY_RELEASE_WAIT=10

# A reading that has not exited by this many seconds is no room.
FM_PROJECT_CAPACITY_HEADROOM_TIMEOUT=30

# How long one crew-state reading for the occupancy count may run. The count
# runs under the shared project lock, so an unbounded reader would hold every
# spawn for that project hostage; a reading that cannot answer in this bound
# counts its record as working, so it holds a place.
FM_PROJECT_CAPACITY_CREW_TIMEOUT=${FM_PROJECT_CAPACITY_CREW_TIMEOUT:-10}

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  FM_PROJECT_CAPACITY_FILE="$1/project-capacity"
  FM_PROJECT_CAPACITY=
  FM_PROJECT_CAPACITY_ANY=
  FM_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$FM_PROJECT_CAPACITY_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      0) ;;
      '' | *[!0-9]* | 0*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_PROJECT_CAPACITY=$pcap
  done < "$FM_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_PROJECT_CAPACITY_ANY=1
  return 0
}

# Read the declared machine total (the header's "Machine total").
# Sets FM_PROJECT_CAPACITY_TOTAL_FILE to the declaration path and
# FM_PROJECT_CAPACITY_TOTAL to the total, or to empty when the file is
# absent or holds no non-whitespace line. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_total_lookup() {  # <config-dir>
  local line lineno=0 count=0 value=
  FM_PROJECT_CAPACITY_TOTAL_FILE="$1/machine-capacity"
  FM_PROJECT_CAPACITY_TOTAL=
  FM_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$FM_PROJECT_CAPACITY_TOTAL_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_TOTAL_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_TOTAL_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_TOTAL_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_TOTAL_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt 1 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_TOTAL_FILE line $lineno declares the machine total a second time"
      return 1
    fi
    value=$line
  done < "$FM_PROJECT_CAPACITY_TOTAL_FILE"
  [ "$count" -eq 0 ] && return 0
  case "$value" in
    0) ;;
    '' | *[!0-9]* | 0*)
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_TOTAL_FILE declares a machine total that is not a positive integer: $value"
      return 1
      ;;
  esac
  if [ "${#value}" -gt 6 ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_TOTAL_FILE declares a machine total longer than six digits"
    return 1
  fi
  FM_PROJECT_CAPACITY_TOTAL=$value
  return 0
}

# Read one task's local crew state for the occupancy count. Returns:
# 0 when bin/fm-crew-state.sh reads the task in <state-dir> as working;
# 1 when the reader answered and the state is anything else - parked,
# paused, done, blocked, failed, unknown - which holds no slot;
# 2 when the reader could not answer at all (missing, not executable,
# non-zero exit, or past FM_PROJECT_CAPACITY_CREW_TIMEOUT), which the
# caller counts as working rather than "not working": undercounting the
# holders would silently turn the cap into no cap. Local evidence only (no
# forge read). The read is bounded because the count runs under the shared
# project lock, the same bound bin/fm-inactive-reconcile.sh already puts
# on this identical invocation.
fm_project_capacity_is_working() {  # <state-dir> <id>
  local out crew_state=${FM_PROJECT_CAPACITY_CREW_STATE:-$(dirname "${BASH_SOURCE[0]}")/fm-crew-state.sh}
  _fm_project_capacity_require_timeout || return 2
  [ -x "$crew_state" ] || return 2
  out=$(fm_run_timed "$FM_PROJECT_CAPACITY_CREW_TIMEOUT" env \
    FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" FM_CREW_STATE_NO_FORGE=1 \
    "$crew_state" "$2" 2>/dev/null) || return 2
  case "$out" in
    "state: working"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Count the task records holding a place under the occupancy rules above.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is not counted.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home and each whose crew state
# could not be read marked "(state unreadable)". When
# FM_PROJECT_CAPACITY_TOTAL is set (fm_project_capacity_total_lookup), the
# same walk also sets FM_PROJECT_CAPACITY_TOTAL_OCCUPANTS and
# FM_PROJECT_CAPACITY_TOTAL_OCCUPANT_IDS over every project's holders; the
# per-record crew-state read then also runs for records the project match
# would have skipped. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i rc match
  local -a cache_dirs cache_locks
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
  FM_PROJECT_CAPACITY_TOTAL_OCCUPANTS=0
  FM_PROJECT_CAPACITY_TOTAL_OCCUPANT_IDS=
  FM_PROJECT_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_PROJECT_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_PROJECT_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] || continue
      match=0
      [ "$lock" != "$want" ] || match=1
      # Without a declared machine total, a record outside this project is
      # skipped before its crew-state read exactly as before.
      [ "$match" -eq 1 ] || [ -n "${FM_PROJECT_CAPACITY_TOTAL:-}" ] || continue
      id=$(basename "$meta" .meta)
      # An unreadable crew state must retain its slot: skipping it would
      # undercount, while failing the whole count would refuse other spawns.
      fm_project_capacity_is_working "$state" "$id"
      rc=$?
      [ "$rc" -ne 1 ] || continue
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      [ "$rc" -eq 0 ] || label="$label (state unreadable)"
      if [ "$match" -eq 1 ]; then
        FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
        FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
      fi
      if [ -n "${FM_PROJECT_CAPACITY_TOTAL:-}" ]; then
        FM_PROJECT_CAPACITY_TOTAL_OCCUPANTS=$((FM_PROJECT_CAPACITY_TOTAL_OCCUPANTS + 1))
        FM_PROJECT_CAPACITY_TOTAL_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_TOTAL_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_TOTAL_OCCUPANT_IDS, }$label"
      fi
    done
  done
  return 0
}

# fm_treehouse_exposed_claims <project-dir> [<status-json>]: print one
# <path>\t<name>\t<task> line per tree of the project's Treehouse pool that a
# Firstmate claim (.fm-slot-owner beside the tree) names a task for while
# Treehouse reads it `available` (nothing running in it, no lease): a task's
# copy whose worker ended and that is not yet torn down. `treehouse get` may
# hand such a tree out and reset its checkout before any claim screen sees it.
# Reads `treehouse status --json` (bounded by FM_PROJECT_CAPACITY_POOL_TIMEOUT)
# unless <status-json> is given. Returns 1 when the read failed although this
# Treehouse has `status --json` (or jq is missing), and 2 when the pool cannot
# be known at all: no treehouse, one older than `status --json`, or a read
# that succeeded but printed no slot list (docs/configuration.md: there
# `treehouse get` alone decides).
fm_treehouse_exposed_claims() {
  local project=$1 json=${2-} path name marker owner
  command -v jq >/dev/null 2>&1 || return 1
  if [ "$#" -lt 2 ]; then
    command -v treehouse >/dev/null 2>&1 || return 2
    _fm_project_capacity_require_timeout || return 1
    if ! json=$(CDPATH='' cd -- "$project" 2>/dev/null &&
      fm_run_timed "$FM_PROJECT_CAPACITY_POOL_TIMEOUT" treehouse status --json </dev/null 2>/dev/null); then
      # A Treehouse older than `status --json` rejects the flag itself.
      (CDPATH='' cd -- "$project" 2>/dev/null &&
        fm_run_timed "$FM_PROJECT_CAPACITY_POOL_TIMEOUT" treehouse status --json </dev/null 2>&1 >/dev/null) |
        grep -qi 'unknown flag' && return 2
      return 1
    fi
  fi
  printf '%s\n' "$json" | jq -e 'arrays' >/dev/null 2>&1 || return 2
  while IFS=$'\t' read -r path name; do
    [ -n "$path" ] || continue
    marker="$(dirname "$path")/.fm-slot-owner"
    { [ -e "$marker" ] || [ -L "$marker" ]; } || continue
    owner=$(sed -n 's/^task=//p' "$marker" 2>/dev/null | head -n 1)
    printf '%s\t%s\t%s\n' "$path" "$name" "$owner"
  done <<EOF
$(printf '%s\n' "$json" | jq -r '.[] | select(.status == "available") | [(.path // ""), .name] | @tsv' 2>/dev/null)
EOF
  return 0
}

# Pool trees: the second limit on a fresh worker. A Treehouse-backed spawn
# also needs a free tree in the project's worktree pool, and a pool whose trees
# are all held cannot start a worker however many places are free. The pool's
# size is the project's own treehouse.toml top-level `max_trees`, read with a
# real TOML parser (python3's tomllib) so it is the value Treehouse reads; a
# project without that key, a key inside a table, or a host without tomllib
# declares no size here, so the pool is not counted and `treehouse get` alone
# decides. Treehouse's state is read with
# `treehouse status --json` from the project directory, bounded by
# FM_PROJECT_CAPACITY_POOL_TIMEOUT seconds. A tree is free when Treehouse
# reports it `available` and no Firstmate claim (.fm-slot-owner beside the
# tree) names a task for it, and each tree the pool can still create below its
# size is free too. A claimed tree with nothing running in it reads
# `available` to Treehouse, but it is a task's copy (one whose worker ended and
# that is not yet torn down): a spawn takes it only when the allocator hands it
# out (bin/fm-spawn.sh), and `treehouse get` would reset it if asked for a tree,
# so it is held, and named in FM_PROJECT_CAPACITY_POOL_EXPOSED for
# bin/fm-spawn.sh to keep the allocator away from. `available` is otherwise
# Treehouse's status, not its reuse test, so the count can be high, never low:
# a spawn whose `treehouse get` then refuses the pool still defers
# (bin/fm-spawn.sh).
# Sets FM_PROJECT_CAPACITY_POOL_KNOWN to 1 with FM_PROJECT_CAPACITY_POOL_MAX,
# FM_PROJECT_CAPACITY_POOL_FREE, FM_PROJECT_CAPACITY_POOL_HELD (each held tree
# as <name> <status>[ by <lease holder>] or <name> claimed by <task>, nothing
# running, comma-separated) and FM_PROJECT_CAPACITY_POOL_EXPOSED (one
# fm_treehouse_exposed_claims row per claimed `available` tree), or KNOWN to 0
# when the project declares no size or the pool cannot be read; never fails.
FM_PROJECT_CAPACITY_POOL_TIMEOUT=${FM_PROJECT_CAPACITY_POOL_TIMEOUT:-20}
fm_project_capacity_pool() {  # <project-dir>
  local project=$1 toml max="" json counts total avail path name owner claimed=""
  FM_PROJECT_CAPACITY_POOL_KNOWN=0
  FM_PROJECT_CAPACITY_POOL_MAX=
  FM_PROJECT_CAPACITY_POOL_FREE=
  FM_PROJECT_CAPACITY_POOL_HELD=
  FM_PROJECT_CAPACITY_POOL_EXPOSED=
  toml="$project/treehouse.toml"
  [ -f "$toml" ] && [ -r "$toml" ] || return 0
  _fm_project_capacity_require_timeout || return 0
  # A real TOML parse, so every spelling Treehouse accepts reads the same here:
  # quoted keys, integer forms, comments, and the key only at the top level
  # (under a [table] it is that table's, and Treehouse keeps its default; chip,
  # PR 164 reviews 5656106077 and 5656246209). Without python3's tomllib, or
  # for a file it cannot parse, the pool is not counted.
  max=$(fm_run_timed "$FM_PROJECT_CAPACITY_POOL_TIMEOUT" python3 -I -c '
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        value = tomllib.load(f).get("max_trees")
except Exception:
    sys.exit(1)
if type(value) is int and value > 0:
    print(value)
' "$toml" </dev/null 2>/dev/null) || max=""
  case "$max" in '' | *[!0-9]*) return 0 ;; esac
  command -v jq >/dev/null 2>&1 && command -v treehouse >/dev/null 2>&1 || return 0
  _fm_project_capacity_require_timeout || return 0
  json=$(CDPATH='' cd -- "$project" 2>/dev/null &&
    fm_run_timed "$FM_PROJECT_CAPACITY_POOL_TIMEOUT" treehouse status --json </dev/null 2>/dev/null) || return 0
  counts=$(printf '%s\n' "$json" | jq -er 'arrays | "\(length) \(map(select(.status == "available")) | length)"' 2>/dev/null) ||
    return 0
  total=${counts%% *}
  avail=${counts#* }
  FM_PROJECT_CAPACITY_POOL_HELD=$(printf '%s\n' "$json" | jq -r '[.[] | select(.status != "available") |
    "\(.name) \(.status)" + (if (.lease_holder // "") != "" then " by \(.lease_holder)" else "" end)] | join(", ")' 2>/dev/null) ||
    FM_PROJECT_CAPACITY_POOL_HELD=
  # An `available` tree a task still claims is held, not free.
  while IFS=$'\t' read -r path name owner; do
    [ -n "$path" ] || continue
    avail=$((avail - 1))
    FM_PROJECT_CAPACITY_POOL_EXPOSED="$FM_PROJECT_CAPACITY_POOL_EXPOSED$path	$name	$owner
"
    claimed="$claimed${claimed:+, }$name claimed by ${owner:-a task}, nothing running"
  done <<EOF
$(fm_treehouse_exposed_claims "$project" "$json")
EOF
  [ -z "$claimed" ] ||
    FM_PROJECT_CAPACITY_POOL_HELD="$FM_PROJECT_CAPACITY_POOL_HELD${FM_PROJECT_CAPACITY_POOL_HELD:+, }$claimed"
  FM_PROJECT_CAPACITY_POOL_MAX=$max
  FM_PROJECT_CAPACITY_POOL_FREE=$avail
  [ "$total" -ge "$max" ] || FM_PROJECT_CAPACITY_POOL_FREE=$((avail + max - total))
  FM_PROJECT_CAPACITY_POOL_KNOWN=1
  return 0
}

# Load bin/fm-timeout-lib.sh when a crew-state or headroom read needs a bound.
_fm_project_capacity_require_timeout() {
  command -v fm_run_timed >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"
}

# Directory of per-project extra-start records for the home that owns <config-dir>.
# The waiting line for a project's next free tree (agent-config
# .agent-config-wnvf0). Without it a freed tree went to whichever deferred
# start retried first, so a P0 waiting since morning lost trees to P1 starts
# whose callers retried sooner. A start that bin/fm-spawn.sh defers on a full
# pool joins the line, and a start that finds a free tree goes ahead only
# while fewer live waiters are ahead of it than there are free trees. Ahead
# means a lower priority number (the backlog item's tasks-axi priority, 0-4),
# then, at the same priority, an earlier arrival: the line hands each task a
# sequence number when it first joins, under the project lock, so two starts
# that arrive within one second keep their order whatever their task ids. A
# start not yet in the line counts as arriving after every waiter, so a later
# arrival never passes an earlier one of the same priority. A start without a
# priority sorts after every declared one.
#
# One entry per task, <dir>/<home>/<id>, and the line's last sequence number
# in <dir>/.seq, where <dir> is project-tree-wait/<identity>
# beside the shared project lock and <identity> names that lock, so clones of
# one origin share a line exactly as they share a pool. <home> is a short hash
# of the Firstmate home's state directory (fm_tree_wait_home): a task id is
# unique only within its home, so a primary and a secondmate home can both wait
# with one id, each in its own place. Every function here
# runs while the caller holds that lock, except a waiter's own removal and
# fm_tree_wait_wake, which a returner sends after releasing the lock so the
# woken start can take it at once. The wake only reads the line and writes a
# wake file, so a wake that races a change in the line costs one fallback
# retry, never a place.
#
# The line is moved by events. Whatever returns a tree to the pool calls
# fm_tree_wait_wake once per returned tree, which writes the wake file,
# <dir>/<home>/.wake-<id>, of the first live waiter that does not already hold
# one, so the k-th returned tree wakes the k-th waiter; a caller's retry loop
# blocks on that file (bin/fm-watch-statewait.py), so the waiter starts at once
# and its retries are only the fallback. An entry is live while the process that retries it, named
# by the caller as FM_TREE_WAIT_OWNER_PID, is alive with the identity it had
# when it joined; that process removes the entry when it exits. An entry
# leaves the line when its task's record publishes or exists in its home. Only
# an entry with no owner falls back to FM_TREE_WAIT_STALE: no deferral
# refreshed it in that many seconds, so no one is retrying it. The default is
# just over two of Firstmate's starter passes, the slowest retrier.
FM_TREE_WAIT_STALE=${FM_TREE_WAIT_STALE:-900}

fm_tree_wait_dir() {  # <project-lock>
  local identity
  identity=$(fm_project_capacity_overshare_identity "$1") || return 1
  printf '%s\n' "${1%/*}/project-tree-wait/$identity"
}

# The sort key for <priority>: 0-4 as given, anything else after them.
fm_tree_wait_rank() {  # <priority>
  case "$1" in
    [0-4]) printf '%s\n' "$1" ;;
    *) printf '5\n' ;;
  esac
}

# The place in a line for the home whose state directory is <state-dir>: the
# SHA-256 of its physical path, which no caller's working directory or git
# object format can change (chip on PR 196: git hash-object gave one home two
# keys from a SHA-1 and a SHA-256 repository), and no two homes share (chip at
# b2810ac4: two state paths had one 32-bit cksum, so each home's leave took
# the other's place).
fm_tree_wait_home() {  # <state-dir>
  local path sum
  path=$(cd -P -- "$1" 2>/dev/null && pwd -P) || path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$path" | sha256sum) || return 1
  else
    sum=$(printf '%s' "$path" | shasum -a 256) || return 1
  fi
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  case "$sum" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$sum"
}

fm_tree_wait_field() {  # <entry> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# Join the line, or refresh this task's entry, keeping its first wait and its
# place. A live <owner-pid> is recorded with its identity, so the entry lives
# exactly as long as that process. Sets FM_TREE_WAIT_WAKE to the entry's wake
# file.
fm_tree_wait_join() {  # <dir> <id> <priority> <state-dir> <now> [owner-pid]
  local dir=$1 id=$2 place since seq owner=${6:-} owner_identity='' tmp
  FM_TREE_WAIT_WAKE=
  place=$(fm_tree_wait_home "$4") || return 1
  place="$dir/$place"
  mkdir -p -- "$place" || return 1
  # A wake written before this deferral is spent: any wake file from here on
  # is a tree freed while this task waited.
  rm -f -- "${place:?}/.wake-${id:?}"
  since=$(fm_tree_wait_field "$place/$id" since)
  case "$since" in '' | *[!0-9]*) since=$5 ;; esac
  # A first join takes the line's next sequence number, its place among the
  # waiters of its priority; a refresh keeps the one it has.
  seq=$(fm_tree_wait_field "$place/$id" seq)
  case "$seq" in
    '' | *[!0-9]*)
      seq=$(cat -- "$dir/.seq" 2>/dev/null) || seq=
      case "$seq" in '' | *[!0-9]*) seq=0 ;; esac
      seq=$((seq + 1))
      tmp="$dir/.seq.${BASHPID:-$$}"
      printf '%s\n' "$seq" > "$tmp" && mv -f -- "$tmp" "$dir/.seq" || return 1
      ;;
  esac
  if [ -n "$owner" ] && fm_pid_alive "$owner"; then
    owner_identity=$(fm_pid_identity "$owner" 2>/dev/null) || owner_identity=
  else
    owner=
  fi
  tmp="$place/.$id.${BASHPID:-$$}"
  printf 'priority=%s\nsince=%s\nseq=%s\nseen=%s\nstate=%s\nowner=%s\nowner_identity=%s\n' \
    "$3" "$since" "$seq" "$5" "$4" "$owner" "$owner_identity" > "$tmp" &&
    mv -f -- "$tmp" "$place/$id" || return 1
  FM_TREE_WAIT_WAKE="$place/.wake-$id"
}

fm_tree_wait_drop() {  # <entry>
  rm -f -- "${1:?}" "${1%/*}/.wake-${1##*/}"
}

# Never fails: an entry it cannot name leaves the line once its record exists.
fm_tree_wait_leave() {  # <dir> <id> <state-dir>
  local home
  home=$(fm_tree_wait_home "$3") || return 0
  fm_tree_wait_drop "${1:?}/$home/${2:?}"
}

# Whether <entry> has left the line: its task started, its owner is gone, or,
# with no owner, nothing refreshed it within FM_TREE_WAIT_STALE seconds.
fm_tree_wait_gone() {  # <entry> <id> <now>
  local since seen state owner owner_identity
  since=$(fm_tree_wait_field "$1" since)
  seen=$(fm_tree_wait_field "$1" seen)
  state=$(fm_tree_wait_field "$1" state)
  owner=$(fm_tree_wait_field "$1" owner)
  owner_identity=$(fm_tree_wait_field "$1" owner_identity)
  case "$since$seen" in '' | *[!0-9]*) return 0 ;; esac
  [ -z "$state" ] || [ ! -e "$state/$2.meta" ] || return 0
  if [ -n "$owner" ]; then
    fm_pid_alive "$owner" || return 0
    [ -z "$owner_identity" ] || [ "$(fm_pid_identity "$owner" 2>/dev/null || true)" = "$owner_identity" ] || return 0
    return 1
  fi
  [ $(($3 - seen)) -gt "$FM_TREE_WAIT_STALE" ]
}

# The live waiters, one "<rank> <seq> <since> <home>/<id>" per line in line
# order, after removing every entry that has left the line. With <keep> it
# removes nothing: fm_tree_wait_wake reads the line without the project lock,
# so an entry it reads as gone may since have been refreshed by a join under
# that lock, and deleting its path would take that waiter's place (chip on
# PR 196 at 607bb0f6). Only a project-lock holder removes an entry.
fm_tree_wait_order() {  # <dir> <now> [keep]
  local dir=$1 now=$2 keep=${3:-} entry id home seq
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*/*; do
    [ -f "$entry" ] || continue
    id=${entry##*/}
    home=${entry%/*}
    home=${home##*/}
    if fm_tree_wait_gone "$entry" "$id" "$now"; then
      [ -n "$keep" ] || fm_tree_wait_drop "$entry"
      continue
    fi
    seq=$(fm_tree_wait_field "$entry" seq)
    case "$seq" in '' | *[!0-9]*) seq=0 ;; esac
    printf '%s %s %s %s\n' "$(fm_tree_wait_rank "$(fm_tree_wait_field "$entry" priority)")" \
      "$seq" "$(fm_tree_wait_field "$entry" since)" "$home/$id"
  done | LC_ALL=C sort -n -k1,1 -k2,2
}

# Count the live waiters ahead of <id> at <priority>. Sets FM_TREE_WAIT_AHEAD
# and FM_TREE_WAIT_AHEAD_IDS ("<id> (P<n>, waiting since <epoch>)",
# comma-separated, in line order).
fm_tree_wait_ahead() {  # <dir> <id> <priority> <now> <state-dir>
  local dir=$1 self now=$4 own_rank own_seq ahead
  FM_TREE_WAIT_AHEAD=0
  FM_TREE_WAIT_AHEAD_IDS=
  self=$(fm_tree_wait_home "$5") || self=
  self="$self/$2"
  own_rank=$(fm_tree_wait_rank "$3")
  # Not yet in the line: this start arrives after every waiter of its priority.
  own_seq=$(fm_tree_wait_field "$dir/$self" seq)
  case "$own_seq" in '' | *[!0-9]*) own_seq= ;; esac
  ahead=$(fm_tree_wait_order "$dir" "$now" | awk -v self="$self" -v r="$own_rank" -v s="$own_seq" '
    $4 != self && ($1 < r || ($1 == r && (s == "" || $2 + 0 < s + 0)))')
  [ -n "$ahead" ] || return 0
  FM_TREE_WAIT_AHEAD=$(printf '%s\n' "$ahead" | wc -l | tr -d ' ')
  FM_TREE_WAIT_AHEAD_IDS=$(printf '%s\n' "$ahead" | awk '
    { id = $4; sub(/^[^\/]*\//, "", id)
      printf "%s%s (%s, waiting since %s)", sep, id, ($1 == 5 ? "no priority" : "P" $1), $3; sep = ", " }')
}

# A tree went back to the pool: wake the first live waiter in line order that
# does not already hold an unconsumed wake, by writing its wake file. A waiter
# holding one has a tree coming already, so the k-th returned tree wakes the
# k-th waiter. Prints the woken id, or nothing when no waiter is left to wake.
# Returners run this after releasing the project lock, so the choice and the
# write are serialized by the line's own <dir>/.wake.lock (bin/fm-wake-lib.sh's
# locks, which every caller loads): two trees returned at once wake two
# waiters, never the head twice. It removes no entry, since it holds no project
# lock. Bounded: a wake that cannot take that lock leaves the waiter's own
# retry as the fallback.
FM_TREE_WAIT_WAKE_LOCK_WAIT=${FM_TREE_WAIT_WAKE_LOCK_WAIT:-10}
fm_tree_wait_wake() {  # <dir> <now>
  local dir=$1 now=$2 key wake woken='' rc=0
  [ -d "$dir" ] || return 0
  fm_lock_acquire_wait_max "$dir/.wake.lock" "$FM_TREE_WAIT_WAKE_LOCK_WAIT" || return 1
  while read -r _ _ _ key; do
    wake="$dir/${key%/*}/.wake-${key##*/}"
    [ ! -s "$wake" ] || continue
    printf '%s\n' "$now" >> "$wake" || rc=1
    [ "$rc" -ne 0 ] || woken=${key##*/}
    break
  done < <(fm_tree_wait_order "$dir" "$now" keep)
  fm_lock_release "$dir/.wake.lock" || true
  [ -z "$woken" ] || printf '%s\n' "$woken"
  return "$rc"
}

fm_project_capacity_overshare_dir() {  # <config-dir>
  local config=$1 parent
  parent=${config%/*}
  [ -n "$parent" ] && [ "$parent" != "$config" ] || return 1
  printf '%s\n' "$parent/state/project-capacity-overshare"
}

# Read config/project-capacity-headroom.
# Sets FM_PROJECT_CAPACITY_HEADROOM_STATE to off, ready, or no, and when ready
# sets FM_PROJECT_CAPACITY_HEADROOM_CMD to the program and its arguments.
fm_project_capacity_headroom_load() {  # <config-dir>
  local file="$1/project-capacity-headroom" line count=0 bin resolved rest token
  local -a cmd=()
  FM_PROJECT_CAPACITY_HEADROOM_CMD=()
  FM_PROJECT_CAPACITY_HEADROOM_STATE=no
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    FM_PROJECT_CAPACITY_HEADROOM_STATE=off
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    count=$((count + 1))
    if [ "$count" -gt 1 ]; then
      return 0
    fi
    rest=$line
    while [ -n "$rest" ]; do
      rest=${rest#"${rest%%[![:space:]]*}"}
      [ -n "$rest" ] || break
      token=${rest%%[[:space:]]*}
      [ -n "$token" ] || break
      cmd+=("$token")
      rest=${rest#"$token"}
    done
  done < "$file"
  if [ "$count" -eq 0 ]; then
    FM_PROJECT_CAPACITY_HEADROOM_STATE=off
    return 0
  fi
  if [ "${#cmd[@]}" -eq 0 ]; then
    return 0
  fi
  bin=${cmd[0]}
  case "$bin" in
    */*) resolved=$bin ;;
    *) resolved=$(command -v -- "$bin" 2>/dev/null) || resolved= ;;
  esac
  if [ -z "$resolved" ] || [ ! -x "$resolved" ] || [ -d "$resolved" ]; then
    return 0
  fi
  cmd[0]=$resolved
  FM_PROJECT_CAPACITY_HEADROOM_CMD=("${cmd[@]}")
  FM_PROJECT_CAPACITY_HEADROOM_STATE=ready
  return 0
}

# Returns 0 when <identity> already took its extra start inside the window.
fm_project_capacity_overshare_spent() {  # <dir> <identity> <now>
  local dir=$1 name=$2 now=$3 file epoch
  file="$dir/$name"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  IFS= read -r epoch < "$file" || return 1
  epoch=${epoch%$'\r'}
  epoch=${epoch#"${epoch%%[![:space:]]*}"}
  epoch=${epoch%"${epoch##*[![:space:]]}"}
  # A leading zero would make bash arithmetic read the value as octal.
  case "$epoch" in
    '' | *[!0-9]* | 0?*) return 1 ;;
  esac
  [ "$now" -lt $((epoch + FM_PROJECT_CAPACITY_OVERSHARE_WINDOW)) ]
}

# Record that <identity> took its extra start at <now>. Returns 1 when the
# record could not be written, which the caller treats as no admission.
fm_project_capacity_overshare_record() {  # <dir> <identity> <now>
  local dir=$1 name=$2 now=$3 tmp
  mkdir -p -- "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(mktemp "$dir/.recording.XXXXXX") || return 1
  if ! printf '%s\n' "$now" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dir/$name"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Remove the record of an extra start that launched no worker. Returns 1 when
# the record cannot be read or removed. The caller holds the project lock.
fm_project_capacity_overshare_release() {  # <dir> <identity> <epoch>
  local file="$1/$2" epoch
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  IFS= read -r epoch < "$file" || return 1
  [ "$epoch" = "$3" ] || return 0
  rm -f -- "$file"
}

# The record identity for the project whose shared project lock is
# <project-lock>: the hash fm_treehouse_project_lock_path names that lock by.
fm_project_capacity_overshare_identity() {  # <project-lock>
  local identity=${1##*/}
  case "$identity" in
    .treehouse-project-*.lock) ;;
    *) return 1 ;;
  esac
  identity=${identity#.treehouse-project-}
  identity=${identity%.lock}
  case "$identity" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  printf '%s\n' "$identity"
}

# First step of deciding whether a project already at its declared count may
# start one more worker, taken while the caller holds <project-lock>, the
# fm_treehouse_project_lock_path for the project. Sets
# FM_PROJECT_CAPACITY_OVERSHARE to off, no, spent, or open. off means the
# command is not configured, and no means it cannot run, so neither runs a
# reading. spent means this project already used its extra start in the
# window. open means a reading may run, and sets
# FM_PROJECT_CAPACITY_OVERSHARE_DIR and FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY
# for the steps below.
fm_project_capacity_overshare_prepare() {  # <config-dir> <project-lock>
  local config=$1 lock=$2 identity now dir
  FM_PROJECT_CAPACITY_OVERSHARE=no
  FM_PROJECT_CAPACITY_OVERSHARE_DIR=
  FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY=
  FM_PROJECT_CAPACITY_OVERSHARE_AT=
  FM_PROJECT_CAPACITY_HEADROOM_LINE=
  fm_project_capacity_headroom_load "$config"
  case "$FM_PROJECT_CAPACITY_HEADROOM_STATE" in
    off)
      FM_PROJECT_CAPACITY_OVERSHARE=off
      return 0
      ;;
    ready) ;;
    *) return 0 ;;
  esac
  identity=$(fm_project_capacity_overshare_identity "$lock") || return 0
  now=$(date +%s 2>/dev/null) || now=
  # A leading zero would make bash arithmetic read the value as octal.
  case "$now" in
    '' | *[!0-9]* | 0?*) return 0 ;;
  esac
  dir=$(fm_project_capacity_overshare_dir "$config") || return 0
  FM_PROJECT_CAPACITY_OVERSHARE_DIR=$dir
  FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY=$identity
  if fm_project_capacity_overshare_spent "$dir" "$identity" "$now"; then
    FM_PROJECT_CAPACITY_OVERSHARE=spent
    return 0
  fi
  FM_PROJECT_CAPACITY_OVERSHARE=open
  return 0
}

# Run the reading prepared above. This helper records nothing and prints
# nothing, so fm-spawn.sh can run it without the project lock held.
# Sets FM_PROJECT_CAPACITY_HEADROOM_LINE
# to the reading's first line, cut as the admission log cuts it, or to empty
# when the reading failed, printed no line, or timed out.
fm_project_capacity_headroom_read() {
  local rc=0 line
  FM_PROJECT_CAPACITY_HEADROOM_LINE=
  _fm_project_capacity_require_timeout || return 0
  line=$(fm_run_timed "$FM_PROJECT_CAPACITY_HEADROOM_TIMEOUT" "${FM_PROJECT_CAPACITY_HEADROOM_CMD[@]}" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 0
  line=${line%%$'\n'*}
  line=${line%$'\r'}
  # An exit 0 with no reading line has shown no headroom.
  [ -n "$line" ] || return 0
  if [ "${#line}" -gt 240 ]; then
    line=${line:0:240}
  fi
  FM_PROJECT_CAPACITY_HEADROOM_LINE=$line
  return 0
}

# Last step, taken while the caller again holds the project lock after a
# recount still at the declared count. Rechecks the window, then records it
# and logs the reading's line when the reading reported room. Sets
# FM_PROJECT_CAPACITY_OVERSHARE to admit, no, or spent, and on admit sets
# FM_PROJECT_CAPACITY_OVERSHARE_AT to the recorded epoch for
# fm_project_capacity_overshare_release. no means the reading showed no room
# or the record could not be written.
fm_project_capacity_overshare_admit() {
  local now
  FM_PROJECT_CAPACITY_OVERSHARE=no
  now=$(date +%s 2>/dev/null) || now=
  # A leading zero would make bash arithmetic read the value as octal.
  case "$now" in
    '' | *[!0-9]* | 0?*) return 0 ;;
  esac
  if fm_project_capacity_overshare_spent \
    "$FM_PROJECT_CAPACITY_OVERSHARE_DIR" "$FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY" "$now"; then
    FM_PROJECT_CAPACITY_OVERSHARE=spent
    return 0
  fi
  [ -n "${FM_PROJECT_CAPACITY_HEADROOM_LINE:-}" ] || return 0
  fm_project_capacity_overshare_record \
    "$FM_PROJECT_CAPACITY_OVERSHARE_DIR" "$FM_PROJECT_CAPACITY_OVERSHARE_IDENTITY" "$now" || return 0
  printf '%s\n' "headroom: $FM_PROJECT_CAPACITY_HEADROOM_LINE" >&2
  FM_PROJECT_CAPACITY_OVERSHARE_AT=$now
  FM_PROJECT_CAPACITY_OVERSHARE=admit
  return 0
}

# Decide whether a project already at its declared count may start one more
# worker, in one call while the caller holds the project lock throughout.
# bin/fm-spawn.sh instead drives the three steps above apart so the reading
# runs unlocked. Sets FM_PROJECT_CAPACITY_OVERSHARE to off, admit, no, or
# spent, with the meanings the steps above give them.
fm_project_capacity_overshare() {  # <config-dir> <project-lock>
  fm_project_capacity_overshare_prepare "$1" "$2"
  [ "$FM_PROJECT_CAPACITY_OVERSHARE" = open ] || return 0
  fm_project_capacity_headroom_read
  fm_project_capacity_overshare_admit
}
