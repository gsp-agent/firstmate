#!/usr/bin/env bash
# Behavior tests for bin/fm-cursor-guard.sh usage fallback.
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

printf '# all fm-cursor-guard tests passed\n'
