#!/usr/bin/env bash
# Claude waker: wake an idle primary that holds an unread wake record and
# has no running Stop hook to deliver it.
#
# Registered in tracked .claude/settings.json for FileChanged with
# "asyncRewake": true and a short timeout, and as a second SessionStart
# entry with "asyncRewake": true. A third, synchronous SessionStart entry
# runs this script with --print-watch-paths and prints only the watchPaths
# JSON for the effective state directory; the digest entry prints plain
# text, so the watch path cannot ride on it.
#
# Exit 2 only when every condition holds: a complete unread record for
# main (fm_wake_main_unread, scope any), the turn record reads idle, no
# live open Stop-hook claim exists (a parked hook delivers), and no rewake
# is already pending. The commit goes through the generation ledger
# (fm_autoarm_claim_next against the generation read before those checks,
# then a rewake outcome), so concurrent waker and Stop firings stay
# single-flight and a waker never supersedes an entry written after it
# decided. At a session open that runs the digest (any source but resume,
# reload, or fork) it first waits, bounded by FM_CLAUDE_WAKE_SESSION_WAIT
# (default 180, the digest's own budget), until state/.session-start-complete
# is rewritten after this waker started and names the current lock pid, then
# evaluates once. Every other path exits 0 silently.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "${1:-}" = --print-watch-paths ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","watchPaths":["%s/.wake-queue"]}}\n' "$STATE"
  exit 0
fi
if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      printf 'Usage: fm-claude-wake.sh [--print-watch-paths]\n'
      printf 'Claude FileChanged and SessionStart asyncRewake hook; reads its payload on stdin.\n'
      exit 0
      ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
fi

[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

EVENT=
SOURCE=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
  SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null || true)
fi

# "<inode> <pid>" of the completion marker, or nothing. The digest replaces
# the marker by rename when it finishes, so a changed inode or pid is a
# completion written after this waker started.
session_start_marker() {
  local file="$STATE/.session-start-complete" inode pid
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  read -r inode _ <<EOF
$(ls -di "$file" 2>/dev/null)
EOF
  IFS= read -r pid < "$file" 2>/dev/null || pid=
  printf '%s %s\n' "$inode" "$pid"
}

if [ "$EVENT" = SessionStart ]; then
  case "$SOURCE" in
    resume|reload|fork) ;;
    *)
      MARKER_BEFORE=$(session_start_marker)
      WAIT=${FM_CLAUDE_WAKE_SESSION_WAIT:-180}
      case "$WAIT" in ''|*[!0-9]*) WAIT=180 ;; esac
      deadline=$((SECONDS + WAIT))
      while :; do
        marker=$(session_start_marker)
        lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
        if [ -n "$marker" ] && [ "$marker" != "$MARKER_BEFORE" ] \
          && [ -n "$lock_pid" ] && [ "${marker#* }" = "$lock_pid" ]; then
          break
        fi
        [ "$SECONDS" -lt "$deadline" ] || exit 0
        sleep 0.2
      done
      ;;
  esac
fi

fm_session_lock_owned_by_self "$STATE" || exit 0
[ -e "$STATE/.afk" ] && exit 0

LOCK_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in ''|*[!0-9]*) exit 0 ;; esac
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

fm_autoarm_ledger_read "$STATE" 2>/dev/null || true
PREV_GEN=${FM_AUTOARM_GEN:-0}
case "$PREV_GEN" in ''|*[!0-9]*) PREV_GEN=0 ;; esac

rows=$(fm_wake_main_unread "$STATE" any) || exit 0
[ -n "$rows" ] || exit 0
fm_claude_turn_idle "$STATE" "$LOCK_PID" || exit 0
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_claude_rewake_pending "$STATE" && exit 0

CLAIM_RC=1
tries=0
while [ "$tries" -lt 5 ]; do
  fm_autoarm_claim_next "$STATE" "$GRACE" "$PREV_GEN"
  CLAIM_RC=$?
  [ "$CLAIM_RC" -ne 1 ] && break
  tries=$((tries + 1))
  sleep 0.2
done
[ "$CLAIM_RC" -eq 0 ] || exit 0
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

rows=$(fm_wake_main_unread "$STATE" any) || exit 0
[ -n "$rows" ] || exit 0
fm_claude_turn_idle "$STATE" "$LOCK_PID" || exit 0

if ! fm_autoarm_write_owned "$STATE" "$MY_GEN" rewake "" "$LOCK_PID"; then
  exit 0
fi
{
  printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
  printf '%s\n' "$rows" | head -8
  printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
} >&2
exit 2
