#!/usr/bin/env bash
# Drive cursor_fallback validation and the spend guard in a disposable lab home.
# Prints the lab path on stdout; the caller removes it as its own command.
set -u
WT=$1 OUT=$2
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
echo "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/cursor-usage" "$LAB/pstack/.cursor-plugin"
printf '{"version":"0.15.21"}\n' > "$LAB/pstack/.cursor-plugin/plugin.json"
printf 'cursor_models_pct=90\n' > "$LAB/cursor-usage/20261016-spending.txt"
clean() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
{
echo "lab home: $LAB (marked: $([ -f "$LAB/.fm-lab-home" ] && echo yes || echo no))"
echo "jq: $(jq --version)"
echo "spending file: cursor_models_pct=90 (fresh). Any accepted limit <= 90 must leave Cursor; 100 must keep Cursor."
accepted=0 rejected=0 broken=0
for spelling in \
  '{"models_pct":85,"max_age_h":26}' \
  '{"models_pct":1,"max_age_h":1}' \
  '{"models_pct":100,"max_age_h":1}' \
  '{"models_pct":90,"max_age_h":26}' \
  '{"models_pct":85.0,"max_age_h":26}' \
  '{"models_pct":85,"max_age_h":26.0}' \
  '{"models_pct":1E2,"max_age_h":26}' \
  '{"models_pct":1e2,"max_age_h":26}' \
  '{"models_pct":8.5e1,"max_age_h":26}' \
  '{"models_pct":850e-1,"max_age_h":26}' \
  '{"models_pct":85.5,"max_age_h":26}' \
  '{"models_pct":85,"max_age_h":0.5}' \
  '{"models_pct":85,"max_age_h":2.6e1}' \
  '{"models_pct":85.00000000000001,"max_age_h":26}' \
  '{"models_pct":-0,"max_age_h":26}' \
  '{"models_pct":"85","max_age_h":26}' \
  '{"models_pct":0,"max_age_h":26}' \
  '{"models_pct":101,"max_age_h":26}' \
  '{"models_pct":85,"max_age_h":0}' ; do
  printf '{"cursor_fallback":%s,"default":{"harness":"cursor"}}\n' "$spelling" > "$LAB/config/crew-dispatch.json"
  echo
  echo "=== cursor_fallback=$spelling"
  dr_out=$(clean bin/fm-dispatch-resolve.sh --labels '' 2>&1); dr=$?
  echo "\$ bin/fm-dispatch-resolve.sh --labels ''  -> exit $dr"
  printf '%s\n' "$dr_out" | sed 's/^/  | /'
  bs=$(clean FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>&1 | grep CREW_DISPATCH)
  echo "\$ FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh | grep CREW_DISPATCH"
  if [ -n "$bs" ]; then printf '%s\n' "$bs" | sed 's/^/  | /'; else echo "  | (no CREW_DISPATCH line: accepted)"; fi
  g_out=$(FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_CURSOR_USAGE_DIR="$LAB/cursor-usage" FM_PSTACK_DIR="$LAB/pstack" bin/fm-cursor-guard.sh fallback lab-bead 2>"$LAB/g.err"); g=$?
  g_err=$(cat "$LAB/g.err")
  echo "\$ bin/fm-cursor-guard.sh fallback lab-bead  -> exit $g"
  echo "  | stdout: $g_out"
  [ -z "$g_err" ] || echo "  | stderr: $g_err"
  if [ "$dr" = 0 ] && [ -z "$bs" ]; then
    accepted=$((accepted+1))
    pct=$(printf '%s' "$spelling" | jq -r '.models_pct')
    want=fallback; [ "$pct" -gt 90 ] 2>/dev/null && want=cursor
    verdict=ok
    [ -z "$g_err" ] || verdict=BROKEN
    if [ "$want" = cursor ]; then [ "$g_out" = cursor ] || verdict=BROKEN; else case "$g_out" in codex*|claude*) ;; *) verdict=BROKEN ;; esac; fi
    [ "$verdict" = ok ] || broken=$((broken+1))
    echo "  => ACCEPTED by both validators; guard decision expected=$want -> $verdict"
  elif [ "$dr" = 2 ] && [ -n "$bs" ]; then
    rejected=$((rejected+1))
    echo "  => REJECTED by both validators (never dispatched)"
  else
    broken=$((broken+1))
    echo "  => VALIDATORS DISAGREE: dispatch-resolve exit $dr, bootstrap line '${bs:-none}'"
  fi
done
echo
echo "SUMMARY: accepted=$accepted rejected=$rejected broken=$broken"
} > "$OUT" 2>&1
