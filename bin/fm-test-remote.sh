#!/usr/bin/env bash
# fm-test-remote.sh - run one Firstmate suite command on another Mac, against
# the exact commit of this checkout, one Firstmate suite at a time through
# that Mac's machine gate.
#
# Usage:
#   fm-test-remote.sh <host>:<scratch-root> [--base <commit>] [--pull <name>=<path>]... -- <script> [args...]
#   fm-test-remote.sh --help
#
# bin/fm-test-run.sh --remote and bin/fm-stock-bash-check.sh --remote hand
# their run to this script, and a maintainer may call it directly. <host> is
# an ssh destination, such as an ssh config alias, reached in ssh's batch
# mode, so a missing key fails instead of prompting, and <scratch-root> is an
# existing directory on that host. <script> is a repository-relative script,
# run on the host as `<host bash> <script> [args...]` from the root of the
# host's copy of the commit, with that bash's directory first on PATH.
#
# In order, it:
#   1. names the commit under test: this checkout's HEAD or, when the checkout
#      has changes git does not ignore, tracked or untracked, a commit of
#      exactly that working tree whose parent is HEAD. That commit is built in
#      a temporary index, so HEAD, the index, and the branch are untouched.
#      Both are printed.
#   2. makes a fresh run directory <scratch-root>/fm-test-remote.XXXXXX on the
#      host, holding an empty repo/, out/, and tmp/. The scratch root must
#      already exist: this never creates it, so an unmounted volume refuses
#      rather than putting the run on the host's system disk.
#   3. pushes that commit, --base's commit, and this checkout's branches,
#      remote-tracking refs, and tags into repo/ over ssh, and gives repo/ each
#      of this checkout's remotes, never fetched, and each remote's HEAD, so a
#      suite there reads the refs and remotes it reads here. A remote's URL has
#      any user info, such as a token or git@, removed before it leaves this
#      machine. It checks the commit out on a branch named as HEAD's branch here,
#      or detached when HEAD here is detached, and stops before anything runs
#      unless `git rev-parse HEAD` there prints that commit.
#   4. runs <script> under the host's ~/.agent-state/machine-gate.sh with
#      --needs firstmate, so one Firstmate suite runs there at a time, with
#      TMPDIR set to tmp/ so the suite's own temp files stay on the scratch
#      volume too. A busy
#      gate is a wait, not a failure: each refused try records its arrival in
#      the gate's line, and the next try follows within
#      FM_TEST_REMOTE_RETRY_SECS, inside the gate's 180-second live-waiter
#      window, so the gate's longest-live-waiter rule starts waiters in
#      arrival order. Only the caller's own time budget bounds the wait.
#   5. streams the script's output back, copies each --pull <name> from out/
#      to <path> here (a relative <path> is relative to this checkout's root),
#      removes the run directory, and exits with the script's own status, or
#      2 when the script passed but a --pull file did not come back. Any file
#      already at a --pull <path> is removed before step 1, so after any exit
#      that path holds this run's file or nothing.
#
# It never runs a suite or takes a machine line on this machine, and it never
# falls back to a local run: a failure before or during the remote run is
# reported and exits 2. The host run sees only the host's own environment,
# plus FM_TEST_ONLY when it is set here, because that narrows which cases a
# test file runs. Live switches never cross: with a control variable named by a
# suite's fm_live_gate declaration, or any FM_ variable named as a LIVE, E2E, or
# REAL switch outside the FM_FAKE_ and FM_TEST_ fixtures, set to anything here,
# it refuses before any ssh and names the variable, so a live check runs on the
# caller's machine without --remote. The machine gate sees none of this machine's
# markers, such as NO_MISTAKES_GATE, so a run here inside a no-mistakes gate
# still queues on the host.
#
# The script's status is reported as it is. bin/fm-test-run.sh --remote is what
# fails a suite that skips because the host lacks what it needs; a script named
# here directly gets no such check.
#
# Exit status: the script's own; 2 when nothing ran (a live switch set here, no
# ssh connection, an ssh key the host refused, a missing scratch root, a failed
# push or checkout, a rev-parse mismatch, or no machine gate on the host), when
# the connection dropped mid-run, so the verdict is unknown, or when the script
# passed but a --pull file was not copied back. A failing script keeps its own
# status.
#
# Environment:
#   FM_TEST_REMOTE_BASH        bash on the host that runs <script> (default
#                              /opt/homebrew/bin/bash)
#   FM_TEST_REMOTE_RETRY_SECS  seconds between tries while the host's gate is
#                              busy (default 15; under 180)
set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-test-remote.sh"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"

die() {
  printf 'fm-test-remote: %s\n' "$*" >&2
  exit 2
}

say() {
  printf 'fm-test-remote: %s\n' "$*" >&2
}

# The host's machine gate admitted the run: say so on the run's real output,
# hand the command the descriptors the host saved, and mark the line held so
# a nested fm-test-run.sh does not queue on the same gate again.
if [ "${1:-}" = __admitted ]; then
  marker=$2 waited_since=$3 host=$4
  shift 4
  [ "${1:-}" = -- ] && shift
  : >"$marker" || exit 2
  exec 1>&3 2>&4 3>&- 4>&-
  say "started on $host after $(($(date +%s) - waited_since))s in its machine gate's line"
  export FM_TEST_MACHINE_LINE_HELD=1
  exec "$@"
fi

# On the host, from the checked-out commit: queue on the host's gate and run.
# Each try's own output goes to a file, so a refused try prints one wait line
# instead of the gate's text every few seconds; an admitted run writes to the
# descriptors saved here.
if [ "${1:-}" = __host ]; then
  run=$2 name=$3 retry=$4
  shift 4
  [ "${1:-}" = -- ] && shift
  host=$(hostname -s 2>/dev/null || hostname)
  gate="$HOME/.agent-state/machine-gate.sh"
  [ -x "$gate" ] || die "$host has no machine gate at $gate, so it cannot hold one Firstmate suite at a time; nothing ran"
  marker="$run/admitted"
  attempt="$run/gate-try.log"
  waited_since=$(date +%s)
  said=
  PATH="$(dirname "$BASH"):$PATH"
  TMPDIR="$run/tmp"
  export PATH TMPDIR
  exec 3>&1 4>&2
  # No caller marker applies on the host: a gate marker would let the gate
  # skip firstmate, and FM_TASK_ID would read the host's plain clone as a
  # primary checkout. A wait of 0 makes each refused try log its arrival now.
  while :; do
    env -u NO_MISTAKES_GATE -u MACHINE_LINE_FIRSTMATE_HELD -u MACHINE_LINE_FIRSTMATE_HELD_TOKEN \
      -u FM_TASK_ID -u FM_TEST_MACHINE_LINE_HELD \
      MACHINE_LINE_NAME="$name" MACHINE_GATE_FIRSTMATE_WAIT=0 \
      "$BASH" "$gate" run --cap 180 --needs firstmate -- \
      "$BASH" "$SELF" __admitted "$marker" "$waited_since" "$host" -- "$BASH" "$@" >"$attempt" 2>&1
    rc=$?
    [ ! -e "$marker" ] || exit "$rc"
    if [ "$rc" -ne 75 ]; then
      cat "$attempt" >&2
      die "the machine gate on $host refused the run (exit $rc); nothing ran"
    fi
    why=$(grep 'NOT STARTED' "$attempt" | tail -n 1)
    if [ "$why" != "$said" ]; then
      say "waiting on $host: ${why:-its machine gate is busy}"
      said=$why
    fi
    sleep "$retry"
  done
fi

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '' | -*) die "the first argument is <host>:<scratch-root> (see --help)" ;;
esac
SPEC=$1
shift
case "$SPEC" in
  *:/*) ;;
  *) die "'$SPEC' is not <host>:<scratch-root> with an absolute scratch root" ;;
esac
HOST=${SPEC%%:*}
SCRATCH_ROOT=${SPEC#*:}
[ -n "$HOST" ] || die "'$SPEC' names no host"

BASE=
PULLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || die "--base takes a commit"
      BASE=$2
      shift 2
      ;;
    --pull)
      [ $# -ge 2 ] || die "--pull takes <name>=<path>"
      case "$2" in
        *=?*) ;;
        *) die "--pull takes <name>=<path>, got '$2'" ;;
      esac
      case "${2%%=*}" in
        '' | . | .. | */*) die "--pull names a file in the run's out/ directory, got '${2%%=*}'" ;;
      esac
      pull_dest=${2#*=}
      case "$pull_dest" in /*) ;; *) pull_dest="$ROOT/$pull_dest" ;; esac
      PULLS+=("${2%%=*}=$pull_dest")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[ $# -gt 0 ] || die "no script to run (see --help)"
SCRIPT=$1

REMOTE_BASH=${FM_TEST_REMOTE_BASH:-/opt/homebrew/bin/bash}
RETRY=${FM_TEST_REMOTE_RETRY_SECS:-15}
if ! printf '%s' "$RETRY" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
  || ! awk -v r="$RETRY" 'BEGIN { exit !(r > 0 && r < 180) }'; then
  die "FM_TEST_REMOTE_RETRY_SECS must be seconds above 0 and under 180, got '$RETRY'"
fi
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)

for pull in ${PULLS[@]+"${PULLS[@]}"}; do
  rm -f -- "${pull#*=}" || die "cannot clear ${pull#*=} for this run's output; nothing ran"
done

# Print the live switches set here: each exported FM_ variable named as one, and
# each control variable the suites' fm_live_gate declarations name.
live_switches_set() {
  local var
  for var in $({
    compgen -e | grep -E '^FM_([A-Z0-9_]+_)?(LIVE|E2E|REAL)(_|$)' | grep -vE '^FM_(FAKE|TEST)_'
    sed -nE 's/^[[:space:]]*fm_live_gate[[:space:]]+(default-on|opt-in)[[:space:]]+([A-Za-z0-9_,]+).*/\2/p' "$ROOT"/tests/*.sh 2>/dev/null | tr ',' '\n'
  } | sort -u); do
    [ -z "${!var:-}" ] || printf '%s ' "$var"
  done
}
LIVE_SET=$(live_switches_set)
[ -z "$LIVE_SET" ] \
  || die "live switch set here: ${LIVE_SET% }. It does not cross to $HOST; unset it, or run the live suite on this machine without --remote; nothing ran"

# Print a remote's URL without user info: https://token@host/path becomes
# https://host/path, and git@host:path becomes host:path.
without_user_info() {
  printf '%s\n' "$1" | sed -E -e 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#' -e 's#^[^/]*@([^/]*:)#\1#'
}

# Print the words quoted for the host's login shell, one line.
quote_words() {
  local w out=
  for w in "$@"; do
    out="$out $(printf '%q' "$w")"
  done
  printf '%s' "${out# }"
}

# Run one setup command on the host, keeping the last line it printed in
# SETUP_OUT and its stderr's last line in SETUP_ERR. A failed ssh connection
# (exit 255) is named for what it was, never retried here.
SETUP_OUT=
SETUP_ERR=
remote_setup() {  # <command string>
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/fm-test-remote-out.XXXXXX") || die "mktemp failed"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-test-remote-err.XXXXXX") || die "mktemp failed"
  ssh -n "${SSH_OPTS[@]}" "$HOST" "$1" >"$out" 2>"$err"
  rc=$?
  SETUP_OUT=$(tail -n 1 "$out")
  SETUP_ERR=$(tail -n 1 "$err")
  rm -f "$out" "$err"
  if [ "$rc" -eq 255 ]; then
    case "$SETUP_ERR" in
      *'Permission denied'*) die "$HOST refused this account's ssh key ($SETUP_ERR); give this account $HOST's key; nothing ran" ;;
      *) die "cannot reach $HOST over ssh (${SETUP_ERR:-ssh exit 255}); nothing ran" ;;
    esac
  fi
  return "$rc"
}

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$ROOT is not a git checkout, so there is no commit to run; nothing ran"
HEAD_SHA=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || die "this checkout has no HEAD commit; nothing ran"
BRANCH=$(git -C "$ROOT" symbolic-ref -q --short HEAD) || BRANCH=
SHA=$HEAD_SHA
CHANGES=$(git -C "$ROOT" status --porcelain --untracked-files=all) \
  || die "git status failed in $ROOT; nothing ran"
if [ -n "$CHANGES" ]; then
  index_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-remote-index.XXXXXX") || die "mktemp failed"
  export GIT_INDEX_FILE="$index_dir/index"
  if git -C "$ROOT" read-tree HEAD && git -C "$ROOT" add -A \
    && tree=$(git -C "$ROOT" write-tree); then
    SHA=$(GIT_AUTHOR_NAME=fm-test-remote GIT_AUTHOR_EMAIL=fm-test-remote@invalid \
      GIT_COMMITTER_NAME=fm-test-remote GIT_COMMITTER_EMAIL=fm-test-remote@invalid \
      git -C "$ROOT" commit-tree "$tree" -p "$HEAD_SHA" -m "fm-test-remote: working tree over $HEAD_SHA") \
      || SHA=
  else
    SHA=
  fi
  unset GIT_INDEX_FILE
  rm -rf "${index_dir:?}"
  [ -n "$SHA" ] || die "could not record this checkout's uncommitted changes as a commit; nothing ran"
fi
BASE_SHA=
if [ -n "$BASE" ]; then
  BASE_SHA=$(git -C "$ROOT" rev-parse --verify "$BASE^{commit}" 2>/dev/null) \
    || die "--base $BASE is not a commit here; nothing ran"
fi

if [ "$SHA" = "$HEAD_SHA" ]; then
  say "$HOST runs $SCRIPT at $SHA"
else
  say "$HOST runs $SCRIPT at $SHA: HEAD $HEAD_SHA plus this checkout's $(printf '%s\n' "$CHANGES" | wc -l | tr -d ' ') uncommitted paths"
fi

RUN=
SSH_PID=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  local rc=$?
  if [ -n "$SSH_PID" ]; then
    kill "$SSH_PID" 2>/dev/null
    wait "$SSH_PID" 2>/dev/null
  fi
  if [ -n "$RUN" ]; then
    case "$RUN" in
      "$SCRATCH_ROOT"/fm-test-remote.*)
        if ssh -n "${SSH_OPTS[@]}" "$HOST" "rm -rf -- $(quote_words "$RUN")" 2>/dev/null; then
          say "removed $RUN on $HOST"
        else
          say "could not remove $RUN on $HOST; it is left there"
        fi
        ;;
      *) say "not removing '$RUN' on $HOST: it is not under $SCRATCH_ROOT/fm-test-remote.*" ;;
    esac
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# shellcheck disable=SC2016 # The host's shell expands these.
setup="root=$(quote_words "$SCRATCH_ROOT")"'
[ -d "$root" ] || { printf "scratch root %s does not exist on this host\n" "$root" >&2; exit 3; }
run=$(mktemp -d "$root/fm-test-remote.XXXXXX") && mkdir "$run/repo" "$run/out" "$run/tmp" && git init -q "$run/repo" && git -C "$run/repo" config receive.denyCurrentBranch ignore && printf "%s\n" "$run"'
remote_setup "$setup" || die "could not make a run directory under $SCRATCH_ROOT on $HOST (${SETUP_ERR:-no reason given}); nothing ran"
case "$SETUP_OUT" in
  "$SCRATCH_ROOT"/fm-test-remote.*) RUN=$SETUP_OUT ;;
  *) die "$HOST printed '$SETUP_OUT' for its run directory, not one under $SCRATCH_ROOT; nothing ran" ;;
esac

refspecs=("$SHA:refs/fm-test-remote/head" 'refs/heads/*:refs/heads/*' 'refs/remotes/*:refs/remotes/*' 'refs/tags/*:refs/tags/*')
[ -z "$BASE_SHA" ] || refspecs+=("$BASE_SHA:refs/fm-test-remote/base")
if ! push_err=$(GIT_SSH_COMMAND="$(quote_words ssh "${SSH_OPTS[@]}")" \
  git -C "$ROOT" push --no-verify -q "$HOST:$RUN/repo" "${refspecs[@]}" 2>&1); then
  die "could not push $SHA to $HOST: $(printf '%s\n' "$push_err" | tail -n 1); nothing ran"
fi

line_name=$(printf 'fm-test-remote-%s-%s-%s-%s' "$(basename "$SCRIPT" .sh)" "$(printf '%s' "$SHA" | cut -c1-12)" \
  "$(hostname -s 2>/dev/null || hostname)" "$$" | tr -c 'A-Za-z0-9._-' '_')
host_env=()
[ -z "${FM_TEST_ONLY+set}" ] || host_env=(env "FM_TEST_ONLY=$FM_TEST_ONLY")
copy_setup=
while IFS= read -r remote; do
  url=$(git -C "$ROOT" config --get "remote.$remote.url") || continue
  copy_setup="$copy_setup && git remote add $(quote_words "$remote" "$(without_user_info "$url")")"
  if remote_head=$(git -C "$ROOT" symbolic-ref -q "refs/remotes/$remote/HEAD"); then
    copy_setup="$copy_setup && git symbolic-ref $(quote_words "refs/remotes/$remote/HEAD" "$remote_head")"
  fi
done < <(git -C "$ROOT" remote)
if [ -n "$BRANCH" ]; then
  checkout=(-B "$BRANCH")
else
  checkout=(--detach)
fi
run_cmd="cd $(quote_words "$RUN/repo")$copy_setup && git -c advice.detachedHead=false checkout -q -f $(quote_words "${checkout[@]}") $SHA && got=\$(git rev-parse HEAD) && [ \"\$got\" = $SHA ] || { printf 'fm-test-remote: the host copy is at %s, not %s; nothing ran\\n' \"\${got:-no commit}\" $SHA >&2; exit 2; }; exec $(quote_words ${host_env[@]+"${host_env[@]}"} "$REMOTE_BASH" "$RUN/repo/bin/fm-test-remote.sh" __host "$RUN" "$line_name" "$RETRY" -- "$@")"

ssh -n "${SSH_OPTS[@]}" "$HOST" "$run_cmd" &
SSH_PID=$!
wait "$SSH_PID"
rc=$?
SSH_PID=
if [ "$rc" -eq 255 ]; then
  die "the ssh connection to $HOST failed during the run of $SCRIPT at $SHA (exit 255), so its verdict is unknown"
fi

undelivered=
for pull in ${PULLS[@]+"${PULLS[@]}"}; do
  name=${pull%%=*}
  dest=${pull#*=}
  if ! mkdir -p "$(dirname "$dest")"; then
    say "cannot make the directory for $dest, so it is not written"
  else
    ssh -n "${SSH_OPTS[@]}" "$HOST" "cat -- $(quote_words "$RUN/out/$name")" >"$dest.fm-test-remote" 2>/dev/null
    pull_rc=$?
    if [ "$pull_rc" -eq 0 ] && mv "$dest.fm-test-remote" "$dest"; then
      continue
    fi
    rm -f "$dest.fm-test-remote"
    case "$pull_rc" in
      0) say "cannot write $dest" ;;
      255) say "the ssh connection to $HOST failed while copying back $name, so $dest is not written" ;;
      *) say "the run on $HOST wrote no $name, so $dest is not written" ;;
    esac
  fi
  undelivered="$undelivered $dest"
done

say "$HOST finished $SCRIPT at $SHA: exit $rc"
[ -z "$undelivered" ] || [ "$rc" -ne 0 ] \
  || die "$SCRIPT passed on $HOST, but not every output it was asked for came back:$undelivered"
exit "$rc"
