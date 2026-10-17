#!/usr/bin/env bash
# revive-gate.sh <root>: the two adapter reads herdr-primary-revive.sh's reset gate makes
# (configs/firstmate/herdr-primary-revive.sh:515-518), through firstmate's own dispatcher.
set -u
. "$(cat "${TMPDIR:-/tmp}/fm-xbvre-live.path")/env.sh"
TARGET="$SESSION:$(cat "$SCRATCH/pane")"
root=$1
out=$(env -u HERDR_PANE_ID -u HERDR_SESSION PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" FM_HOME="$SCRATCH/fmhome" \
  bash -c '. "$1/bin/fm-backend.sh" && fm_backend_source herdr || exit 9
    rendered=$(fm_backend_herdr_rendered_busy_state "$2" claude 2>/dev/null)
    composer=$(fm_backend_composer_state herdr "$2" 2>/dev/null)
    printf "rendered=%s composer=%s " "$rendered" "$composer"
    if [ "$rendered" = idle ] && [ "$composer" = empty ]; then echo "=> reset gate PASSES (would type /clear)"
    else echo "=> reset gate DEFERS (composer is ${composer:-unknown}; never type into a draft)"; fi' _ "$root" "$TARGET")
printf '[%s] %s\n' "$(basename "$root" | sed 's/^01M.*/HEAD/; s/^base$/BASE/')" "$out"
