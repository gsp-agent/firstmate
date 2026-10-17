#!/usr/bin/env bash
# Real fm-spawn Cursor launches in a disposable lab home on a private tmux socket.
# Usage: cursor-lab.sh <worktree> <evidence-dir> <scratch-dir>
# Prints LAB and MATE paths first; the caller tears down the tmux server and
# removes both directories as separate commands.
set -u
WT=$1 EV=$2 SCR=$3
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-mate.XXXXXX")
echo "LAB=$LAB"; echo "MATE=$MATE"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/treehouse" "$LAB/user-home" "$LAB/pstack/.cursor-plugin" "$LAB/cursor-usage"
printf '{"version":"0.15.21"}\n' > "$LAB/pstack/.cursor-plugin/plugin.json"
printf 'cursor_models_pct=10\n' > "$LAB/cursor-usage/20261016-spending.txt"
printf '%s\n' '# lab allowlist' HOME PATH TERM USER LOGNAME LANG > "$LAB/config/launch-env-allowlist"
P="$LAB/projects/proj"
git init -q -b main "$P"; printf 'lab project\n' > "$P/README.md"
git -C "$P" add README.md; git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial
git clone -q --bare "$P" "$LAB/origin.git"; git -C "$P" remote add origin "file://$LAB/origin.git"; git -C "$P" fetch -q origin
printf '%s\n' '- proj [no-mistakes] - lab fixture (added 2026-10-16)' > "$LAB/data/projects.md"
TAG=lab$(printf '%s' "$LAB" | shasum | cut -c1-5)
SHIP=$TAG-pin SM=$TAG-csm
mkdir -p "$LAB/data/$SHIP" "$LAB/data/$SM"
cat > "$LAB/data/$SHIP/brief.md" <<'BRIEF'
# Task
## Captain's intent
Lab check of shell working-directory pinning only. Run exactly these three shell commands, each as its own separate Shell tool call, in this order, and set no working directory on any of them: 1) `cd /tmp && pwd` 2) `pwd` 3) `git symbolic-ref HEAD`. Then reply with the three outputs and stop.

## Firstmate spec
Lab-only verification. Do not edit files, commit, write a status file, or run any other command.
BRIEF
cat > "$LAB/data/$SM/brief.md" <<'BRIEF'
# Task
## Captain's intent
Lab check of the secondmate launch only. Reply with the single word READY and take no other action: run no commands and edit no files.

## Firstmate spec
Lab-only verification.
BRIEF
# Secondmate home outside the lab home and the repo.
mkdir -p "$MATE/bin" "$MATE/data"
printf '# Firstmate\n' > "$MATE/AGENTS.md"; printf '%s\n' "$SM" > "$MATE/.fm-secondmate-home"
printf 'charter for %s\n' "$SM" > "$MATE/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$MATE/.gitignore"
git -C "$MATE" init -q -b main

T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 220 -y 50 -c "$WT" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" -e FM_PSTACK_DIR="$LAB/pstack" \
  -e FM_CURSOR_USAGE_DIR="$LAB/cursor-usage" -e FM_CURSOR_CLI_CONFIG="$LAB/cursor-cli-config.json" \
  -e FM_CURSOR_MODELS_RULE="$LAB/pstack-models.mdc" bash --noprofile --norc || exit 1
waitfile() { local f=$1 n=$2 i=0; while [ ! -s "$f" ] && [ "$i" -lt "$n" ]; do sleep 1; i=$((i+1)); done; [ -s "$f" ]; }
cfg_before=$(shasum -a 256 "$HOME/.cursor/cli-config.json" 2>/dev/null | cut -c1-16)
th_before=$(ls "$HOME/.treehouse" 2>/dev/null | wc -l | tr -d ' ')

R="$EV/r2-cursor-ship-allowlist-live.txt"
{
echo "lab home: $LAB (marked: $([ -f "$LAB/.fm-lab-home" ] && echo yes || echo no))"
echo "cursor-agent: $(cursor-agent --version 2>&1 | head -1); login (operator HOME): $(cursor-agent status 2>&1 | grep -o 'Logged in' | head -1)"
echo "lab tmux socket: $(T display -p '#{socket_path}')"
echo "config/launch-env-allowlist:"; sed 's/^/  /' "$LAB/config/launch-env-allowlist"
echo
echo "=== A. allowlisted Cursor ship worker, spawned for real"
T send-keys -t primary "FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $SHIP $P --harness cursor --model grok-4.7-low --mode local-only --yolo off > $LAB/ship.out 2>&1; echo \$? > $LAB/ship.rc" Enter
waitfile "$LAB/ship.rc" 240 || echo "ship spawn did not finish in 240s"
echo "\$ bin/fm-spawn.sh $SHIP <project> --harness cursor --model grok-4.7-low --mode local-only --yolo off  -> exit $(cat "$LAB/ship.rc" 2>/dev/null)"
sed 's/^/  | /' "$LAB/ship.out"
SLOT=$(sed -n 's/^worktree=//p' "$LAB/state/$SHIP.meta" 2>/dev/null)
WIN=$(sed -n 's/^window=//p' "$LAB/state/$SHIP.meta" 2>/dev/null)
echo "worker window: ${WIN:-none}; slot: ${SLOT:-none} (branch $(git -C "${SLOT:-/nonexistent}" branch --show-current 2>/dev/null))"
LF=$(ls -t /tmp/fm-$SHIP+*/launch.*.sh 2>/dev/null | head -1)
echo "generated launch file: ${LF:-none}"
if [ -n "$LF" ]; then
  echo "  wrapper shell: $(grep -o '/bin/[a-z]*sh -c' "$LF" | head -1)"
  echo "  env -i wrapper: $(grep -c '/usr/bin/env -i' "$LF")"
  echo "  process substitution tee: $(grep -c '> >(tee' "$LF")"
  echo "  headless -p: $(grep -c " -p --output-format stream-json" "$LF")"
  echo "  model flag: $(grep -o -- "--model '*[a-z0-9.-]*'*" "$LF" | head -1)"
fi
GD="$LAB/state/$SHIP.cursor-crew-guard"
echo "crew guard hooks.json: $(cat "$GD/hooks/hooks.json" 2>/dev/null)"
# Wait for Cursor to finish: the stream ends with a result line.
S="$LAB/state/$SHIP.cursor-stream.jsonl"
i=0; while ! grep -q '"type":"result"' "$S" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 2; i=$((i+2)); done
echo "Cursor run finished after about ${i}s (result line present: $(grep -c '"type":"result"' "$S" 2>/dev/null))"
sleep 3
T send-keys -t "$WIN" 'echo "PANE_LAUNCH_EXIT=$?"' Enter
sleep 2
echo "--- worker pane tail (capture-pane):"
T capture-pane -p -t "$WIN" -S -400 | grep -v '^$' | cut -c1-400 | tail -25 | sed 's/^/  | /'
echo "--- captured stream file: $(wc -l < "$S" 2>/dev/null | tr -d ' ') JSON lines; pane shows stream JSON: $(T capture-pane -p -t "$WIN" -S -2000 | grep -c '^{"type"')"
echo "--- shell tool calls in the captured stream (command, workingDirectory, stdout or refusal):"
jq -c 'select(.type=="tool_call" and .subtype=="completed") | .tool_call.shellToolCall // empty | {command: .args.command, workingDirectory: .args.workingDirectory, stdout: (.result.success.stdout // null), refused: (.result.rejected.reason // .result.failure // null)}' "$S" 2>/dev/null | cut -c1-600 | sed 's/^/  | /'
echo "--- final result:"
jq -r 'select(.type=="result") | .result' "$S" 2>/dev/null | head -20 | sed 's/^/  | /'
echo "state/cursor-dispatch.json after ship: $(cat "$LAB/state/cursor-dispatch.json" 2>/dev/null)"
echo
echo "=== A2. same generated launch file, re-run in the worker pane with an unauthenticated HOME (exit status through the tee)"
if [ -n "$LF" ]; then
  T send-keys -t "$WIN" "HOME=$LAB/user-home; . '$LF'; echo \"RERUN_EXIT=\$?\"" Enter
  i=0; while ! T capture-pane -p -t "$WIN" -S -400 | grep -q 'RERUN_EXIT=' && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
  T capture-pane -p -t "$WIN" -S -400 | grep -v '^$' | cut -c1-300 | tail -4 | sed 's/^/  | /'
  echo "reference: the same binary run directly with that HOME: $(HOME=$LAB/user-home cursor-agent -p --output-format stream-json --trust hi >/dev/null 2>&1; echo exit=$?)"
fi
} > "$R" 2>&1
echo "SLOT=$SLOT"

# B. Direct probes: real Cursor with the spawn-generated guard, wrapped to log the
# hook payload and answer; C. control with a log-only hook (no guard).
R2="$EV/r2-cursor-crew-guard-probe-live.txt"
PROMPT='Run exactly these three shell commands, each as its own separate Shell tool call, in this order, and set no working directory on any of them: 1) `cd /tmp && pwd` 2) `pwd` 3) `git symbolic-ref HEAD`. Then reply with the three outputs and stop. Run nothing else.'
GUARD_CMD=$(jq -r '.hooks.preToolUse[0].command' "$GD/hooks/hooks.json" 2>/dev/null)
mkprobe() { # <dir> <hook-script>
  mkdir -p "$1/.cursor-plugin" "$1/hooks"
  jq -n '{name:"fm-crew-probe",displayName:"probe",version:"1.0.0",description:"lab probe",hooks:"./hooks/hooks.json"}' > "$1/.cursor-plugin/plugin.json"
  jq -n --arg c "$2" '{version:1,hooks:{preToolUse:[{matcher:"Shell",type:"command",command:$c,timeout:10}]}}' > "$1/hooks/hooks.json"
}
cat > "$LAB/hook-guard-log.sh" <<SH
#!/usr/bin/env bash
in=\$(cat)
printf 'IN %s\n' "\$(printf '%s' "\$in" | jq -c '{tool_name, tool_input}')" >> '$LAB/hook-guard.log'
out=\$(printf '%s' "\$in" | sh -c $(printf '%q' "$GUARD_CMD"))
printf 'OUT %s\n' "\${out:-(no decision)}" >> '$LAB/hook-guard.log'
printf '%s' "\$out"
SH
cat > "$LAB/hook-log-only.sh" <<SH
#!/usr/bin/env bash
in=\$(cat)
printf 'IN %s\n' "\$(printf '%s' "\$in" | jq -c '{tool_name, tool_input}')" >> '$LAB/hook-only.log'
SH
chmod +x "$LAB/hook-guard-log.sh" "$LAB/hook-log-only.sh"
mkprobe "$LAB/probe-guard" "$LAB/hook-guard-log.sh"
mkprobe "$LAB/probe-control" "$LAB/hook-log-only.sh"
probe() { # <label> <plugin> <log>
  local s="$LAB/$1-stream.jsonl"
  ( cd "$SLOT" && timeout 240 cursor-agent -p --output-format stream-json --trust --yolo --model grok-4.7-low --plugin-dir "$2" --workspace "$SLOT" "$PROMPT" > "$s" 2> "$LAB/$1.err" ); local rc=$?
  echo "cursor-agent exit=$rc"
  echo "--- shell calls Cursor recorded (command, workingDirectory, stdout or refusal):"
  jq -c 'select(.type=="tool_call" and .subtype=="completed") | .tool_call.shellToolCall // empty | {command: .args.command, workingDirectory: .args.workingDirectory, stdout: (.result.success.stdout // null), refused: (.result.rejected.reason // null)}' "$s" 2>/dev/null | cut -c1-500 | sed 's/^/  | /'
  echo "--- hook log:"
  cut -c1-700 "$3" 2>/dev/null | sed 's/^/  | /'
}
{
echo "task worktree (pin target): $SLOT"
echo "spawn-generated guard command: $GUARD_CMD"
echo
echo "=== B. real Cursor + spawn-generated crew guard (logged)"
probe guard "$LAB/probe-guard" "$LAB/hook-guard.log"
echo
echo "=== C. control: real Cursor, log-only hook, no guard"
probe control "$LAB/probe-control" "$LAB/hook-only.log"
} > "$R2" 2>&1

# D. Cursor secondmate, spawned for real.
R3="$EV/r2-cursor-secondmate-live.txt"
{
echo "secondmate home (outside lab home and repo): $MATE"
echo "state/cursor-dispatch.json before secondmate: $(cat "$LAB/state/cursor-dispatch.json" 2>/dev/null)"
T send-keys -t primary "FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $SM $MATE --harness cursor --model grok-4.7-low --secondmate > $LAB/sm.out 2>&1; echo \$? > $LAB/sm.rc" Enter
waitfile "$LAB/sm.rc" 240 || echo "secondmate spawn did not finish in 240s"
echo "\$ bin/fm-spawn.sh $SM <mate-home> --harness cursor --model grok-4.7-low --secondmate  -> exit $(cat "$LAB/sm.rc" 2>/dev/null)"
sed 's/^/  | /' "$LAB/sm.out"
SWIN=$(sed -n 's/^window=//p' "$LAB/state/$SM.meta" 2>/dev/null)
SLF=$(ls -t /tmp/fm-$SM+*/launch.*.sh 2>/dev/null | head -1)
echo "secondmate window: ${SWIN:-none}; generated launch file: ${SLF:-none}"
if [ -n "$SLF" ]; then
  echo "  wrapper shell: $(grep -o '/bin/[a-z]*sh -c' "$SLF" | head -1)"
  echo "  headless -p: $(grep -c -- " -p " "$SLF"); --output-format: $(grep -c -- '--output-format' "$SLF"); tee: $(grep -c '> >(tee' "$SLF"); guard after: $(grep -c 'fm-cursor-guard.sh' "$SLF")"
fi
sleep 40
PANE_PID=$(T display -p -t "$SWIN" '#{pane_pid}' 2>/dev/null)
echo "--- cursor-agent processes under the secondmate pane (pid $PANE_PID), argv flags:"
pgrep -f "$MATE" | while read -r p; do ps -o args= -p "$p" 2>/dev/null; done | grep -i cursor | grep -v grep | sed -E 's/"[^"]{80,}"/"<brief>"/g' | cut -c1-400 | sed 's/^/  | /'
echo "--- secondmate pane after 40s (capture-pane):"
T capture-pane -p -t "$SWIN" 2>/dev/null | grep -v '^$' | cut -c1-200 | tail -30 | sed 's/^/  | /'
echo "state/cursor-dispatch.json after secondmate: $(cat "$LAB/state/cursor-dispatch.json" 2>/dev/null)"
echo "secondmate launch allowance taken: $(jq -r --arg id "$SM" '.beads[$id] // "no"' "$LAB/state/cursor-dispatch.json" 2>/dev/null)"
T kill-window -t "$SWIN" 2>/dev/null
echo
echo "operator ~/.cursor/cli-config.json sha256 before/after: $cfg_before/$(shasum -a 256 "$HOME/.cursor/cli-config.json" 2>/dev/null | cut -c1-16)"
echo "~/.treehouse entries before/after: $th_before/$(ls "$HOME/.treehouse" 2>/dev/null | wc -l | tr -d ' ')"
echo "gate worktree status after run: $(git -C "$WT" status --porcelain | wc -l | tr -d ' ') changed paths"
echo "task temp dirs: $(ls -d /tmp/fm-$TAG-* 2>/dev/null | tr '\n' ' ')"
} > "$R3" 2>&1
echo DONE
