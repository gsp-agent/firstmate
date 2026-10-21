#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must run the stock macOS Bash check as its stock-macos-bash gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

# This fork's GitHub CI has no macOS job, so the trusted gate is the only
# required stock Bash 3.2 run before push; an upstream merge must not drop it.
test_nm_declares_the_stock_bash_gate() {
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
gate = Array(doc["gates"]).find { |g| g.is_a?(Hash) && g["name"] == "stock-macos-bash" }
puts gate ? "#{gate["after"]} #{gate["command"]}" : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ "$val" = "lint bin/fm-stock-bash-check.sh" ] \
    || fail "the stock-macos-bash gate must run bin/fm-stock-bash-check.sh after lint; got: ${val:-no such gate}"
  [ -x "$ROOT/bin/fm-stock-bash-check.sh" ] || fail "bin/fm-stock-bash-check.sh must be executable"
  pass "no-mistakes runs the stock macOS Bash check as a gate after lint"
}

test_nm_has_no_deterministic_test_command
test_nm_declares_the_stock_bash_gate
