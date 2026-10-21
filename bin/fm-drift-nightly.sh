#!/usr/bin/env bash
# fm-drift-nightly.sh - compare a fork to kunchenguid/firstmate main.
#
# Usage:
#   fm-drift-nightly.sh check [--repo <dir>] [--fork <ref>] [--upstream <ref>] [--proof <file>] [--no-fetch]
#   fm-drift-nightly.sh nightly [--repo <dir>] [--log <file>]
#   fm-drift-nightly.sh install [--dry-run] [--hour <0-23>] [--minute <0-59>] [--repo <dir>] [--log <file>]
#   fm-drift-nightly.sh uninstall [--dry-run]
#   fm-drift-nightly.sh --help
#
# check defaults to fork HEAD and upstream kunchenguid/main. After the optional
# fetch, both refs resolve to fixed commit SHAs used for the entire check and
# report; later ref changes belong to the next run. Only committed trees are
# compared, not working-tree or staged changes.
# check prints behind and ahead counts, path-ok for changed paths that match
# the accepted tree, path-drift for every mismatch with that tree, one line
# per commit reachable from the captured fork and not captured upstream, one
# error line per numbered first-parent PR missing a proof entry, then one
# unmatched line per proof entry whose PR has no first-parent commit.
# Accepted patches are replayed from the merge-base in first-parent order
# using git merge-tree with each accepted first-parent commit's parent as
# its patch base. Only first-parent commits are replayed. An accepted
# merge's first-parent patch carries every commit it merges (reachable
# from the merge, not from its first parent or the merge-base), so those
# carried commits are never replayed on their own and inherit the carrying
# PR's class. A path is path-ok only when its fork content and mode match
# the resulting tree.
# Missing accepted changes and extra changes are path-drift. Rename detection
# is disabled so a deletion cannot disappear into a rename onto a proven file.
# No file is exempt, including the guard and proof files.
# A commit is pending when its first-parent PR is listed as pending, printed
# with its bead on every run; merge when it has multiple parents and is not
# proven; keep when its first-parent PR is proven; and unproven otherwise.
# A first-parent PR number is parsed from "Merge pull request #N",
# "Merge PR #N", "Merge PR N", or a trailing "(#N)" in the commit subject.
# A first-parent commit with no parseable PR number is unproven.
# Exit 0 when no path-drift line is printed and every numbered first-parent
# PR has a proof entry, 1 on either mismatch, and 2 on usage or git failure.
# Unnumbered first-parent commits whose changes are later cut do not fail
# the check. behind is reported and does not change the exit code.
#
# The proof file holds "pr: <number>" or "pending-pr: <number> <bead>" per
# line. A PR writes its own line before merging; the line lands inside its
# squash or merge commit and matches afterward, so no SHA can dangle.
# "pending-pr" accepts that PR with its proof still owed on <bead>; it is
# accepted like a proven PR but never reported as keep. Duplicate entries
# are errors. An entry whose PR has no first-parent commit in the captured
# range proves nothing and prints "unmatched: <number>" without changing the
# exit code: an open PR's own line stays unmatched until its squash or merge
# commit lands, and a wrong number leaves the real PR unproven and prints
# "error: missing manifest entry for PR <number>" even if its paths match.
# Blank lines and lines whose first character is # are ignored.
# When --proof is omitted, the proof file is drift-proof.txt in the captured
# fork commit's tree; a working-tree, staged, or untracked copy is never read.
# When that tree has no drift-proof.txt, no commit is proven.
#
# With fetch left on, check runs git fetch --no-tags kunchenguid main when
# that remote exists in the repo. --no-fetch skips that. A missing remote
# with fetch left on is an error.
#
# nightly is the installed job's command. It prints the run time, check's
# output for --repo with the default refs, fetch and proof file, and check's
# exit code, then exits with that code. A nonzero check sends one note through
# fm-inbox.sh beside this script, which picks the Firstmate home (FM_HOME, else
# the home holding this script). The note names the exit code, the first ten
# path-drift and error lines, a count of the rest, and the
# log, under request id fm-drift-nightly-<local date>, so a same-day rerun
# makes no second note. A green check sends nothing.
# --log names the job's log in the note and defaults to
# ~/Library/Logs/dev.firstmate.drift-nightly.log; it must be absolute.
#
# install writes ~/Library/LaunchAgents/dev.firstmate.drift-nightly.plist and
# bootstraps the job for the current user. The job runs nightly once a night,
# defaulting to 03:17 in the machine's local time, with --repo and --log only,
# and appends its stdout and stderr to that log. install creates the log's
# directory, because launchd does not.
# install XML-escapes each string it writes and replaces the plist only after
# plutil -lint accepts the new one; a rejected plist exits 2 before launchctl
# runs, leaving the installed plist and job unchanged.
# uninstall bootstraps nothing, removes that job, and deletes the plist only
# when launchctl bootout succeeds or exits 3 because no such job is loaded;
# any other bootout failure keeps the plist and exits 2. uninstall never
# touches the log.
# A second uninstall, when the plist is already gone, exits 0.
# --dry-run prints the action and does not write a file or call launchctl.
# FM_DRIFT_AGENT_DIR selects the LaunchAgents directory.
# FM_DRIFT_LAUNCHCTL selects the launchctl executable.
set -u
export LC_ALL=C

LABEL=dev.firstmate.drift-nightly
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH=$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")
DEFAULT_REPO=$(cd "$SCRIPT_DIR/.." && pwd)

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

proof_has() {
  case $KEEP_SHAS in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

pending_bead() {
  local rest=${PENDING_SHA_BEADS#*"|$1="}
  [ "$rest" != "$PENDING_SHA_BEADS" ] || return 1
  printf '%s\n' "${rest%%|*}"
}

pr_number() { # <subject> -> PR number or failure
  local n
  case $1 in
    'Merge pull request #'*) n=${1#Merge pull request #} ;;
    'Merge PR #'*) n=${1#Merge PR #} ;;
    'Merge PR '*) n=${1#Merge PR } ;;
    *'(#'*')') n=${1##*\(#}; n=${n%\)} ;;
    *) return 1 ;;
  esac
  n=${n%%[^0-9]*}
  case $n in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

class_of_pr() { # <pr> -> keep, pending or failure
  case $KEEP_PRS in *"|$1|"*) printf 'keep\n'; return 0 ;; esac
  case $PENDING_PRS in *"|$1|"*) printf 'pending\n'; return 0 ;; esac
  return 1
}

load_proof() {
  KEEP_PRS='|'
  PENDING_PRS='|'
  PENDING_PR_BEADS='|'
  [ -n "$PROOF" ] || return 0
  [ -f "$PROOF" ] || die "proof file not found: $PROOF"
  local line pr bead extra
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|\#*) continue ;;
    esac
    bead='' extra=''
    case $line in
      'pr: '*)
        read -r pr extra <<< "${line#pr: }"
        [ -z "$extra" ] || die "proof line is not 'pr: <number>': $line"
        ;;
      'pending-pr: '*)
        read -r pr bead extra <<< "${line#pending-pr: }"
        if [ -n "$extra" ] || ! printf '%s\n' "$bead" | grep -Eq '^[A-Za-z0-9._-]+$'; then
          die "pending-pr line is not '<number> <bead>': $line"
        fi
        ;;
      *) die "proof line is not a PR entry: $line" ;;
    esac
    printf '%s\n' "$pr" | grep -Eq '^[0-9]+$' || die "proof line is not a PR number: $line"
    case "|$KEEP_PRS$PENDING_PRS" in *"|$pr|"*) die "duplicate proof entry for PR $pr" ;; esac
    if [ -n "$bead" ]; then
      PENDING_PRS="${PENDING_PRS}${pr}|"
      PENDING_PR_BEADS="${PENDING_PR_BEADS}${pr}=${bead}|"
    else
      KEEP_PRS="${KEEP_PRS}${pr}|"
    fi
  done < "$PROOF"
}

classify_commits() {
  # Build KEEP_SHAS / PENDING_SHA_BEADS for every commit in base..fork from
  # its first-parent PR; carried commits inherit the carrying PR's class.
  # SEEN_PRS collects every first-parent PR number, for the unmatched lines.
  KEEP_SHAS='|'
  PENDING_SHA_BEADS='|'
  SEEN_PRS='|'
  git -C "$REPO" log --first-parent --reverse --format='%H %s' "$base..$fork" > "$CHECK_TMP/fp" || die "cannot list first-parent commits"
  local sha subject pr cls parent carried merged bead line
  while read -r line; do
    sha=${line%% *}
    subject=${line#* }
    pr=$(pr_number "$subject") || continue
    SEEN_PRS="${SEEN_PRS}${pr}|"
    cls=$(class_of_pr "$pr") || continue
    if [ "$cls" = pending ]; then
      bead=${PENDING_PR_BEADS#*"|$pr="}; bead=${bead%%|*}
      PENDING_SHA_BEADS="${PENDING_SHA_BEADS}${sha}=${bead}|"
    else
      KEEP_SHAS="${KEEP_SHAS}${sha}|"
    fi
    parent=$(git -C "$REPO" rev-list --parents -n 1 "$sha") || die "cannot read parents of $sha"
    # shellcheck disable=SC2086
    set -- $parent
    [ $# -gt 2 ] || continue
    carried=$(git -C "$REPO" rev-list "$sha" "^$2" "^$base") || die "cannot read the commits merged by $sha"
    while read -r merged; do
      [ "$merged" = "$sha" ] && continue
      case $KEEP_SHAS in *"|$merged|"*) continue ;; esac
      case $PENDING_SHA_BEADS in *"|$merged="*) continue ;; esac
      if [ "$cls" = pending ]; then
        PENDING_SHA_BEADS="${PENDING_SHA_BEADS}${merged}=${bead}|"
      else
        KEEP_SHAS="${KEEP_SHAS}${merged}|"
      fi
    done <<< "$carried"
  done < "$CHECK_TMP/fp"
}

replay_proof() {
  EXPECTED_TREE=$(git -C "$REPO" rev-parse "${base}^{tree}") || die "cannot read the merge-base tree"
  classify_commits
  local sha parent _rest line
  while read -r line; do
    sha=${line%% *}
    case $KEEP_SHAS in *"|$sha|"*) ;; *) case $PENDING_SHA_BEADS in *"|$sha="*) ;; *) continue ;; esac ;; esac
    parent=$(git -C "$REPO" rev-parse "$sha^") || die "cannot read proof parent: $sha"
    EXPECTED_TREE=$(git -C "$REPO" merge-tree --write-tree --no-messages --merge-base="$parent" "$EXPECTED_TREE" "$sha") || die "proof patch conflicts without unproven changes: $sha"
  done < "$CHECK_TMP/fp"
}

int_in_range() { # <value> <max>
  case $1 in
    [0-9]|[1-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le "$2" ]
}

agent_dir() {
  if [ -n "${FM_DRIFT_AGENT_DIR:-}" ]; then
    printf '%s\n' "$FM_DRIFT_AGENT_DIR"
  else
    printf '%s\n' "${HOME:?HOME is unset}/Library/LaunchAgents"
  fi
}

default_log() {
  printf '%s\n' "${HOME:?HOME is unset}/Library/Logs/$LABEL.log"
}

launchctl_bin() {
  if [ -n "${FM_DRIFT_LAUNCHCTL:-}" ]; then
    printf '%s\n' "$FM_DRIFT_LAUNCHCTL"
  else
    printf '%s\n' launchctl
  fi
}

xml_escape() { # <var> <value>
  # Backslash-quoted & stays literal under Bash 5.2's patsub_replacement.
  local s=$2
  s=${s//\&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//\"/\&quot;}
  s=${s//\'/\&apos;}
  printf -v "$1" '%s' "$s"
}

write_plist() { # <path> <repo> <log> <hour> <minute>
  local label script repo log
  xml_escape label "$LABEL"
  xml_escape script "$SCRIPT_PATH"
  xml_escape repo "$2"
  xml_escape log "$3"
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$script</string>
    <string>nightly</string>
    <string>--repo</string>
    <string>$repo</string>
    <string>--log</string>
    <string>$log</string>
  </array>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$4</integer>
    <key>Minute</key>
    <integer>$5</integer>
  </dict>
</dict>
</plist>
EOF
}

cmd_help() {
  cat <<EOF
Usage:
  fm-drift-nightly.sh check [--repo <dir>] [--fork <ref>] [--upstream <ref>] [--proof <file>] [--no-fetch]
  fm-drift-nightly.sh nightly [--repo <dir>] [--log <file>]
  fm-drift-nightly.sh install [--dry-run] [--hour <0-23>] [--minute <0-59>] [--repo <dir>] [--log <file>]
  fm-drift-nightly.sh uninstall [--dry-run]
  fm-drift-nightly.sh --help
EOF
}

cmd_check() {
  local repo=$DEFAULT_REPO fork=HEAD upstream=kunchenguid/main proof='' no_fetch=0
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --fork) [ $# -ge 2 ] || die "--fork needs a ref"; fork=$2; shift 2 ;;
      --upstream) [ $# -ge 2 ] || die "--upstream needs a ref"; upstream=$2; shift 2 ;;
      --proof) [ $# -ge 2 ] || die "--proof needs a file"; proof=$2; shift 2 ;;
      --no-fetch) no_fetch=1; shift ;;
      *) die "unknown check argument: $1" ;;
    esac
  done
  REPO=$repo
  PROOF=$proof
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO"
  if [ "$no_fetch" -eq 0 ]; then
    git -C "$REPO" remote get-url kunchenguid >/dev/null 2>&1 || die "kunchenguid remote is missing"
    git -C "$REPO" fetch --no-tags kunchenguid main || die "git fetch kunchenguid main failed"
  fi
  local fork_sha upstream_sha
  fork_sha=$(git -C "$REPO" rev-parse --verify "${fork}^{commit}" 2>/dev/null) || die "fork ref not found: $fork"
  upstream_sha=$(git -C "$REPO" rev-parse --verify "${upstream}^{commit}" 2>/dev/null) || die "upstream ref not found: $upstream"
  fork=$fork_sha
  upstream=$upstream_sha
  CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift.XXXXXX") || die "cannot create a temporary directory"
  trap 'rm -f -- "$CHECK_TMP/proof" "$CHECK_TMP/paths" "$CHECK_TMP/commits" "$CHECK_TMP/fp"; rmdir -- "$CHECK_TMP"' EXIT
  if [ -z "$PROOF" ] && git -C "$REPO" cat-file -e "$fork:drift-proof.txt" 2>/dev/null; then
    git -C "$REPO" cat-file blob "$fork:drift-proof.txt" > "$CHECK_TMP/proof" || die "cannot read drift-proof.txt from $fork"
    PROOF=$CHECK_TMP/proof
  fi
  local base behind ahead path sha subject parents bead pr drift=0
  base=$(git -C "$REPO" merge-base "$fork" "$upstream") || die "no merge-base for $fork and $upstream"
  behind=$(git -C "$REPO" rev-list --count "$fork..$upstream") || die "behind count failed"
  ahead=$(git -C "$REPO" rev-list --count "$upstream..$fork") || die "ahead count failed"
  load_proof
  replay_proof
  git -C "$REPO" diff --no-renames --name-only -z "$base" "$fork" > "$CHECK_TMP/paths" || die "cannot read fork paths"
  printf 'behind: %s\n' "$behind"
  printf 'ahead: %s\n' "$ahead"
  while IFS= read -r -d '' path; do
    if git --literal-pathspecs -C "$REPO" diff --no-renames --quiet "$EXPECTED_TREE" "$fork" -- "$path"; then
      printf 'path-ok: %s\n' "$path"
    fi
  done < "$CHECK_TMP/paths"
  git -C "$REPO" diff --no-renames --name-only -z "$EXPECTED_TREE" "$fork" > "$CHECK_TMP/paths" || die "cannot read drift paths"
  [ ! -s "$CHECK_TMP/paths" ] || drift=1
  while IFS= read -r -d '' path; do
    printf 'path-drift: %s\n' "$path"
  done < "$CHECK_TMP/paths"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    subject=$(git -C "$REPO" log -1 --format=%s "$sha") || die "cannot read $sha"
    parents=$(git -C "$REPO" rev-list --parents -n 1 "$sha") || die "cannot read parents of $sha"
    # shellcheck disable=SC2086
    set -- $parents
    if bead=$(pending_bead "$sha"); then
      printf 'pending: %s %s %s\n' "$sha" "$bead" "$subject"
    elif [ $# -gt 2 ] && ! proof_has "$sha"; then
      printf 'merge: %s %s\n' "$sha" "$subject"
    elif proof_has "$sha"; then
      printf 'keep: %s %s\n' "$sha" "$subject"
    else
      printf 'unproven: %s %s\n' "$sha" "$subject"
    fi
  done < <(git -C "$REPO" rev-list "$upstream..$fork")
  for pr in $(printf '%s' "$SEEN_PRS" | tr '|' ' '); do
    if ! class_of_pr "$pr" >/dev/null; then
      printf 'error: missing manifest entry for PR %s\n' "$pr"
      drift=1
    fi
  done
  for pr in $(printf '%s' "$KEEP_PRS$PENDING_PRS" | tr '|' ' '); do
    case $SEEN_PRS in *"|$pr|"*) ;; *) printf 'unmatched: %s\n' "$pr" ;; esac
  done
  [ "$drift" -eq 0 ]
}

cmd_nightly() {
  local repo=$DEFAULT_REPO log='' day out rc red
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) [ $# -ge 2 ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || die "--log needs a file"; log=$2; shift 2 ;;
      *) die "unknown nightly argument: $1" ;;
    esac
  done
  [ -n "$log" ] || log=$(default_log)
  require_absolute_log "$log"
  day=$(date +%F)
  printf 'run: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  rc=0
  out=$(cmd_check --repo "$repo" 2>&1) || rc=$?
  printf '%s\n' "$out"
  printf 'exit: %s\n' "$rc"
  [ "$rc" -ne 0 ] || return 0
  red=$(printf '%s\n' "$out" | awk '/^(path-drift|error): / { if (++n <= 10) print } END { if (n > 10) printf "%d more red lines in the log.\n", n - 10 }')
  {
    printf 'Nightly drift check red on %s: exit %s for %s.\n' "$day" "$rc" "$repo"
    [ -z "$red" ] || printf '%s\n' "$red"
    printf 'Log: %s\n' "$log"
  } | "$SCRIPT_DIR/fm-inbox.sh" note --request-id "fm-drift-nightly-$day" - ||
    printf 'error: fm-inbox.sh note failed with exit %s\n' "$?" >&2
  return "$rc"
}

require_absolute_log() {
  case $1 in
    /*) ;;
    *) die "--log must be an absolute path" ;;
  esac
}

cmd_install() {
  local dry=0 hour=3 minute=17 repo=$DEFAULT_REPO log=''
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      --hour) [ $# -ge 2 ] || die "--hour needs a number"; hour=$2; shift 2 ;;
      --minute) [ $# -ge 2 ] || die "--minute needs a number"; minute=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || die "--log needs a file"; log=$2; shift 2 ;;
      *) die "unknown install argument: $1" ;;
    esac
  done
  int_in_range "$hour" 23 || die "--hour must be 0 through 23"
  int_in_range "$minute" 59 || die "--minute must be 0 through 59"
  [ -n "$log" ] || log=$(default_log)
  require_absolute_log "$log"
  local dir plist next lint uid bin
  dir=$(agent_dir)
  plist=$dir/$LABEL.plist
  next=$plist.new
  uid=$(id -u)
  if [ "$dry" -eq 1 ]; then
    printf 'dry-run: install\n'
    printf 'label: %s\n' "$LABEL"
    printf 'hour: %s\n' "$hour"
    printf 'minute: %s\n' "$minute"
    printf 'plist: %s\n' "$plist"
    printf 'repo: %s\n' "$repo"
    printf 'log: %s\n' "$log"
    return 0
  fi
  mkdir -p -- "$dir" || die "cannot create $dir"
  if ! write_plist "$next" "$repo" "$log" "$hour" "$minute"; then
    rm -f -- "$next"
    die "cannot write $next"
  fi
  if ! lint=$(plutil -lint "$next" 2>&1); then
    rm -f -- "$next"
    die "plutil -lint rejected the new plist, installed job unchanged: $lint"
  fi
  if ! mkdir -p -- "$(dirname -- "$log")"; then
    rm -f -- "$next"
    die "cannot create the log directory for $log, installed job unchanged"
  fi
  mv -f -- "$next" "$plist" || die "cannot replace $plist"
  bin=$(launchctl_bin)
  "$bin" bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  "$bin" bootstrap "gui/$uid" "$plist" || die "launchctl bootstrap gui/$uid failed"
  printf 'installed: %s\n' "$plist"
}

cmd_uninstall() {
  local dry=0
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      *) die "unknown uninstall argument: $1" ;;
    esac
  done
  local dir plist uid bin rc
  dir=$(agent_dir)
  plist=$dir/$LABEL.plist
  uid=$(id -u)
  if [ "$dry" -eq 1 ]; then
    printf 'dry-run: uninstall\n'
    if [ -f "$plist" ]; then
      printf 'bootout: gui/%s/%s\n' "$uid" "$LABEL"
      printf 'plist: %s\n' "$plist"
    else
      printf 'absent: %s\n' "$plist"
    fi
    return 0
  fi
  if [ ! -f "$plist" ]; then
    printf 'uninstalled: absent\n'
    return 0
  fi
  bin=$(launchctl_bin)
  rc=0
  "$bin" bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || rc=$?
  # launchctl bootout exits 3 (no such process) when the job is not loaded.
  case $rc in
    0 | 3) ;;
    *) die "launchctl bootout gui/$uid/$LABEL failed with exit $rc; kept $plist" ;;
  esac
  rm -f -- "$plist" || die "cannot remove $plist"
  printf 'uninstalled: removed\n'
}

main() {
  local cmd=${1:-check}
  case $cmd in
    -h|--help|help) cmd_help ;;
    check) shift; cmd_check "$@" ;;
    nightly) shift; cmd_nightly "$@" ;;
    install) shift; cmd_install "$@" ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
