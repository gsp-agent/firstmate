#!/usr/bin/env bash
set -eu
VALIDATION_ROOT=$PWD
VALIDATION_HOME="$VALIDATION_ROOT/.test-phase/backlog-home"
mkdir -p "$VALIDATION_HOME/config" "$VALIDATION_HOME/data" "$VALIDATION_HOME/state"
export FM_HOME="$VALIDATION_HOME"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$VALIDATION_HOME/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$VALIDATION_HOME/data/backlog.md"
. "$VALIDATION_ROOT/bin/fm-tasks-axi-lib.sh"
. "$VALIDATION_ROOT/bin/fm-backlog-transition-lib.sh"
cd "$VALIDATION_HOME"
URL='https://gitlab.example.com/group/sub/project/-/merge_requests/269'
tasks-axi add native-gitlab-close 'Complete the GitLab item' --kind ship --repo fixture --start --file "$VALIDATION_HOME/data/backlog.md"
fm_backlog_done "$VALIDATION_HOME/data" native-gitlab-close --pr "$URL"
tasks-axi show native-gitlab-close --file "$VALIDATION_HOME/data/backlog.md"
tasks-axi add native-gitlab-replay 'Recover the interrupted GitLab close' --kind ship --repo fixture --start --file "$VALIDATION_HOME/data/backlog.md"
fm_backlog_close_marker_write "$VALIDATION_HOME/state" native-gitlab-replay "$VALIDATION_HOME/data" validation-spawn --pr "$URL"
fm_backlog_close_marker_replay "$VALIDATION_HOME/state" "$VALIDATION_HOME/state/native-gitlab-replay.backlog-close" "$VALIDATION_HOME/data"
printf 'close_replay_result=%s\n' "$FM_BACKLOG_CLOSE_REPLAY_RESULT"
tasks-axi show native-gitlab-replay --file "$VALIDATION_HOME/data/backlog.md"
test ! -e "$VALIDATION_HOME/state/native-gitlab-replay.backlog-close"
printf '\nPersisted backlog after both public transitions:\n'
cat "$VALIDATION_HOME/data/backlog.md"
