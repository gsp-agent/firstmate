#!/usr/bin/env bash
# capture-evidence.sh <label>: save what each adapter actually classifies.
# BASE reads `pane read --source visible`; HEAD reads fm_backend_herdr_composer_capture.
# Letters on rows other than the lab's own synthetic text and composer rows are
# masked to x (digits kept) so no account or statusline text is published.
set -u
. "$(cat "${TMPDIR:-/tmp}/fm-xbvre-live.path")/env.sh"
EV=/Users/dalecarman/.no-mistakes/evidence/01M53ZX69ZX0GCAGCV12JPBZ9A
PANE=$(cat "$SCRATCH/pane"); TARGET="$SESSION:$PANE"; label=$1
redact() {
  perl -CSD -pe 'unless (/^(old scrollback line \d+|[─]+|❯.*|\s*[❯ ]?\s*\/\S+.*|.*fm draft probe.*)\s*$/) { s/[A-Za-z]/x/g }' |
    sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]+/<email>/g'
}
{
  printf '# %s: pane get scroll = %s\n' "$label" "$(lab pane get "$PANE" | jq -c '.result.pane.scroll')"
  printf '# BASE source: pane read --source visible (what the base adapter classified)\n'
  lab pane read "$PANE" --source visible | redact | cat -n
} > "$EV/live-$label-base-visible.txt"
{
  printf '# %s: pane get scroll = %s\n' "$label" "$(lab pane get "$PANE" | jq -c '.result.pane.scroll')"
  printf '# HEAD source: fm_backend_herdr_composer_capture (text format)\n'
  env -u HERDR_PANE_ID -u HERDR_SESSION PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_capture "$2"' _ "$WT" "$TARGET" | redact | cat -n
} > "$EV/live-$label-head-capture.txt"
printf 'wrote %s and %s\n' "live-$label-base-visible.txt" "live-$label-head-capture.txt"
