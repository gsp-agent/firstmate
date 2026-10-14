#!/usr/bin/env bash
export FM_HOME=$1
EV=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
exec > "$EV/live-counterfactual.log" 2>&1
bin/fm-control.sh lab-cap-normal relaunch --harness grok --note 'Reply only LIVE_REPLAY_counterfactual. Do not use tools or change anything.'
printf 'Explicit Grok (guard bypass) relaunch exit=%s\n' "$?"
printf done > "$EV/live-counterfactual.done"
