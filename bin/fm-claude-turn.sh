#!/usr/bin/env bash
# Claude turn record writer.
#
# Registered in tracked .claude/settings.json for UserPromptSubmit (writes
# busy) and for Stop and StopFailure (write idle). StopFailure matters
# because an API error such as a full context fires it instead of Stop.
# It records state/.claude-turn as one atomically replaced line:
#   <busy|idle> <turn-start-epoch> <claude-pid> <session-id>
# bin/fm-wake-lib.sh owns the record contract and its readers.
# The idle write keeps the busy write's turn-start epoch, so a rewake
# committed mid-turn stays pending until a newer turn starts.
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
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

EVENT=
SESSION_ID=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)
fi
[ -n "$SESSION_ID" ] || SESSION_ID=${CLAUDE_CODE_SESSION_ID:-}
[ -n "$SESSION_ID" ] || SESSION_ID=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
[ -n "$SESSION_ID" ] || SESSION_ID=-
case "$SESSION_ID" in *[!A-Za-z0-9._-]*) SESSION_ID=- ;; esac

case "$EVENT" in
  UserPromptSubmit|busy) NEW_STATE=busy ;;
  Stop|StopFailure|idle) NEW_STATE=idle ;;
  *) exit 0 ;;
esac

ENV_CLAUDE_PID=${CLAUDE_PID:-}
CLAUDE_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
case "$CLAUDE_PID" in
  ''|*[!0-9]*) CLAUDE_PID=$ENV_CLAUDE_PID ;;
esac
case "$CLAUDE_PID" in ''|*[!0-9]*) exit 0 ;; esac

EPOCH=$(date +%s)
if [ "$NEW_STATE" = idle ] && fm_claude_turn_read "$STATE" \
  && [ "$FM_CLAUDE_TURN_PID" = "$CLAUDE_PID" ] \
  && [ "$FM_CLAUDE_TURN_SESSION" = "$SESSION_ID" ]; then
  EPOCH=$FM_CLAUDE_TURN_EPOCH
fi

TMP="$STATE/.claude-turn.tmp.$$"
if printf '%s %s %s %s\n' "$NEW_STATE" "$EPOCH" "$CLAUDE_PID" "$SESSION_ID" > "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$STATE/.claude-turn" 2>/dev/null; then
  exit 0
fi
rm -f "$TMP" 2>/dev/null || true
exit 0
