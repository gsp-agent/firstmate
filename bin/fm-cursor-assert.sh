#!/usr/bin/env bash
# fm-cursor-assert.sh - re-assert the Cursor settings a pstack code worker needs,
# before every cursor run. Any other `agent --model` run rewrites them, so this
# runs on every spawn and relaunch (bin/fm-spawn.sh, cursor case).
#
#   ~/.cursor/cli-config.json  network.useHttp1ForAgent=true (HTTP/2 is torn
#       down under concurrency); modelParameters["grok-4.7"] = 256k / xhigh /
#       fast false, so a Task subagent never silently runs grok-4.7-xhigh-fast.
#   ~/.cursor/rules/pstack-models.mdc  pstack's per-role models, all
#       grok-4.7-xhigh, with gpt-5.6-sol-xhigh as the cross-family second
#       entry on panels. No Opus model appears, so a Cursor fan-out never
#       selects one (Opus runs only on the Claude harness, label ep-opus).
#
# Overrides for tests: FM_CURSOR_CLI_CONFIG, FM_CURSOR_MODELS_RULE.
set -eu
CFG=${FM_CURSOR_CLI_CONFIG:-$HOME/.cursor/cli-config.json}
RULE=${FM_CURSOR_MODELS_RULE:-$HOME/.cursor/rules/pstack-models.mdc}
command -v jq >/dev/null 2>&1 || { echo "error: jq required to re-assert $CFG" >&2; exit 1; }
mkdir -p "$(dirname "$CFG")" "$(dirname "$RULE")"
[ -s "$CFG" ] || printf '{}\n' > "$CFG"
tmp=$(mktemp "$CFG.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq '.network.useHttp1ForAgent = true
  | .modelParameters["grok-4.7"] = [
      {"id":"context","value":"256k"},
      {"id":"reasoning_effort","value":"xhigh"},
      {"id":"fast","value":"false"}]' "$CFG" > "$tmp" \
  || { echo "error: $CFG is not valid JSON; not rewriting it" >&2; exit 1; }
chmod 600 "$tmp"
mv "$tmp" "$CFG"
trap - EXIT

G=grok-4.7-xhigh
P="$G, gpt-5.6-sol-xhigh"
cat > "$RULE" <<MDC
---
description: pstack per-role model choices (overrides skill defaults)
alwaysApply: true
---
# Written by firstmate bin/fm-cursor-assert.sh before every cursor run. Do not edit.
# No Opus model on purpose: Opus runs only on the Claude harness.
feature, refactoring: $G
bug-fix: $G
perf-issue: $G
hillclimb: $G
judgment and prose: $G
hardest tasks: $G
how explorer: $G
how explainer: $G
why investigators: $G
why synthesizer: $G
reflect tooling: $G
reflect judgment, divergent, synthesizer: $G
arena runners: $P
arena cross-judge pool: $P
swarm workers: $G
architect runners: $P
interrogate reviewers: $P
MDC
