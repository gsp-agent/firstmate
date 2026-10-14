#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor-guard.sh (per-bead stop, usage fallback, limit
# record) and for the cursor pane command keeping the agent's exit status.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-cursor-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-guard)
export FM_STATE_OVERRIDE="$TMP_ROOT/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" FM_CURSOR_USAGE_DIR="$TMP_ROOT/usage"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_CURSOR_USAGE_DIR"
export FM_PSTACK_DIR="$TMP_ROOT/pstack"; mkdir -p "$FM_PSTACK_DIR/.cursor-plugin"
printf '{"name":"pstack","version":"0.15.21"}\n' > "$FM_PSTACK_DIR/.cursor-plugin/plugin.json"
STATEFILE="$FM_STATE_OVERRIDE/cursor-dispatch.json"

g() { local day=$1; shift; FM_CURSOR_DAY=$day "$TOOL" "$@" 2> "$TMP_ROOT/err"; }

# No distinct-bead cap: many beads launch.
for i in 1 2 3 4 5 6 7 8; do g 2030-01-01 take "b$i"; expect_code 0 $? "bead b$i launches (no daily cap)"; done
g 2030-01-01 take b1; expect_code 0 $? "a relaunch is allowed"
g 2030-01-01 take b1; expect_code 1 $? "the 3rd launch of one bead in a day is refused"
assert_contains "$(cat "$TMP_ROOT/err")" "refused b1" "refusal names the bead"
[ "$(wc -l < "$TMP_ROOT/err" | tr -d ' ')" = 1 ] || fail "refusal must be one line"
pass "no distinct-bead cap; a bead's 3rd launch in a day is refused"

g 2030-01-01 give b2; g 2030-01-01 take b2
[ "$(jq -r '.beads.b2' "$STATEFILE")" = 1 ] || fail "give then take should leave one launch"
g 2030-01-01 give b1; g 2030-01-01 take b1; expect_code 0 $? "give returns one launch of a relaunched bead"
pass "failed spawns give the launch back"

g 2030-01-02 take d; expect_code 0 $? "a new day resets"
[ "$(jq -c '.' "$STATEFILE")" = '{"day":"2030-01-02","beads":{"d":1}}' ] || fail "day rollover: $(cat "$STATEFILE")"
pass "day rollover resets the count"

mkdir "$FM_STATE_OVERRIDE/cursor-dispatch.lock"
( sleep 1; rmdir "$FM_STATE_OVERRIDE/cursor-dispatch.lock" ) &
g 2030-01-03 take y; expect_code 0 $? "waits for a held mkdir lock"
wait
mkdir "$FM_STATE_OVERRIDE/cursor-dispatch.lock"
touch -t 200001010000 "$FM_STATE_OVERRIDE/cursor-dispatch.lock"
g 2030-01-03 take z; expect_code 0 $? "a stale lock does not stall dispatch"
assert_contains "$(cat "$TMP_ROOT/err")" "removed a stale lock" "stale lock removal is announced"
[ "$(wc -l < "$TMP_ROOT/err" | tr -d ' ')" = 1 ] || fail "stale lock notice must be one line"
[ ! -e "$FM_STATE_OVERRIDE/cursor-dispatch.lock" ] || fail "lock must be released"
pass "mkdir lock honoured; a stale one is removed"

# ---- fallback: no model judgment ----
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
# newest file wins by mtime; thresholds come from crew-dispatch.json
printf 'cursor_models_pct=10\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = cursor ] || fail "the newest fresh low file must keep cursor"
printf '{"cursor_fallback":{"models_pct":10,"max_age_h":26}}\n' > "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
case "$(fb e1)" in "codex Cursor Models at 10% (limit 10%)") ;; *) fail "threshold must come from crew-dispatch.json: $(fb e1)" ;; esac
rm -f "$FM_CONFIG_OVERRIDE/crew-dispatch.json"
# the live 89% reading goes to codex; a codex-limit marker sends the bead to claude
printf 'cursor_models_pct=89\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = "codex Cursor Models at 89% (limit 85%)" ] || fail "89% must fall back to codex: $(fb e1)"
printf 'codex run for e1 hit its usage limit\n' > "$FM_STATE_OVERRIDE/e1.codex-limit"
[ "$(fb e1)" = "claude Cursor Models at 89% (limit 85%); codex run for e1 hit its usage limit" ] || fail "a codex-limit marker must fall back to claude: $(fb e1)"
[ "$(fb e2)" = "codex Cursor Models at 89% (limit 85%)" ] || fail "another bead's codex-limit must not move this one: $(fb e2)"
rm -f "$FM_STATE_OVERRIDE/e1.codex-limit"
printf 'cursor_models_pct=10\n' > "$FM_CURSOR_USAGE_DIR/20261013-spending.txt"
[ "$(fb e1)" = cursor ] || fail "under the limit must stay on cursor: $(fb e1)"
pass "fallback at 84/85/89, missing file, stale file, bad value; codex first, claude after a codex limit"

# real fixture shape (Chip-Grok's 2026-10-12-1512-spending.txt)
printf 'cursor_models_pct=26\nother_models_pct=45\non_demand=disabled\ncycle_resets=2026-10-14\nread_at=2026-10-12T15:12-05:00\n' > "$FM_CURSOR_USAGE_DIR/20261014-spending.txt"
[ "$(fb e1)" = cursor ] || fail "the real spending file shape at 26% must keep cursor: $(fb e1)"
printf '{"name":"pstack","version":"0.15.22"}\n' > "$FM_PSTACK_DIR/.cursor-plugin/plugin.json"
case "$(fb e1)" in "grok pstack plugin version is '0.15.22', not the pinned 0.15.21") ;; *) fail "a different pstack version must fall back: $(fb e1)" ;; esac
printf 'cursor_models_pct=89\n' > "$FM_CURSOR_USAGE_DIR/20261015-spending.txt"
[ "$(fb e1)" = "codex Cursor Models at 89% (limit 85%)" ] || fail "an off-pin pstack with a short pool must go to codex, not grok: $(fb e1)"
rm -f "$FM_CURSOR_USAGE_DIR/20261015-spending.txt"
printf '{"name":"pstack","version":"0.15.21"}\n' > "$FM_PSTACK_DIR/.cursor-plugin/plugin.json"
pass "an off-pin pstack falls back to grok only while the pool is fine; a short pool still goes to codex"

# ---- a usage-limit error is recorded, then the bead routes to codex ----
printf '{"type":"error","message":"429 usage limit reached"}\n' > "$FM_STATE_OVERRIDE/u1.cursor-stream.jsonl"
"$TOOL" after u1 3 2>/dev/null; expect_code 3 $? "after exits with the agent's status"
[ -s "$FM_STATE_OVERRIDE/u1.cursor-limit" ] || fail "usage-limit error was not recorded"
case "$(fb u1)" in codex*) ;; *) fail "a recorded usage limit must route to codex: $(fb u1)" ;; esac
printf '{"type":"error","message":"429 usage limit reached"}\n' > "$FM_STATE_OVERRIDE/u2.cursor-stream.jsonl"
"$TOOL" after u2 0 2>/dev/null; expect_code 0 $? "after passes rc 0 through"
[ ! -e "$FM_STATE_OVERRIDE/u2.cursor-limit" ] || fail "a successful run must not record a limit"
printf '{"type":"error","message":"tool failed"}\n' > "$FM_STATE_OVERRIDE/u3.cursor-stream.jsonl"
"$TOOL" after u3 1 2>/dev/null; expect_code 1 $? "after passes other failures through"
[ ! -e "$FM_STATE_OVERRIDE/u3.cursor-limit" ] || fail "an unrelated failure must not record a limit"
pass "a usage-limit error is recorded and the bead's next launch goes to codex"

printf '%s\n' '{"type":"tool_call","result":{"isEmpty":false,"exceededLimit":false,"totalLines":12}}' > "$FM_STATE_OVERRIDE/u4.cursor-stream.jsonl"
"$TOOL" after u4 1 2>/dev/null; expect_code 1 $? "after passes a nonzero exit when the stream only carries exceededLimit false"
[ ! -e "$FM_STATE_OVERRIDE/u4.cursor-limit" ] || fail "exceededLimit false must not record a usage limit"
[ "$(fb u4)" = cursor ] || fail "exceededLimit false must keep the next launch on cursor: $(fb u4)"
printf '%s\n' '{"type":"error","message":"You have exceeded your usage quota"}' > "$FM_STATE_OVERRIDE/u5.cursor-stream.jsonl"
"$TOOL" after u5 2 2>/dev/null; expect_code 2 $? "after passes the exceeded-quota exit status through"
[ -s "$FM_STATE_OVERRIDE/u5.cursor-limit" ] || fail "an exceeded-quota line must record a usage limit"
case "$(fb u5)" in codex*) ;; *) fail "an exceeded-quota line must route the next launch to codex: $(fb u5)" ;; esac
pass "exceededLimit false is not a usage limit; an exceeded-quota line is"

# The pane command keeps the agent's exit status past the tee, in bash and zsh.
tpl=$(grep -o '> >(tee __CURSORSTREAM__)' "$ROOT/bin/fm-spawn.sh" | head -1)
[ -n "$tpl" ] || fail "cursor template no longer tees through process substitution"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  "$sh" -c "(echo out; exit 7) ${tpl//__CURSORSTREAM__/\"$TMP_ROOT/stream.jsonl\"}"
  expect_code 7 $? "$sh: pane command exits with the agent's status, not tee's"
done
pass "cursor exit code survives the tee"

printf '# all fm-cursor-guard tests passed\n'
