#!/usr/bin/env bash
# Live fault-A scenarios against real Claude Code in an isolated fm-lab-* Herdr
# session. HEAD = this change's bin/; BASE = base commit 20dcbf91's bin/.
# Every adapter herdr call is routed through bin/fm-herdr-lab.sh run.
set -u
. "$(cat "${TMPDIR:-/tmp}/fm-xbvre-live.path")/env.sh"
PANE=$(cat "$SCRATCH/pane"); TARGET="$SESSION:$PANE"
api() { python3 -I "$SCRATCH/herdr-lab-api.py" "$SESSION" "$(cat "$SCRATCH/socket")" "$@"; }
scroll_to() { api pane.scroll "{\"pane_id\":\"$1\",\"offset_from_bottom\":$2}" | jq -c '.result.pane.scroll'; }
submit() {  # <root> <text>
  env -u HERDR_PANE_ID -u HERDR_SESSION PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit "$2" "$3" 3 0.4 1.2' _ "$1" "$TARGET" "$2"
}
state_of() {  # <root> <target>
  env -u HERDR_PANE_ID -u HERDR_SESSION PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$2"' _ "$1" "$2"
}
step() { printf '\n== %s\n' "$*"; }
printf 'herdr %s (lab session fm-lab-*, isolated), %s\n' "$(PATH=$ORIGINAL_PATH herdr --version | awk '{print $2}')" "$(PATH=$ORIGINAL_PATH claude --version)"

step "S1 unscrolled empty composer"
scroll_to "$PANE" 0 >/dev/null; "$SCRATCH/probe.sh" S1

step "S2 fault A: user scrolled 150 rows up into old output; composer is empty"
scroll_to "$PANE" 150 >/dev/null; "$SCRATCH/probe.sh" S2
"$SCRATCH/revive-gate.sh" "$WT"; "$SCRATCH/revive-gate.sh" "$SCRATCH/base"

step "S3 scrolled pane with a typed draft must not read empty"
PATH=$ORIGINAL_PATH lab pane send-text "$PANE" "fm draft probe" >/dev/null; sleep 1.2
"$SCRATCH/probe.sh" S3
"$SCRATCH/revive-gate.sh" "$WT"
v=$(submit "$WT" "reset"); printf '[S3] HEAD send_text_submit "reset" onto the scrolled draft -> %s\n' "$v"; sleep 1
"$SCRATCH/probe.sh" S3-after-send | sed -n 2p
lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 1

step "S4 scrolled pane with Claude's slash popup open over a typed /clear"
scroll_to "$PANE" 150 >/dev/null
lab pane send-text "$PANE" "/clear" >/dev/null; sleep 1.5
"$SCRATCH/probe.sh" S4
"$SCRATCH/revive-gate.sh" "$WT"
lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 1

step "S5 the planned reset: gate passes on the scrolled empty composer, then /clear is sent as the revive job does"
scroll_to "$PANE" 150 >/dev/null
gate=$("$SCRATCH/revive-gate.sh" "$WT"); echo "$gate"
case "$gate" in *PASSES*) out=$(lab agent prompt "$PANE" "/clear" 2>&1); printf '[S5] herdr agent prompt %s /clear -> rc=%s %s\n' "$PANE" "$?" "$(printf '%s' "$out" | jq -r '.result.type // "?"' 2>/dev/null)";; esac
sleep 4
n=$(env -u HERDR_PANE_ID -u HERDR_SESSION PATH="$SCRATCH/fakebin:$ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_capture "$2"' _ "$WT" "$TARGET" | grep -c '^❯ /clear')
printf '[S5] current screen shows %s submitted "❯ /clear" row(s) above the composer\n' "$n"
"$SCRATCH/probe.sh" S5-after-reset

step "S6 adversarial: plain shell pane (prompt glyph ╰─❯, no agent), scrolled vs unscrolled"
SPLIT=$(lab pane split "$PANE" --direction right --cwd "$SCRATCH/cwd" --no-focus | jq -er '.result.pane.pane_id // .result.pane_id')
sleep 4
lab pane run "$SPLIT" "for i in \$(seq 1 200); do echo \"shell scrollback line \$i\"; done" >/dev/null; sleep 3
printf '[S6] unscrolled: HEAD=%s BASE=%s\n' "$(state_of "$WT" "$SESSION:$SPLIT")" "$(state_of "$SCRATCH/base" "$SESSION:$SPLIT")"
printf '[S6] scroll=%s\n' "$(scroll_to "$SPLIT" 80)"
printf '[S6] scrolled 80: HEAD=%s BASE=%s\n' "$(state_of "$WT" "$SESSION:$SPLIT")" "$(state_of "$SCRATCH/base" "$SESSION:$SPLIT")"
lab pane send-text "$SPLIT" "echo shell draft" >/dev/null; sleep 1; scroll_to "$SPLIT" 80 >/dev/null
printf '[S6] scrolled 80 with typed shell text: HEAD=%s BASE=%s\n' "$(state_of "$WT" "$SESSION:$SPLIT")" "$(state_of "$SCRATCH/base" "$SESSION:$SPLIT")"
lab pane close "$SPLIT" >/dev/null; sleep 1

step "S7 typed /exit behind the slash popup (unscrolled) is proven and submitted"
scroll_to "$PANE" 0 >/dev/null
lab pane send-text "$PANE" "/exit" >/dev/null; sleep 1.5
"$SCRATCH/probe.sh" S7
lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 1
v=$(submit "$SCRATCH/base" "/exit"); printf '[S7] BASE send_text_submit /exit -> %s; agent after: %s\n' "$v" "$(lab pane get "$PANE" | jq -r '.result.pane.agent // "none"')"
sleep 1
v=$(submit "$WT" "/exit"); 
for i in $(seq 1 20); do a=$(lab pane get "$PANE" | jq -r '.result.pane.agent // "none"'); [ "$a" = none ] && break; sleep 1; done
printf '[S7] HEAD send_text_submit /exit -> %s; agent after: %s\n' "$v" "$a"
