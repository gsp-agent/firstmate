#!/usr/bin/env bash
# fm-cursor-guard.sh - guards around a Cursor code worker. No model judgment.
#   fallback <id>      prints "cursor", "codex <reason>", "claude <reason>" or "grok <reason>".
#                      Codex when the shared Cursor/Grok pool is short or unknown: the newest
#                      <usage dir>/*-spending.txt says cursor_models_pct >= the crew-dispatch.json
#                      cursor_fallback.models_pct (integer 1..100, default 85), or there is no readable file, or
#                      it is older than max_age_h (positive integer, default 26) by mtime, or the bead's last Cursor
#                      run hit a usage limit (state/<id>.cursor-limit). At pct >= the limit,
#                      credit room in the same file keeps Cursor (Dale 10-16) only when
#                      on_demand=enabled, a numeric monthly_additional_usage_used is below a
#                      numeric monthly_additional_usage_limit, and a numeric prepaid_balance is
#                      above 0; anything else, a missing or non-numeric value included, is no
#                      room and falls back. Bare Grok draws the same
#                      pool, so it is no fallback there. Claude instead of Codex when the bead's
#                      last Codex run hit a usage limit (state/<id>.codex-limit). Grok (bare CLI,
#                      grok-4.7 xhigh) only when the pstack plugin dir's plugin.json version is
#                      not pstack_version (0.15.21): a Cursor-only problem, the pool is fine.
#   take <id>          before a cursor launch; a bead's 3rd launch in one America/Chicago day is
#                      refused (exit 1, one stderr line). Counts in state/cursor-dispatch.json.
#   give <id>          give the launch back when the spawn failed.
#   after <id> <rc>    run in the pane after the agent exits; exits with <rc>. When rc is nonzero
#                      and state/<id>.cursor-stream.jsonl shows a usage-limit or 429 error, writes
#                      state/<id>.cursor-limit so the bead's next launch goes to codex.
# Overrides for tests: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CURSOR_USAGE_DIR, FM_CURSOR_DAY, FM_PSTACK_DIR.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
USAGE="${FM_CURSOR_USAGE_DIR:-$HOME/.agent-state/a3ov3/cursor-usage}"
op=${1:-}; id=${2:-}
case "$op" in take | give | fallback | after) ;; *) op= ;; esac
[ -n "$op" ] && [ -n "$id" ] || { echo "usage: fm-cursor-guard.sh take|give|fallback <bead-id> | after <bead-id> <rc>" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cursor guard: jq required" >&2; exit 1; }
mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

if [ "$op" = after ]; then
  rc=${3:-0}
  sleep 1  # let the tee in the pane command flush the stream
  S="$STATE/$id.cursor-stream.jsonl"
  if [ "$rc" != 0 ] && [ -r "$S" ] && grep -qiE 'usage limit|usage_limit|rate.?limit|\b429\b|out of usage|\bexceeded\b.*(quota|limit)' "$S"; then
    printf 'cursor run for %s exited %s on a usage-limit/429 error; next launch goes to codex\n' "$id" "$rc" > "$STATE/$id.cursor-limit"
    cat "$STATE/$id.cursor-limit" >&2
  fi
  exit "$rc"
fi

if [ "$op" = fallback ]; then
  pct_max=85; age_max=26
  if [ -r "$CONFIG/crew-dispatch.json" ]; then
    pct_max=$(jq -r '.cursor_fallback.models_pct // 85' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 85)
    age_max=$(jq -r '.cursor_fallback.max_age_h // 26' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 26)
  fi
  want=0.15.21
  [ ! -r "$CONFIG/crew-dispatch.json" ] || want=$(jq -r '.pstack_version // "0.15.21"' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 0.15.21)
  have=$(jq -r '.version // empty' "${FM_PSTACK_DIR:-$HOME/dev/pstack/pstack}/.cursor-plugin/plugin.json" 2>/dev/null)
  # The shared pool is short or unknown: Codex, or Claude when this bead's Codex run hit its limit.
  pool() {
    if [ -s "$STATE/$id.codex-limit" ]; then echo "claude $1; $(head -1 "$STATE/$id.codex-limit")"; else echo "codex $1"; fi
  }
  if [ -s "$STATE/$id.cursor-limit" ]; then pool "$(head -1 "$STATE/$id.cursor-limit")"; exit 0; fi
  f=
  for spending_file in "$USAGE"/*-spending.txt; do
    [ -e "$spending_file" ] || continue
    if [ -z "$f" ] || [ "$spending_file" -nt "$f" ]; then
      f=$spending_file
    fi
  done
  if [ -z "$f" ] || [ ! -r "$f" ]; then pool "no Cursor spending file in $USAGE"; exit 0; fi
  age=$(( $(date +%s) - $(mtime "$f") ))
  if [ "$age" -gt $(( age_max * 3600 )) ]; then pool "newest Cursor spending file is $((age / 3600)) h old (limit $age_max h)"; exit 0; fi
  pct=$(sed -n 's/^cursor_models_pct=//p' "$f" | tail -1)
  case "$pct" in '' | *[!0-9]*) pool "cursor_models_pct missing or not an integer in $(basename "$f")"; exit 0 ;; esac
  if [ "$pct" -ge "$pct_max" ]; then
    # Included usage is spent, but prepaid/on-demand credit room still carries
    # Cursor (Dale 10-16: Grok/Cursor keep running on credits while they last).
    # A missing or non-numeric value is unknown room, never zero use.
    num='^[0-9]+([.][0-9]+)?$'
    on_demand=$(sed -n 's/^on_demand=//p' "$f" | tail -1)
    prepaid=$(sed -n 's/^prepaid_balance=//p' "$f" | tail -1)
    add_used=$(sed -n 's/^monthly_additional_usage_used=//p' "$f" | tail -1)
    add_limit=$(sed -n 's/^monthly_additional_usage_limit=//p' "$f" | tail -1)
    if ! { [ "$on_demand" = enabled ] && [[ $prepaid =~ $num && $add_used =~ $num && $add_limit =~ $num ]] \
      && awk -v p="$prepaid" -v u="$add_used" -v l="$add_limit" 'BEGIN { exit !(p + 0 > 0 && u + 0 < l + 0) }'; }; then
      pool "Cursor Models at ${pct}% (limit ${pct_max}%) and no prepaid/on-demand credit room in $(basename "$f")"; exit 0
    fi
  fi
  # Only once the pool is fine: an off-pin pstack is a Cursor-only problem.
  if [ "$have" != "$want" ]; then echo "grok pstack plugin version is '${have:-unreadable}', not the pinned $want"; exit 0; fi
  echo cursor; exit 0
fi

F="$STATE/cursor-dispatch.json"; LOCK="$STATE/cursor-dispatch.lock"
DAY=${FM_CURSOR_DAY:-$(TZ=America/Chicago date +%F)}
mkdir -p "$STATE"
tries=0
until mkdir "$LOCK" 2>/dev/null; do
  # A SIGKILLed run leaves the lock behind; one older than 60 s is stale.
  lock_mtime=$(mtime "$LOCK")
  if [ "$lock_mtime" -gt 0 ] && [ $(( $(date +%s) - lock_mtime )) -gt 60 ]; then
    echo "cursor guard: removed a stale lock older than 60 s at $LOCK" >&2
    rmdir "$LOCK" 2>/dev/null
    continue
  fi
  tries=$((tries + 1))
  [ "$tries" -le 100 ] || { echo "cursor guard: refused $id, could not take $LOCK" >&2; exit 1; }
  sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
cur='{}'
[ ! -s "$F" ] || cur=$(cat "$F")
cur=$(jq -c --arg d "$DAY" 'if (.day? == $d) and ((.beads? | type) == "object") then . else {day: $d, beads: {}} end' <<<"$cur" 2>/dev/null) \
  || { echo "cursor guard: refused $id, $F is not valid JSON" >&2; exit 1; }
if [ "$op" = give ]; then
  new=$(jq -c --arg id "$id" 'if (.beads[$id] // 0) > 1 then .beads[$id] -= 1 else del(.beads[$id]) end' <<<"$cur")
else
  n=$(jq -r --arg id "$id" '.beads[$id] // 0' <<<"$cur")
  if [ "$n" -ge 2 ]; then
    echo "cursor guard: refused $id, already launched $n times today ($DAY); write blocked: instead of a 3rd run" >&2; exit 1
  fi
  new=$(jq -c --arg id "$id" '.beads[$id] = ((.beads[$id] // 0) + 1)' <<<"$cur")
fi
printf '%s\n' "$new" > "$F.tmp.$$" && mv "$F.tmp.$$" "$F"
