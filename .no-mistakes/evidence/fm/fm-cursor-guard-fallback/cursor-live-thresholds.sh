#!/usr/bin/env bash
export FM_HOME=$1 FM_CURSOR_USAGE_DIR="$1/usage"
printf '{"cursor_fallback":{"models_pct":84.5,"max_age_h":26.5}}\n' > "$FM_HOME/config/crew-dispatch.json"
printf 'cursor_models_pct=85\n' > "$FM_CURSOR_USAGE_DIR/current-spending.txt"
printf '85%% with 84.5%% threshold: '
bin/fm-cursor-guard.sh fallback lab-fractional
printf 'cursor_models_pct=84\n' > "$FM_CURSOR_USAGE_DIR/current-spending.txt"
printf '84%% with 84.5%% threshold: '
bin/fm-cursor-guard.sh fallback lab-fractional
printf '{"cursor_fallback":{"models_pct":84.5,"max_age_h":0.5}}\n' > "$FM_HOME/config/crew-dispatch.json"
python3 - "$FM_CURSOR_USAGE_DIR/current-spending.txt" <<'PY'
import os,sys,time
old=time.time()-2700
os.utime(sys.argv[1],(old,old))
PY
printf '45-minute file with half-hour limit: '
bin/fm-cursor-guard.sh fallback lab-fractional
