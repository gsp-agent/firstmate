#!/usr/bin/env bash
# Real Pi 0.85 primary-shaped print run in a disposable lab home with the fm
# extensions loaded explicitly, a probe extension, and a local stand-in model.
# Usage: pi-lab.sh <worktree> <ext-dir> <label> <out-file>
# Prints the lab path; the caller removes it as its own command.
set -u
WT=$1 EXT=$2 LABEL=$3 OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/pi-agent" "$LAB/sessions" "$LAB/run"
node "$HERE/fake-openai.mjs" "$LAB/port" "$LAB/requests.jsonl" & SRV=$!
i=0; while [ ! -s "$LAB/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
PORT=$(cat "$LAB/port")
jq -n --arg url "http://127.0.0.1:$PORT/v1" '{providers:{labfake:{baseUrl:$url,api:"openai-completions",apiKey:"lab-placeholder",compat:{supportsDeveloperRole:false,supportsReasoningEffort:false},models:[{id:"lab-model",reasoning:false}]}}}' > "$LAB/pi-agent/models.json"
PROMPT='captain: please check the fleet'
# One eligible row in the real queue format (epoch, seq, kind, key, payload).
printf '%s\t1\theartbeat\theartbeat\tlab heartbeat review\n' "$(date +%s)" > "$LAB/state/.wake-queue"
printf '1\n' > "$LAB/state/.wake-queue.seq"
(
  cd "$LAB/run" || exit 1
  printf '%s\n' "$BASHPID" > "$LAB/state/.lock"
  exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PI_CODING_AGENT_DIR="$LAB/pi-agent" PROBE_LOG="$LAB/probe.jsonl" PROBE_REQUESTS="$LAB/requests.jsonl" PROBE_OFFER=1 \
    timeout 150 pi -p --offline --no-extensions -e "$EXT/fm-primary-pi-watch.ts" -e "$EXT/fm-branch-supervision.ts" -e "$HERE/probe.ts" \
    --no-skills --no-context-files --no-prompt-templates --no-themes --session-dir "$LAB/sessions" \
    --provider labfake --model lab-model "$PROMPT"
) > "$LAB/pi.out" 2> "$LAB/pi.err"; rc=$?
kill "$SRV" 2>/dev/null
{
  echo "variant: $LABEL"
  echo "extensions loaded: $EXT/fm-primary-pi-watch.ts, $EXT/fm-branch-supervision.ts (+ probe.ts)"
  echo "pi: $(command -v pi) version $(pi --version 2>/dev/null); stand-in model server 127.0.0.1:$PORT; lab FM_HOME $LAB; primary lock held by the pi process"
  echo "\$ pi -p --no-extensions -e <fm extensions> -e probe.ts --provider labfake --model lab-model '$PROMPT'  -> exit $rc"
  echo "pi stdout: $(head -c 400 "$LAB/pi.out")"
  echo "pi stderr: $(grep -v 'collision-guard\|No models match' "$LAB/pi.err" | head -c 1500)"
  echo "model requests received: $(grep -c . "$LAB/requests.jsonl" 2>/dev/null)"
  echo "probe records:"
  jq . "$LAB/probe.jsonl" 2>/dev/null | sed 's/^/  /'
  echo "branch session file: $(cat "$LAB/state/.branch-session" 2>/dev/null)"
  bs=$(cat "$LAB/state/.branch-session" 2>/dev/null)
  echo "branch session fm-main-mirror entries:"
  [ -f "$bs" ] && jq -c 'select(.customType=="fm-main-mirror") | .content' "$bs" | cut -c1-200 | sed 's/^/  | /'
  echo "wake queue after run: $(cat "$LAB/state/.wake-queue" 2>/dev/null | tr '\t' ' ')"
  echo "watch extension log (state/.watch-extension.log, tail):"
  tail -5 "$LAB/state/.watch-extension.log" 2>/dev/null | cut -c1-300 | sed 's/^/  | /'
} > "$OUT" 2>&1
