#!/usr/bin/env bash
set -eu
root='/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5988E2EDNGT1XV34F05X546'
cd "$root"
for relative in ./.test-phase ./p ./q; do
  fixture="$root/${relative#./}"
  [ -d "$fixture" ] || continue
  [ ! -L "$fixture" ] || { printf 'refusing symlink fixture: %s\n' "$fixture"; exit 1; }
  ls -ld "$fixture"
  # Inspect and stop only marked disposable homes before removing the fixtures.
  while IFS= read -r marker; do
    lab=${marker%/.fm-lab-home}
    if [ -e "$lab/state/.watch.lock" ]; then
      env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
        -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        FM_HOME="$lab" "$root/bin/fm-watch-arm.sh" --stop
    fi
  done < <(find "$fixture" -name .fm-lab-home -type f -print)
  # Exact destructive command is reviewed by dcg before execution.
  guard=$(python3 - "$relative" <<'PY' | dcg
import json, shlex, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'rm -r -- '+shlex.quote(sys.argv[1])}}))
PY
  )
  case "$guard" in *deny*) printf '%s\n' "$guard"; exit 1 ;; esac
  rm -r -- "${relative:?}"
done
baseline="$root/.agent-state/dirtiness/no-mistakes-test-01M5988E2EDNGT1XV34F05X546.json"
if [ -f "$baseline" ]; then
  ls -l "$baseline"
  guard=$(python3 - "$baseline" <<'PY' | dcg
import json, shlex, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'rm -- '+shlex.quote(sys.argv[1])}}))
PY
  )
  case "$guard" in *deny*) printf '%s\n' "$guard"; exit 1 ;; esac
  rm -- "${baseline:?}"
fi
git -C "$root" status --short
