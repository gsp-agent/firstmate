#!/usr/bin/env bash
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
#     no longer uses local resources.
# A place therefore frees when a PR-based ship records its ready PR, or when any
# task is cleaned up and its record removed. A local-only ship and a scout have
# no recorded handoff and hold their place until cleanup. A worker that is
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
# count. A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included. Freeing a
# place needs no lock, because removing a record or adding pr= only ever lowers
# the count.
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
# its extra-start window is open. Exit 0 admits one spawn past that count.
# Before that spawn continues, the epoch second is written as the only line of
# <config-dir>/../state/project-capacity-overshare/<project-name>. A second
# extra spawn for that project is deferred while that epoch is less than
# FM_PROJECT_CAPACITY_OVERSHARE_WINDOW seconds old. The window is 420 seconds,
# about one starter pass. Each project has its own file, so two projects do
# not rewrite one record. bin/fm-spawn.sh holds the project lock across the
# reading and the write, so two spawns of one project cannot both take the
# extra start. An extra start whose record cannot be written is not admitted.
# Workers already running are never stopped. A name that is empty, ".", "..",
# or that contains a slash or a newline cannot be recorded, so it is not
# admitted past its count.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first. The headroom reading
# loads bin/fm-timeout-lib.sh when that reading runs. No side effects on source.

# Exit status of a spawn deferred because the project is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_PROJECT_CAPACITY_DEFER_EXIT=75

# How long one extra start remains that project's extra start. 7 * 60 seconds
# matches one starter pass of about 7 minutes.
FM_PROJECT_CAPACITY_OVERSHARE_WINDOW=420

# A reading that has not exited by this many seconds is no room. The shared
# reading samples the CPU over a few seconds and has taken up to 12.7 seconds
# on a loaded machine. The spawn holds the project lock for as long as the
# reading runs.
FM_PROJECT_CAPACITY_HEADROOM_TIMEOUT=30

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

# Count the task records holding a place in one project's capacity.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is not counted.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i
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
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}

# Load bin/fm-timeout-lib.sh the first time a headroom reading needs a bound.
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

# Returns 0 when <project> already took its extra start inside the window.
fm_project_capacity_overshare_spent() {  # <dir> <project> <now>
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

# Record that <project> took its extra start at <now>. Returns 1 when the
# record could not be written, which the caller treats as no admission.
fm_project_capacity_overshare_record() {  # <dir> <project> <now>
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

# Decide whether a project already at its declared count may start one more
# worker. The caller holds the project lock.
# Sets FM_PROJECT_CAPACITY_OVERSHARE to off, admit, no, or spent.
# off means the command is not configured. admit records the window before
# returning. no means the reading failed, printed no line, was missing, or
# could not be recorded.
# spent means this project already used its extra start in the window.
fm_project_capacity_overshare() {  # <config-dir> <project-name>
  local config=$1 name=$2 now dir rc=0 line
  FM_PROJECT_CAPACITY_OVERSHARE=no
  fm_project_capacity_headroom_load "$config"
  case "$FM_PROJECT_CAPACITY_HEADROOM_STATE" in
    off)
      FM_PROJECT_CAPACITY_OVERSHARE=off
      return 0
      ;;
    ready) ;;
    *) return 0 ;;
  esac
  case "$name" in
    '' | '.' | '..' | *'/'* | *$'\n'*) return 0 ;;
  esac
  now=$(date +%s 2>/dev/null) || now=
  # A leading zero would make bash arithmetic read the value as octal.
  case "$now" in
    '' | *[!0-9]* | 0?*) return 0 ;;
  esac
  dir=$(fm_project_capacity_overshare_dir "$config") || return 0
  if fm_project_capacity_overshare_spent "$dir" "$name" "$now"; then
    FM_PROJECT_CAPACITY_OVERSHARE=spent
    return 0
  fi
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
  fm_project_capacity_overshare_record "$dir" "$name" "$now" || return 0
  printf '%s\n' "headroom: $line" >&2
  FM_PROJECT_CAPACITY_OVERSHARE=admit
  return 0
}
