#!/usr/bin/env bash
# fm-drift-nightly.sh - compare a fork to kunchenguid/firstmate main.
#
# Usage:
#   fm-drift-nightly.sh check [--repo <dir>] [--fork <ref>] [--upstream <ref>] [--proof <file>] [--no-fetch]
#   fm-drift-nightly.sh install [--dry-run] [--hour <0-23>] [--minute <0-59>] [--repo <dir>]
#   fm-drift-nightly.sh uninstall [--dry-run]
#   fm-drift-nightly.sh --help
#
# check defaults to fork HEAD and upstream kunchenguid/main. After the optional
# fetch, both refs resolve to fixed commit SHAs used for the entire check and
# report; later ref changes belong to the next run. Only committed trees are
# compared, not working-tree or staged changes.
# check prints behind and ahead counts, path-ok for changed paths that match
# the accepted tree, path-drift for every mismatch with that tree, then one
# line per commit reachable from the captured fork and not captured upstream.
# Proof patches are replayed from the merge-base in ancestry order using
# git merge-tree with each proof commit's parent as its patch base. A path is
# path-ok only when its fork content and mode match the resulting tree.
# Missing proven changes and extra changes are path-drift. Rename detection
# is disabled so a deletion cannot disappear into a rename onto a proven file.
# No file is exempt, including the guard and proof files.
# A commit is merge when it has multiple parents, keep when it is selected
# by the proof file and is not a merge, and unproven otherwise.
# Exit 0 when no path-drift line is printed, 1 when one is, and 2 on usage or
# git failure. behind is reported and does not change the exit code.
#
# The proof file holds one full 40-hex sha per line, or "after: <full sha>"
# to select the unique reachable commit whose first parent is that sha.
# This lets a manifest name its own finalized patch before its commit SHA
# exists, without approving later descendants. Missing or multiple direct
# children are errors. Selection uses only the captured fork snapshot.
# Blank lines and lines whose first character is # are ignored.
# Listed commits must exist and be reachable from the fork ref.
# When --proof is omitted and <repo>/drift-proof.txt exists, that file is the
# proof file. When it does not exist, no commit is proven.
#
# With fetch left on, check runs git fetch --no-tags kunchenguid main when
# that remote exists in the repo. --no-fetch skips that. A missing remote
# with fetch left on is an error.
#
# install writes ~/Library/LaunchAgents/dev.firstmate.drift-nightly.plist and
# bootstraps the job for the current user. The job runs check once a night,
# defaulting to 03:17 in the machine's local time. It passes only --repo, so
# the installed job uses the default refs, fetch, and repository proof file;
# alternate check options are not persisted by install.
# uninstall bootstraps nothing, removes that job, and deletes the plist.
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
  case $PROOF_SHAS in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

proof_successor() {
  local history sha parent _parents selected=''
  history=$(git -C "$REPO" rev-list --ancestry-path --parents "$1..$fork") || die "cannot read proof descendants: $1"
  while read -r sha parent _parents; do
    [ "$parent" = "$1" ] || continue
    [ -z "$selected" ] || die "proof parent has multiple direct children: $1"
    selected=$sha
  done <<< "$history"
  [ -n "$selected" ] || die "proof parent has no direct child: $1"
  printf '%s\n' "$selected"
}

load_proof() {
  PROOF_SHAS='|'
  [ -n "$PROOF" ] || return 0
  [ -f "$PROOF" ] || die "proof file not found: $PROOF"
  local line sha
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|\#*) continue ;;
    esac
    sha=${line#after: }
    printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "proof line is not a full sha: $line"
    git -C "$REPO" rev-parse --verify "${sha}^{commit}" >/dev/null 2>&1 || die "proof commit not found: $sha"
    git -C "$REPO" merge-base --is-ancestor "$sha" "$fork" || die "proof commit is not reachable from fork: $sha"
    if [ "$sha" != "$line" ]; then
      sha=$(proof_successor "$sha") || exit 2
    fi
    PROOF_SHAS="${PROOF_SHAS}${sha}|"
  done < "$PROOF"
}

replay_proof() {
  local sha parent
  EXPECTED_TREE=$(git -C "$REPO" rev-parse "${base}^{tree}") || die "cannot read the merge-base tree"
  git -C "$REPO" rev-list --reverse --topo-order "$base..$fork" > "$CHECK_TMP/commits" || die "cannot order fork commits"
  while IFS= read -r sha; do
    proof_has "$sha" || continue
    parent=$(git -C "$REPO" rev-parse "${sha}^1") || die "cannot read proof parent: $sha"
    EXPECTED_TREE=$(git -C "$REPO" merge-tree --write-tree --no-messages --merge-base="$parent" "$EXPECTED_TREE" "$sha") || die "proof patch conflicts without unproven changes: $sha"
  done < "$CHECK_TMP/commits"
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

launchctl_bin() {
  if [ -n "${FM_DRIFT_LAUNCHCTL:-}" ]; then
    printf '%s\n' "$FM_DRIFT_LAUNCHCTL"
  else
    printf '%s\n' launchctl
  fi
}

write_plist() { # <path> <repo> <hour> <minute>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_PATH</string>
    <string>check</string>
    <string>--repo</string>
    <string>$2</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$3</integer>
    <key>Minute</key>
    <integer>$4</integer>
  </dict>
</dict>
</plist>
EOF
}

cmd_help() {
  cat <<EOF
Usage:
  fm-drift-nightly.sh check [--repo <dir>] [--fork <ref>] [--upstream <ref>] [--proof <file>] [--no-fetch]
  fm-drift-nightly.sh install [--dry-run] [--hour <0-23>] [--minute <0-59>] [--repo <dir>]
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
  if [ -z "$PROOF" ] && [ -f "$REPO/drift-proof.txt" ]; then
    PROOF=$REPO/drift-proof.txt
  fi
  local base behind ahead path sha subject parents drift=0
  base=$(git -C "$REPO" merge-base "$fork" "$upstream") || die "no merge-base for $fork and $upstream"
  behind=$(git -C "$REPO" rev-list --count "$fork..$upstream") || die "behind count failed"
  ahead=$(git -C "$REPO" rev-list --count "$upstream..$fork") || die "ahead count failed"
  load_proof
  CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift.XXXXXX") || die "cannot create a temporary directory"
  trap 'rm -f -- "$CHECK_TMP/paths" "$CHECK_TMP/commits"; rmdir -- "$CHECK_TMP"' EXIT
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
    if [ $# -gt 2 ]; then
      printf 'merge: %s %s\n' "$sha" "$subject"
    elif proof_has "$sha"; then
      printf 'keep: %s %s\n' "$sha" "$subject"
    else
      printf 'unproven: %s %s\n' "$sha" "$subject"
    fi
  done < <(git -C "$REPO" rev-list "$upstream..$fork")
  [ "$drift" -eq 0 ]
}

cmd_install() {
  local dry=0 hour=3 minute=17 repo=$DEFAULT_REPO
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      --hour) [ $# -ge 2 ] || die "--hour needs a number"; hour=$2; shift 2 ;;
      --minute) [ $# -ge 2 ] || die "--minute needs a number"; minute=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      *) die "unknown install argument: $1" ;;
    esac
  done
  int_in_range "$hour" 23 || die "--hour must be 0 through 23"
  int_in_range "$minute" 59 || die "--minute must be 0 through 59"
  local dir plist uid bin
  dir=$(agent_dir)
  plist=$dir/$LABEL.plist
  uid=$(id -u)
  if [ "$dry" -eq 1 ]; then
    printf 'dry-run: install\n'
    printf 'label: %s\n' "$LABEL"
    printf 'hour: %s\n' "$hour"
    printf 'minute: %s\n' "$minute"
    printf 'plist: %s\n' "$plist"
    printf 'repo: %s\n' "$repo"
    return 0
  fi
  mkdir -p -- "$dir" || die "cannot create $dir"
  write_plist "$plist" "$repo" "$hour" "$minute" || die "cannot write $plist"
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
  local dir plist uid bin
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
  "$bin" bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  if "$bin" print "gui/$uid/$LABEL" >/dev/null 2>&1; then
    die "launchctl bootout gui/$uid/$LABEL left the job loaded"
  fi
  rm -f -- "$plist" || die "cannot remove $plist"
  printf 'uninstalled: removed\n'
}

main() {
  local cmd=${1:-check}
  case $cmd in
    -h|--help|help) cmd_help ;;
    check) shift; cmd_check "$@" ;;
    install) shift; cmd_install "$@" ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
