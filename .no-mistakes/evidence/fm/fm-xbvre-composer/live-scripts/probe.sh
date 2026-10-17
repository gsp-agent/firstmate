#!/usr/bin/env bash
# probe.sh <label>: read the lab pane's composer with the new (HEAD) and the
# base-commit Herdr adapters, side by side. Every herdr call goes through the
# lab helper via the fakebin wrapper.
set -u
. "$(cat "${TMPDIR:-/tmp}/fm-xbvre-live.path")/env.sh"
PANE=$(cat "$SCRATCH/pane")
TARGET="$SESSION:$PANE"
label=${1:-probe}
read_with() {  # <root> <function>
  env -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_ENV -u HERDR_SOCKET_PATH PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" \
    bash -c '. "$1/bin/backends/herdr.sh"; "$2" "$3"' _ "$1" "$2" "$TARGET" 2>/dev/null
}
scroll=$(lab pane get "$PANE" | jq -c '.result.pane.scroll')
new_state=$(read_with "$WT" fm_backend_herdr_composer_state)
base_state=$(read_with "$SCRATCH/base" fm_backend_herdr_composer_state)
new_content=$(read_with "$WT" fm_backend_herdr_composer_content); nc=$?
base_content=$(read_with "$SCRATCH/base" fm_backend_herdr_composer_content); bc=$?
printf '[%s] scroll=%s\n' "$label" "$scroll"
printf '[%s] HEAD composer_state=%s   composer_content(rc=%s)=%q\n' "$label" "$new_state" "$nc" "$new_content"
printf '[%s] BASE composer_state=%s   composer_content(rc=%s)=%q\n' "$label" "$base_state" "$bc" "$base_content"
