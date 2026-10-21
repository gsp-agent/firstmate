#!/usr/bin/env bash
set -eu
. "$PWD/bin/fm-pr-lib.sh"
state="$PWD/.gate-validation/old-state"
template="$PWD/bin/fm-pr-poll.sh"
historical="$PWD/.gate-validation/predecessor.sh"
hash=$(fm_pr_sha256 "$historical")
printf 'Prior shipped template: %s\n' "$hash"
[ "$hash" = 66dd5009cb6f0f0b8d5bbf88b521059e2c70a238c3d75b24562cefc298a84687 ]
fm_pr_poll_artifacts_valid "$state" old-1 "$historical"
if fm_pr_poll_artifacts_valid "$state" old-1 "$template"; then
  echo 'Unexpected current-template registration before recovery' >&2
  exit 1
fi
fm_pr_poll_registration_rerecord_template "$state" old-1 "$template"
fm_pr_poll_artifacts_valid "$state" old-1 "$template"
printf 'Authenticated predecessor watch upgraded; real poll output follows:\n'
bash "$state/old-1.check.sh"
