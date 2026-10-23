#!/usr/bin/env bash
set -eu
export FM_HERDR_LAB_STATE_DIR="$PWD/.nm-test-live/herdr-state"
SESSION=fm-lab-exit-shells-37054-21491
helper="$PWD/bin/fm-herdr-lab.sh"
"$helper" teardown "$SESSION"
trap '"$helper" teardown "$SESSION"' EXIT
"$helper" provision "$SESSION"
lab() { "$helper" run "$SESSION" "$@"; }
workspace=$(lab workspace create --cwd "$PWD" --label nm-exit-validation --no-focus)
pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id')
printf 'Named lab %s, pane %s\n' "$SESSION" "$pane"
printf -v launch '%q ' env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "FM_HOME=$PWD/.nm-test-live/home" claude --setting-sources '' --settings '{"disableAllHooks":true}'
lab pane run "$pane" "$launch"
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  screen=$(lab pane read "$pane" --source visible)
  case "$screen" in *'Quick safety check'*) break ;; esac
  sleep 1
done
printf '%s\n' "$screen"
case "$screen" in *'Quick safety check'*) echo 'Real Claude again requires workspace trust; no key sent.' ;; *) echo 'Unexpected launch screen'; exit 1 ;; esac
