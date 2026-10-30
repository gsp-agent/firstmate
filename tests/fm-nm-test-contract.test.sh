#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# must run the stock macOS Bash check as its stock-macos-bash gate, and must
# keep the trusted gate-agent pin compatible with project-instruction isolation.
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
# It runs on the Mac mini, and the Test step's suites go to that same host.
test_nm_declares_the_stock_bash_gate() {
  local val spec
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
gate = Array(doc["gates"]).find { |g| g.is_a?(Hash) && g["name"] == "stock-macos-bash" }
puts gate ? "#{gate["after"]} #{gate["command"]}" : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  case "$val" in
    "lint bin/fm-stock-bash-check.sh --remote "?*:/?*) spec=${val#lint bin/fm-stock-bash-check.sh --remote } ;;
    *) fail "the stock-macos-bash gate must run bin/fm-stock-bash-check.sh --remote <host>:<scratch-root> after lint; got: ${val:-no such gate}" ;;
  esac
  [ -x "$ROOT/bin/fm-stock-bash-check.sh" ] || fail "bin/fm-stock-bash-check.sh must be executable"
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
text = ((doc["test"] || {})["instructions"]).to_s
abort "test.instructions must send suites through bin/fm-test-run.sh --remote #{ARGV[1]}" unless text.include?("bin/fm-test-run.sh --remote #{ARGV[1]} ")
' "$NM" "$spec" || fail "the Test step's suites must run on the gate's host"
  pass "no-mistakes runs the stock macOS Bash check after lint, and the Test step's suites, on the same remote host"
}

test_nm_pins_gate_to_claude_then_codex() {
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
abort "disable_project_settings must remain true" unless doc["disable_project_settings"] == true
abort "gate agents must stay pinned to [claude, codex] while Grok cannot isolate project instructions" unless doc["agent"] == ["claude", "codex"]
' "$NM" || fail "trusted gate-agent isolation configuration is unsafe"
  pass "no-mistakes pins Claude then Codex while disabling project instructions"
}

test_nm_has_no_deterministic_test_command
test_nm_declares_the_stock_bash_gate
test_nm_pins_gate_to_claude_then_codex
