#!/usr/bin/env bash
set -eu
export PATH="$PWD/.test-phase/linux-bin:$PATH"
export FM_HOME="$PWD/.test-phase/linux-live-home"
export FM_CURSOR_USAGE_DIR="$FM_HOME/usage" FM_PSTACK_DIR="$FM_HOME/pstack"
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_CURSOR_USAGE_DIR" "$FM_PSTACK_DIR/.cursor-plugin"
printf '{"version":"0.15.21"}\n' > "$FM_PSTACK_DIR/.cursor-plugin/plugin.json"
uname -s
stat --version
jq --version
printf 'cursor_models_pct=26\n' > "$FM_CURSOR_USAGE_DIR/current-spending.txt"
printf 'Fresh spending file: '
out=$(bin/fm-cursor-guard.sh fallback linux-demo)
printf '%s\n' "$out"
[ "$out" = cursor ]
touch -d '2000-01-01 UTC' "$FM_CURSOR_USAGE_DIR/current-spending.txt"
printf 'Stale spending file: '
out=$(bin/fm-cursor-guard.sh fallback linux-demo)
printf '%s\n' "$out"
case "$out" in codex*) ;; *) exit 1 ;; esac
mkdir "$FM_HOME/state/cursor-dispatch.lock"
touch -d '2000-01-01 UTC' "$FM_HOME/state/cursor-dispatch.lock"
bin/fm-cursor-guard.sh take linux-demo
[ ! -e "$FM_HOME/state/cursor-dispatch.lock" ]
printf 'Launch accounting after stale-lock recovery: '
cat "$FM_HOME/state/cursor-dispatch.json"
