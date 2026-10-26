#!/usr/bin/env bash
# Claude turn record writer.
#
# Registered in tracked .claude/settings.json for UserPromptSubmit (writes
# busy), for Stop and StopFailure (write idle), and as a synchronous
# SessionStart entry. StopFailure matters because an API error such as a
# full context fires it instead of Stop. A session open with source clear,
# startup, or resume proves no turn is running, so it writes idle before any
# turn can start; a compact can happen mid-turn, so it writes nothing.
# It records state/.claude-turn as one atomically replaced line:
#   <busy|idle> <turn-start-epoch> <claude-pid> <session-id>
# Only the session that holds the fleet lock writes, and the pid is the lock
# pid. The session id comes from the payload, or is '-' when absent.
# bin/fm-wake-lib.sh owns the record contract and its readers.
# The idle write keeps the busy write's turn-start epoch, so a rewake
# committed mid-turn stays pending until a newer turn starts. A turn Claude
# started itself (its prompt opens with <task-notification>, the wrapper
# around a rewake) records an epoch after the ledger's latest rewake commit,
# so a rewake's own turn always orders after that rewake.
# Always exits 0: a turn-record failure must never block a turn.
set -u

[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
[ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
case "$EVENT" in
  UserPromptSubmit) NEW_STATE=busy ;;
  Stop|StopFailure) NEW_STATE=idle ;;
  SessionStart)
    case "$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null || true)" in
      clear|startup|resume) NEW_STATE=idle ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

fm_session_lock_owned_by_self "$STATE" || exit 0
CLAUDE_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
case "$CLAUDE_PID" in ''|*[!0-9]*) exit 0 ;; esac

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=- ;; esac

EPOCH=$(date +%s)
if [ "$NEW_STATE" = idle ]; then
  if fm_claude_turn_read "$STATE" \
    && [ "$FM_CLAUDE_TURN_PID" = "$CLAUDE_PID" ] \
    && [ "$FM_CLAUDE_TURN_SESSION" = "$SESSION_ID" ]; then
    EPOCH=$FM_CLAUDE_TURN_EPOCH
  fi
elif printf '%s' "$PAYLOAD" | jq -e '(.prompt // "") | type == "string" and test("^\\s*<task-notification>")' >/dev/null 2>&1 \
  && fm_autoarm_ledger_read "$STATE" && [ "$FM_AUTOARM_OUTCOME" = rewake ]; then
  REWAKE_AT=$(_fm_autoarm_epoch_field "$STATE/.claude-autoarm-epoch" updated_at 2>/dev/null || true)
  case "$REWAKE_AT" in
    ''|*[!0-9]*) ;;
    *) [ "$REWAKE_AT" -lt "$EPOCH" ] || EPOCH=$((REWAKE_AT + 1)) ;;
  esac
fi

TMP="$STATE/.claude-turn.tmp.$$"
if printf '%s %s %s %s\n' "$NEW_STATE" "$EPOCH" "$CLAUDE_PID" "$SESSION_ID" > "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$STATE/.claude-turn" 2>/dev/null; then
  exit 0
fi
rm -f "$TMP" 2>/dev/null || true
exit 0
