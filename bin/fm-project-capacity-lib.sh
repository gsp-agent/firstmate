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
# its unlocked reading, locked recount, and per-home task-set serialization.
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
# could not be read marked "(state unreadable)". Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i rc
  local -a cache_dirs cache_locks
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
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
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      # An unreadable crew state must retain its slot: skipping it would
      # undercount, while failing the whole count would refuse other spawns.
      fm_project_capacity_is_working "$state" "$id"
      rc=$?
      [ "$rc" -ne 1 ] || continue
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      [ "$rc" -eq 0 ] || label="$label (state unreadable)"
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
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
# reports it `available`, and each tree the pool can still create below its
# size is free too. `available` is Treehouse's status, not its reuse test, so
# the count can be high, never low: a spawn whose `treehouse get` then refuses
# the pool still defers (bin/fm-spawn.sh).
# Sets FM_PROJECT_CAPACITY_POOL_KNOWN to 1 with FM_PROJECT_CAPACITY_POOL_MAX,
# FM_PROJECT_CAPACITY_POOL_FREE and FM_PROJECT_CAPACITY_POOL_HELD (each held
# tree as <name> <status>[ by <lease holder>], comma-separated), or to 0 when
# the project declares no size or the pool cannot be read; never fails.
FM_PROJECT_CAPACITY_POOL_TIMEOUT=${FM_PROJECT_CAPACITY_POOL_TIMEOUT:-20}
fm_project_capacity_pool() {  # <project-dir>
  local project=$1 toml max="" json counts total avail
  FM_PROJECT_CAPACITY_POOL_KNOWN=0
  FM_PROJECT_CAPACITY_POOL_MAX=
  FM_PROJECT_CAPACITY_POOL_FREE=
  FM_PROJECT_CAPACITY_POOL_HELD=
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
