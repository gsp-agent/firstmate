#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor-guard.sh usage fallback and for
# bin/fm-cursor-crew-guard.mjs, the preToolUse hook a crew session loads.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-cursor-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-guard)
export FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" FM_CURSOR_USAGE_DIR="$TMP_ROOT/usage"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_CURSOR_USAGE_DIR"

fb() { "$TOOL" fallback "$1" 2>/dev/null; }
[ "$(fb e1)" = "$(printf 'codex no Cursor spending file in %s' "$FM_CURSOR_USAGE_DIR")" ] || fail "missing file must fall back: $(fb e1)"
printf 'cursor_models_pct=84\nother=1\n' > "$FM_CURSOR_USAGE_DIR/20261012-spending.txt"
[ "$(fb e1)" = cursor ] || fail "84% must stay on cursor: $(fb e1)"
printf 'cursor_models_pct=85\n' > "$FM_CURSOR_USAGE_DIR/20261012-spending.txt"
case "$(fb e1)" in "codex Cursor Models at 85%"*) ;; *) fail "85% must fall back: $(fb e1)" ;; esac
printf 'cursor_models_pct=abc\n' > "$FM_CURSOR_USAGE_DIR/20261012-spending.txt"
case "$(fb e1)" in codex*) ;; *) fail "a non-integer pct must fall back" ;; esac
printf 'cursor_models_pct=10\n' > "$FM_CURSOR_USAGE_DIR/20261012-spending.txt"
touch -t 200001010000 "$FM_CURSOR_USAGE_DIR/20261012-spending.txt"
case "$(fb e1)" in "codex newest Cursor spending file is"*) ;; *) fail "a stale file must fall back: $(fb e1)" ;; esac
printf 'cursor_models_pct=10\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = cursor ] || fail "the newest fresh low file must keep cursor"
printf '{"cursor_fallback":{"models_pct":10,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
case "$(fb e1)" in "codex Cursor Models at 10% (limit 10%)") ;; *) fail "threshold must come from crew-dispatch.json: $(fb e1)" ;; esac
printf 'cursor_models_pct=86\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
printf '{"cursor_fallback":{"models_pct":85.5,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
[ "$(fb e1)" = "codex cursor_fallback.models_pct '85.5' in crew-dispatch.json is not an integer" ] || fail "a fractional threshold must fall back: $(fb e1)"
printf '{"cursor_fallback":{"models_pct":85,"max_age_h":0.5}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
[ "$(fb e1)" = "codex cursor_fallback.max_age_h '0.5' in crew-dispatch.json is not an integer" ] || fail "a fractional age must fall back: $(fb e1)"
printf '{"cursor_fallback":{"models_pct":85.0,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
[ "$(fb e1)" = "codex Cursor Models at 86% (limit 85%)" ] || fail "an integral 85.0 threshold must apply as 85: $(fb e1)"
rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
printf 'cursor_models_pct=89\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = "codex Cursor Models at 89% (limit 85%)" ] || fail "89% must fall back to codex: $(fb e1)"
printf 'codex run for e1 hit its usage limit\n' > "$FM_STATE_OVERRIDE/e1.codex-limit"
[ "$(fb e1)" = "claude Cursor Models at 89% (limit 85%); codex run for e1 hit its usage limit" ] || fail "a codex-limit marker must fall back to claude: $(fb e1)"
[ "$(fb e2)" = "codex Cursor Models at 89% (limit 85%)" ] || fail "another bead's codex-limit must not move this one: $(fb e2)"
rm -f "$FM_STATE_OVERRIDE/e1.codex-limit"
printf 'cursor_models_pct=10\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = cursor ] || fail "under the limit must stay on cursor: $(fb e1)"
pass "fallback at 84/85/89, missing file, stale file, bad value; codex first, claude after a codex limit"

# ---- crew guard: the preToolUse hook a crew session loads ----
CREW_GUARD="$ROOT/bin/fm-cursor-crew-guard.mjs"
SLOT="$TMP_ROOT/slot"
# crew_hook <command> [cwd]: Cursor's preToolUse payload for a Shell call.
crew_hook() { jq -nc --arg c "$1" --arg d "${2-}" '{tool_name:"Shell",tool_input:{command:$c,cwd:$d}}' | node "$CREW_GUARD" --worktree "$SLOT"; }

while IFS= read -r cmd; do
  out=$(crew_hook "$cmd" "$SLOT")
  [ "$(printf '%s' "$out" | jq -r '.permission // empty')" = deny ] || fail "the crew guard must refuse: $cmd"
done <<'CMDS'
git symbolic-ref HEAD refs/heads/fm/x
git branch fm/x && git symbolic-ref HEAD refs/heads/fm/x
git update-ref -d refs/heads/fm/x
git -C /tmp/primary symbolic-ref HEAD refs/heads/x
/usr/bin/git -c core.pager=cat --no-pager update-ref HEAD abc123
env GIT_DIR=/tmp/p/.git git update-ref HEAD abc123
sudo git update-ref HEAD abc123
echo $(git symbolic-ref --short HEAD)
(git update-ref -d refs/heads/fm/x)
if true; then git symbolic-ref HEAD refs/heads/x; fi
bash -c 'git symbolic-ref HEAD refs/heads/x'
git-update-ref HEAD abc123
env -S 'git -C /primary symbolic-ref HEAD refs/heads/main'
if true; then env git -C /primary symbolic-ref HEAD refs/heads/main; fi
CMDS
while IFS= read -r cmd; do
  out=$(crew_hook "$cmd" "$SLOT")
  [ -z "$out" ] || fail "the crew guard must leave this alone: $cmd -> $out"
done <<'CMDS'
git status
git switch -c fm/x
git checkout -b fm/x --
git branch --show-current
git for-each-ref refs/heads
rg -n symbolic-ref bin
echo 'git update-ref' | cat
git commit -m 'document symbolic-ref handling'
CMDS
out=$(crew_hook 'git symbolic-ref HEAD refs/heads/x' "$SLOT")
assert_contains "$out" 'git branch --show-current' "the refusal must name the read alternative"
assert_contains "$out" 'git switch -c' "the refusal must name the branch-creating alternative"
assert_contains "$out" 'blocked [at=<epoch>]' "the refusal must say a refused command is a stop"
pass "crew guard: refuses git symbolic-ref and update-ref in every command position, leaves reads and branch creation alone"

out=$(crew_hook 'pwd' '')
[ "$(printf '%s' "$out" | jq -c '.')" = "{\"permission\":\"allow\",\"updated_input\":{\"command\":\"pwd\",\"cwd\":\"$SLOT\"}}" ] \
  || fail "an empty working directory must be rewritten to the worktree: $out"
[ -z "$(crew_hook 'pwd' /elsewhere)" ] || fail "an explicit working directory must be left alone"
[ -z "$(printf '{"tool_name":"Read","tool_input":{"path":"x"}}' | node "$CREW_GUARD" --worktree "$SLOT")" ] \
  || fail "a non-Shell tool must be left alone"
[ -z "$(jq -nc '{tool_name:"Shell",tool_input:{command:"pwd",cwd:""}}' | node "$CREW_GUARD")" ] \
  || fail "without --worktree there is nothing to pin to"
out=$(printf 'not json' | node "$CREW_GUARD" --worktree "$SLOT"); expect_code 0 $? "unparseable input must fail open"
[ -z "$out" ] || fail "unparseable input must produce no decision"
pass "crew guard: pins an empty working directory, leaves explicit ones, other tools and bad input alone"

printf '# all fm-cursor-guard tests passed\n'
