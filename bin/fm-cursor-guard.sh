#!/usr/bin/env bash
# fm-cursor-guard.sh - the launch route for a Cursor or Codex code worker. No model judgment.
#   route <id> <harness> [<recorded-harness>]
#                      prints <harness> when it is kept, else "<new-harness> <reason>",
#                      and exits 0; fm-spawn and fm-control relaunch call it for every
#                      crewmate and scout launch, and launch what it prints.
#                      cursor: Codex when the shared Cursor/Grok pool is short or unknown: the newest
#                      <usage dir>/*-spending.txt says cursor_models_pct >= the crew-dispatch.json
#                      cursor_fallback.models_pct (integer 1..100, default 85), or there is no readable file, or
#                      it is older than max_age_h (positive integer, default 26) by mtime. At pct >= the limit,
#                      credit room in the same file keeps Cursor (Dale 10-16) only when
#                      on_demand=enabled, a numeric monthly_additional_usage_used is below a
#                      numeric monthly_additional_usage_limit, and a numeric prepaid_balance is
#                      above 0; anything else, a missing or non-numeric value included, is no
#                      room and falls back. Bare Grok draws the same
#                      pool, so it is no fallback there. The fallback reason is written to
#                      state/<id>.cursor-fallback, and the Codex choice then takes the codex route.
#                      codex: Claude when state/<id>.codex-limit exists. Before reading it, the
#                      route looks for the task's current Codex session: the newest
#                      ${CODEX_HOME:-~/.codex}/sessions rollout modified since the spawn_gen epoch
#                      in state/<id>.meta whose session_meta cwd is the recorded worktree. When that
#                      session's last task_complete carries codex_error_info usage_limit_exceeded,
#                      the route writes the marker with Codex's own message, so the stop routes
#                      this launch and every later one to Claude.
#                      An explicit harness other than cursor for a task recorded on cursor is kept
#                      and named in state/<id>.cursor-fallback. Any other harness prints unchanged.
# The usage directory defaults to ~/.agent-state/a3ov3/cursor-usage.
# Spending files supply cursor_models_pct=<integer>; invalid values select fallback.
# Usage percentages, configured thresholds, and configured ages are consumed as integers.
# Overrides for tests: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_CURSOR_USAGE_DIR.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
USAGE="${FM_CURSOR_USAGE_DIR:-$HOME/.agent-state/a3ov3/cursor-usage}"
op=${1:-}; id=${2:-}; harness=${3:-}; recorded=${4:-}
[ "$op" = route ] && [ -n "$id" ] && [ -n "$harness" ] || { echo "usage: fm-cursor-guard.sh route <bead-id> <harness> [<recorded-harness>]" >&2; exit 2; }
if [ "$recorded" = cursor ] && [ "$harness" != cursor ]; then
  printf '%s\n' "explicit --harness $harness override of a recorded cursor task" > "$STATE/$id.cursor-fallback"
fi
case "$harness" in cursor | codex) ;; *) echo "$harness"; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { echo "cursor guard: jq required" >&2; exit 1; }
mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

# codex_limit_scan: write state/<id>.codex-limit when the task's current Codex
# session ended on its usage limit. Codex 0.163 keeps its TUI open after that
# stop and persists it only in the rollout, never as a process exit.
codex_limit_scan() {
  local meta="$STATE/$id.meta" wt wt_real gen sessions newest f marker
  [ -r "$meta" ] || return 0
  wt=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  gen=$(sed -n 's/^spawn_gen=s\([0-9][0-9]*\)\..*/\1/p' "$meta" | tail -1)
  sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -n "$wt" ] && [ -n "$gen" ] && [ -d "$sessions" ] || return 0
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  newest=
  # shellcheck disable=SC2016  # awk program text: $0 is awk's record.
  while IFS= read -r f; do
    [ "$(mtime "$f")" -ge "$gen" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
  done < <(find "$sessions" -name 'rollout-*.jsonl' -type f -mmin "-$(( ($(date +%s) - gen) / 60 + 1 ))" -print0 2>/dev/null |
    xargs -0 awk -v a="\"cwd\":\"$wt\"" -v b="\"cwd\":\"$wt_real\"" \
      'FNR == 1 { if (index($0, a) || index($0, b)) print FILENAME; nextfile }' 2>/dev/null)
  [ -n "$newest" ] || return 0
  marker=$(grep -F '"type":"task_complete"' "$newest" | tail -1 | jq -r --arg id "$id" '
    .payload.error | select(.codex_error_info == "usage_limit_exceeded") | (.message // "" | gsub("\n"; " ")) as $m
    | "codex run for \($id) hit its usage limit" + (if $m == "" then "" else ": " + $m end)' 2>/dev/null)
  [ -z "$marker" ] || printf '%s\n' "$marker" > "$STATE/$id.codex-limit"
}

# codex_route [<reason Codex was chosen>]
codex_route() {
  [ -s "$STATE/$id.codex-limit" ] || codex_limit_scan
  if [ -s "$STATE/$id.codex-limit" ]; then
    echo "claude ${1:+$1; }$(head -1 "$STATE/$id.codex-limit")"
  elif [ "$harness" = codex ]; then
    echo codex
  else
    echo "codex $1"
  fi
}

[ "$harness" = cursor ] || { codex_route; exit 0; }
# pool <reason>: the shared Cursor/Grok pool cannot carry this launch.
pool() {
  printf '%s\n' "$1" > "$STATE/$id.cursor-fallback"
  codex_route "$1"
}
pct_max=85; age_max=26
if [ -r "$CONFIG/crew-dispatch.json" ]; then
  pct_max=$(jq -r '.cursor_fallback.models_pct // 85 | if type == "number" and . == floor then floor else . end' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 85)
  age_max=$(jq -r '.cursor_fallback.max_age_h // 26 | if type == "number" and . == floor then floor else . end' "$CONFIG/crew-dispatch.json" 2>/dev/null || echo 26)
fi
case "$pct_max" in '' | *[!0-9]*) pool "cursor_fallback.models_pct '$pct_max' in crew-dispatch.json is not an integer"; exit 0 ;; esac
case "$age_max" in '' | *[!0-9]*) pool "cursor_fallback.max_age_h '$age_max' in crew-dispatch.json is not an integer"; exit 0 ;; esac
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
echo cursor
