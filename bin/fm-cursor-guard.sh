#!/usr/bin/env bash
# fm-cursor-guard.sh - guards around a Cursor code worker. No model judgment.
#   fallback <id>      prints "cursor", "codex <reason>" or "claude <reason>".
#                      Codex when the shared Cursor/Grok pool is short or unknown: the newest
#                      <usage dir>/*-spending.txt says cursor_models_pct >= the crew-dispatch.json
#                      cursor_fallback.models_pct (default 85), or there is no readable file, or
#                      it is older than max_age_h (default 26) by mtime. Bare Grok draws the same
#                      pool, so it is no fallback there. Claude instead of Codex when the bead's
#                      last Codex run hit a usage limit (state/<id>.codex-limit).
# Overrides for tests: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CURSOR_USAGE_DIR.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
USAGE="${FM_CURSOR_USAGE_DIR:-$HOME/.agent-state/a3ov3/cursor-usage}"
op=${1:-}; id=${2:-}
[ "$op" = fallback ] && [ -n "$id" ] || { echo "usage: fm-cursor-guard.sh fallback <bead-id>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cursor guard: jq required" >&2; exit 1; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

pct_max=85; age_max=26
if [ -r "$CONFIG/crew-dispatch.json" ]; then
  pct_max=$(jq -r '.cursor_fallback.models_pct // 85' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 85)
  age_max=$(jq -r '.cursor_fallback.max_age_h // 26' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 26)
fi
pool() {
  if [ -s "$STATE/$id.codex-limit" ]; then echo "claude $1; $(head -1 "$STATE/$id.codex-limit")"; else echo "codex $1"; fi
}
# shellcheck disable=SC2012
f=$(ls -t "$USAGE"/*-spending.txt 2>/dev/null | head -1)
if [ -z "$f" ] || [ ! -r "$f" ]; then pool "no Cursor spending file in $USAGE"; exit 0; fi
age=$(( $(date +%s) - $(mtime "$f") ))
if [ "$age" -gt $(( age_max * 3600 )) ]; then pool "newest Cursor spending file is $((age / 3600)) h old (limit $age_max h)"; exit 0; fi
pct=$(sed -n 's/^cursor_models_pct=//p' "$f" | tail -1)
case "$pct" in '' | *[!0-9]*) pool "cursor_models_pct missing or not an integer in $(basename "$f")"; exit 0 ;; esac
if [ "$pct" -ge "$pct_max" ]; then pool "Cursor Models at ${pct}% (limit ${pct_max}%)"; exit 0; fi
echo cursor
