#!/usr/bin/env bash
set -u
. .nm-composer-test/env.sh
if [ "${1:-}" = --base ]; then
  shift
  . .nm-composer-test/base-herdr.sh
else
  . bin/backends/herdr.sh
fi
session=$(cat .nm-composer-test/session)
pane=$(jq -r '.result.root_pane.pane_id' .nm-composer-test/workspace.json)
fm_backend_herdr_cli() {
  local requested=$1
  shift
  [ "$requested" = "$session" ] || return 97
  bin/fm-herdr-lab.sh run "$requested" "$@"
}
fm_test_viewer_start() {
  PATH="$PWD/.nm-composer-test/viewer-bin:$PATH" bin/fm-herdr-lab.sh viewer start "$session"
}
fm_test_viewer_stop() {
  bin/fm-herdr-lab.sh viewer stop "$session"
}
method=${1:-fm_backend_herdr_composer_state}
shift || true
"$method" "$session:$pane" "$@"
