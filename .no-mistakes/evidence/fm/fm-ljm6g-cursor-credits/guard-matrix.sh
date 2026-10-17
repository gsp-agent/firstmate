#!/usr/bin/env bash
# Drive the real bin/fm-cursor-guard.sh `fallback` command against disposable
# spending files, state, config and pstack dirs. Prints one transcript block per
# scenario: the spending file the guard read, its real output, and the verdict.
# Usage: guard-matrix.sh <worktree>
set -u
shopt -s lastpipe  # run is the last pipeline stage, so its counters persist
WT=${1:?worktree}
TOOL="$WT/bin/fm-cursor-guard.sh"
R=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-matrix.XXXXXX")
trap 'rm -rf "${R:?}"' EXIT
export FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" FM_CURSOR_USAGE_DIR="$R/usage" FM_PSTACK_DIR="$R/pstack"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_CURSOR_USAGE_DIR" "$FM_PSTACK_DIR/.cursor-plugin"
SPEND="$FM_CURSOR_USAGE_DIR/20261017-0800-spending.txt"
pin() { printf '{"name":"pstack","version":"%s"}\n' "$1" > "$FM_PSTACK_DIR/.cursor-plugin/plugin.json"; }
pin 0.15.21
total=0; bad=0
# run <label> <expected-glob> <bead> ; spending file content on stdin
run() {
  local label=$1 want=$2 bead=$3 out
  cat > "$SPEND"
  out=$("$TOOL" fallback "$bead" 2>&1)
  total=$((total + 1))
  printf '### %s\n' "$label"
  sed 's/^/    file: /' "$SPEND" | cat -v
  printf '    guard> %s\n' "$out"
  # shellcheck disable=SC2254
  case "$out" in $want) printf '    PASS (expected %s)\n\n' "$want" ;; *) bad=$((bad + 1)); printf '    FAIL (expected %s)\n\n' "$want" ;; esac
}
real() {  # the real spending file keys, with pct and credit fields filled in
  printf 'cursor_models_pct=%s\nother_models_pct=45\non_demand=%s\nprepaid_balance=%s\nmonthly_additional_usage_used=%s\nmonthly_additional_usage_limit=%s\ncycle_resets=2026-11-14\nread_at=2026-10-17T03:00-05:00\n' "$@"
}

echo "## pct at or over the limit: credit room keeps Cursor"
real 100 enabled 445.63 138.38 400 | run "pct 100, on-demand enabled, prepaid 445.63, used 138.38 of 400" cursor e1
real 89 enabled 445.63 138.38 400 | run "pct 89 (over 85), same credit room" cursor e1
real 100 enabled 0.01 399.99 400 | run "pct 100, prepaid 0.01, used 399.99 of 400 (edge just inside)" cursor e1

echo "## pct at or over the limit: no credit room diverts with the no-room message"
real 100 enabled 184.05 400.00 400 | run "pct 100, prepaid 184.05 but used 400.00 of 400 (Dale's 10-16 trace)" 'codex Cursor Models at 100% (limit 85%) and no prepaid/on-demand credit room in 20261017-0800-spending.txt' e1
real 100 disabled 84.07 10 400 | run "pct 100, on-demand disabled, prepaid 84.07, used 10 of 400" 'codex *no prepaid/on-demand credit room*' e1
real 100 not_set 84.07 0 0 | run "pct 100, on-demand not_set, prepaid 84.07, limit 0 (real 10-13 state)" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 0 10 400 | run "pct 100, on-demand room but prepaid 0" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 0.00 10 400 | run "pct 100, prepaid 0.00" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 445.63 400.001 400 | run "pct 100, used 400.001 just past 400" 'codex *no prepaid/on-demand credit room*' e1
real 85 enabled 0 400 400 | run "pct 85 exactly at the limit, no room" 'codex Cursor Models at 85% (limit 85%) and no*' e1

echo "## unknown values are no room (adversarial)"
printf 'cursor_models_pct=100\non_demand=enabled\nmonthly_additional_usage_used=10\nmonthly_additional_usage_limit=400\n' | run "prepaid_balance missing" 'codex *no prepaid/on-demand credit room*' e1
printf 'cursor_models_pct=100\nprepaid_balance=445.63\nmonthly_additional_usage_used=10\nmonthly_additional_usage_limit=400\n' | run "on_demand missing" 'codex *no prepaid/on-demand credit room*' e1
printf 'cursor_models_pct=100\non_demand=enabled\nprepaid_balance=445.63\nmonthly_additional_usage_limit=400\n' | run "monthly_additional_usage_used missing" 'codex *no prepaid/on-demand credit room*' e1
printf 'cursor_models_pct=100\non_demand=enabled\nprepaid_balance=445.63\nmonthly_additional_usage_used=10\n' | run "monthly_additional_usage_limit missing" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 445.63 not-available 400 | run "used=not-available" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 445.63 '' 400 | run "used empty" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled -5 10 400 | run "prepaid negative (-5)" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 1e3 10 400 | run "prepaid in exponent form (1e3)" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled '$445.63' 10 400 | run "prepaid with a currency sign" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 445.63 10 '400 ' | run "limit with a trailing space" 'codex *no prepaid/on-demand credit room*' e1
real 100 Enabled 445.63 10 400 | run "on_demand=Enabled (wrong case)" 'codex *no prepaid/on-demand credit room*' e1
real 100 enabled 445.63 10 400 | sed 's/$/\r/' | run "CRLF line endings" 'codex *' e1
printf 'cursor_models_pct=100\non_demand=enabled\nprepaid_balance=445.63\nmonthly_additional_usage_used=10\nmonthly_additional_usage_limit=400\non_demand=disabled\n' | run "a later on_demand=disabled line wins" 'codex *no prepaid/on-demand credit room*' e1

echo "## credit room does not override the other guards"
pin 0.15.22
real 100 enabled 445.63 138.38 400 | run "credit room with an off-pin pstack 0.15.22" "grok pstack plugin version is '0.15.22', not the pinned 0.15.21" e1
real 100 enabled 0 10 400 | run "no room with an off-pin pstack still goes to codex, not grok" 'codex *no prepaid/on-demand credit room*' e1
pin 0.15.21
printf 'cursor run for e1 exited 1 on a usage-limit/429 error; next launch goes to codex\n' > "$FM_STATE_OVERRIDE/e1.cursor-limit"
real 100 enabled 445.63 138.38 400 | run "credit room but this bead's last Cursor run hit a usage limit" 'codex cursor run for e1 exited 1 on a usage-limit/429 error*' e1
real 100 enabled 445.63 138.38 400 | run "another bead (e2) is not moved by e1's marker" cursor e2
rm -f "$FM_STATE_OVERRIDE/e1.cursor-limit"
printf 'codex run for e1 hit its usage limit\n' > "$FM_STATE_OVERRIDE/e1.codex-limit"
real 100 enabled 445.63 400 400 | run "no room and the bead's Codex run hit its limit goes to claude" 'claude Cursor Models at 100% (limit 85%) and no prepaid/on-demand credit room*; codex run for e1 hit its usage limit' e1
real 100 enabled 445.63 138.38 400 | run "credit room with a codex-limit marker stays on cursor" cursor e1
rm -f "$FM_STATE_OVERRIDE/e1.codex-limit"
real 100 enabled 445.63 138.38 400 > "$SPEND"
touch -t "$(date -v-30H +%Y%m%d%H%M 2>/dev/null || date -d '30 hours ago' +%Y%m%d%H%M)" "$SPEND"
out=$("$TOOL" fallback e1 2>&1); total=$((total + 1))
printf '### stale file (30 h old by mtime) with credit room still diverts\n'
sed 's/^/    file: /' "$SPEND"
printf '    guard> %s\n' "$out"
case "$out" in 'codex newest Cursor spending file is 30 h old (limit 26 h)') printf '    PASS\n\n' ;; *) bad=$((bad + 1)); printf '    FAIL\n\n' ;; esac

echo "## below the limit nothing changed"
printf 'cursor_models_pct=26\nother_models_pct=45\non_demand=disabled\ncycle_resets=2026-10-14\nread_at=2026-10-12T15:12-05:00\n' | run "pct 26 with on-demand disabled and no credit fields" cursor e1
real 84 disabled 0 400 400 | run "pct 84 with no credit room at all" cursor e1
printf '{"cursor_fallback":{"models_pct":101,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
real 100 disabled 0 400 400 | run "crew-dispatch.json models_pct 101 puts pct 100 below the limit" cursor e1
printf '{"cursor_fallback":{"models_pct":50,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
real 60 enabled 445.63 138.38 400 | run "models_pct 50 from config; pct 60 with room stays on cursor" cursor e1
real 60 enabled 445.63 400 400 | run "models_pct 50 from config; pct 60 without room diverts" 'codex Cursor Models at 60% (limit 50%) and no*' e1
rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"

printf '== %s scenarios, %s failed ==\n' "$total" "$bad"
[ "$bad" = 0 ]
