#!/usr/bin/env bash
# fm-drift-nightly.sh - compare a fork to kunchenguid/firstmate main.
#
# Usage:
#   fm-drift-nightly.sh check [--repo <dir>] [--fork <ref>] [--upstream <ref>] [--proof <file>] [--no-fetch]
#   fm-drift-nightly.sh install [--dry-run] [--hour <0-23>] [--minute <0-59>] [--repo <dir>]
#   fm-drift-nightly.sh uninstall [--dry-run]
#   fm-drift-nightly.sh --help
#
# check prints behind and ahead counts, then one line per path in the diff
# from the merge-base to the fork ref, then one line per commit reachable from
# the fork ref and not from the upstream ref.
# A path is path-ok when it is one of this guard's own files or a file a proof
# commit changes. Every other path is path-drift.
# A commit is keep when its full sha is in the proof file, merge when it has
# two parents, and unproven otherwise.
# Exit 0 when no path-drift line is printed, 1 when one is, and 2 on usage or
# git failure. behind is reported and does not change the exit code.
# A path owned by a proof commit is allowed in full, so a later edit on that
# same path is not a separate finding.
#
# The proof file holds one full 40-hex sha per line. Blank lines and lines
# whose first character is # are ignored. Any other line is an error.
# When --proof is omitted and <repo>/drift-proof.txt exists, that file is the
# proof file. When it does not exist, no commit is proven.
#
# With fetch left on, check runs git fetch --no-tags kunchenguid main when
# that remote exists in the repo. --no-fetch skips that. A missing remote
# with fetch left on is an error.
#
# install writes ~/Library/LaunchAgents/dev.firstmate.drift-nightly.plist and
# bootstraps the job for the current user. The job runs check once a night.
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

guard_path() {
  case $1 in
    bin/fm-drift-nightly.sh|tests/fm-drift-nightly.test.sh|docs/scripts.md|drift-proof.txt) return 0 ;;
    *) return 1 ;;
  esac
}

proof_has() {
  case $PROOF_SHAS in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

load_proof() {
  PROOF_SHAS='|'
  PROOF_PATHS='|'
  [ -n "$PROOF" ] || return 0
  [ -f "$PROOF" ] || die "proof file not found: $PROOF"
  local line sha path
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|\#*) continue ;;
    esac
    printf '%s\n' "$line" | grep -Eq '^[0-9a-f]{40}$' || die "proof line is not a full sha: $line"
    PROOF_SHAS="${PROOF_SHAS}${line}|"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      PROOF_PATHS="${PROOF_PATHS}${path}|"
    done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$line" 2>/dev/null || true)
  done < "$PROOF"
}

path_ok() {
  guard_path "$1" && return 0
  case $PROOF_PATHS in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
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
  git -C "$REPO" rev-parse --verify "${fork}^{commit}" >/dev/null 2>&1 || die "fork ref not found: $fork"
  git -C "$REPO" rev-parse --verify "${upstream}^{commit}" >/dev/null 2>&1 || die "upstream ref not found: $upstream"
  if [ -z "$PROOF" ] && [ -f "$REPO/drift-proof.txt" ]; then
    PROOF=$REPO/drift-proof.txt
  fi
  load_proof
  local base behind ahead path sha subject parents drift=0
  base=$(git -C "$REPO" merge-base "$fork" "$upstream") || die "no merge-base for $fork and $upstream"
  behind=$(git -C "$REPO" rev-list --count "$fork..$upstream") || die "behind count failed"
  ahead=$(git -C "$REPO" rev-list --count "$upstream..$fork") || die "ahead count failed"
  printf 'behind: %s\n' "$behind"
  printf 'ahead: %s\n' "$ahead"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if path_ok "$path"; then
      printf 'path-ok: %s\n' "$path"
    else
      printf 'path-drift: %s\n' "$path"
      drift=1
    fi
  done < <(git -C "$REPO" diff --name-only "$base" "$fork" | LC_ALL=C sort)
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
