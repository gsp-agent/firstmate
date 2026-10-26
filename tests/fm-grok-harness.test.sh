#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  GROK_HOME="$grok_home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

# A fixed `grok inspect --json` inventory, so the worker configuration is
# derived from known discovery rather than whatever grok the host has. Any other
# call records the GROK_HOME it ran under and appends a transcript turn under
# that home's sessions directory, as a launched worker does, so executing a
# launch shows which home the worker would use and where its transcript lands.
# FM_FAKE_GROK_INSPECT_FAIL makes discovery fail.
install_fake_grok() {  # <fakebin>
  cat > "$1/grok" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = inspect ] && [ "${2:-}" = --json ]; then
  if [ -n "${FM_FAKE_GROK_INSPECT_FAIL:-}" ]; then
    echo 'grok: inspect unavailable' >&2
    exit 1
  fi
  printf '%s\n' '{"skills":[{"name":"no-mistakes"},{"name":"poteto-mode"},{"name":"deslop"},{"name":"long-running-background-tasks"}],"mcpServers":[{"name":"notion"},{"name":"gmail"}],"plugins":[{"name":"cursor-plugin"}]}'
  exit 0
fi
printf '%s\n' "${GROK_HOME:-}" > "${FM_FAKE_GROK_HOME_LOG:-/dev/null}"
mkdir -p "${GROK_HOME:?}/sessions/fake-workspace" &&
  printf '%s\n' '{"role":"user","content":"fake worker turn"}' >> "$GROK_HOME/sessions/fake-workspace/chat_history.jsonl"
SH
  chmod +x "$1/grok"
}

# Replace the fixture's minimal brief with a real no-mistakes ship scaffold,
# so the launch brief is rendered from every section a worker receives.
scaffold_ship_brief() {  # <home> <id>
  local home=$1 id=$2 brief filled
  brief="$home/data/$id/brief.md"
  rm -f -- "$brief"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" project --mode no-mistakes >/dev/null || fail "ship scaffold failed"
  filled=$(sed -e 's/{TASK}/Trim the worker launch context./' \
    -e 's/{FIRSTMATE_SPEC}/Exercise the spawn behavior under test./' "$brief")
  printf '%s\n' "$filled" > "$brief"
}

section_of() {  # <file> <level-1 heading>
  awk -v h="$2" '$0 == h { on = 1; print; next } on && /^# / { exit } on { print }' "$1"
}

# The Grok-only context discipline is in the launch text, never in the scaffold.
assert_launch_context_discipline() {  # <brief> <launch-brief>
  local discipline line
  assert_no_grep '# Worker context discipline' "$1" "the scaffold carries the Grok-only context discipline"
  discipline=$(section_of "$2" '# Worker context discipline')
  for line in 'Cap search and grep output near 50 lines' 'Tail or head long command output' \
    'Do not read skills at session start' "the project's \`.agents/skills/<name>/SKILL.md\`" \
    '`~/.agents/skills/<category>/<name>/SKILL.md`' '`~/.claude/skills/<name>/SKILL.md`'; do
    assert_contains "$discipline" "$line" "grok launch brief context discipline lacks: $line"
  done
}

# The no-mistakes intent contract reads to the end of the brief, so it is last.
assert_intent_contract_last() {  # <launch-brief>
  assert_contains "$(section_of "$1" '# Current no-mistakes intent contract')" 'Trim the worker launch context.' \
    "grok launch brief dropped the no-mistakes intent contract"
  assert_equals '## Captain intent authorized for --intent' "$(grep '^#' "$1" | tail -n 1)" \
    "the no-mistakes intent contract is not the last section of the grok launch brief"
}

test_grok_worker_home_trims_launch_context() {
  local rec case_dir home proj wt fakebin grok_home id out status worker_home operator_config launch seen
  rec=$(make_spawn_case worker-home)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  printf '%s\n' 'dummy-test-credential' > "$grok_home/auth.json"
  printf '[models]\ndefault = "grok-code-fast-1"\n' > "$grok_home/config.toml"
  operator_config=$(cat "$grok_home/config.toml")
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok worker spawn should succeed: $out"
  worker_home="$home/state/$id.grok-home"
  python3 -I - "$worker_home/config.toml" <<'PY' || fail "grok worker config does not trim the discovered launch context"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    cfg = tomllib.load(fh)
checks = {
    "compat.claude": cfg["compat"]["claude"] == {"skills": False, "mcps": False},
    "compat.cursor": cfg["compat"]["cursor"] == {"skills": False, "mcps": False},
    "skills.disabled": cfg["skills"]["disabled"] == ["deslop", "poteto-mode"],
    "disabled_mcp_servers": cfg["disabled_mcp_servers"] == ["gmail", "notion"],
    "plugins.disabled": cfg["plugins"]["disabled"] == ["cursor-plugin"],
    "managed_mcps": cfg["managed_mcps"] == {"enabled": False, "gateway_tools_enabled": False},
    "features": cfg["features"] == {"image_gen": False, "video_gen": False},
    "mcp.max_output_bytes": cfg["mcp"]["max_output_bytes"] == 8000,
    "toolset.bash.output_byte_limit": cfg["toolset"]["bash"]["output_byte_limit"] == 8000,
    "models.default": cfg["models"]["default"] == "grok-code-fast-1",
}
failed = [key for key, ok in checks.items() if not ok]
if failed:
    print("mismatched: " + ", ".join(failed), file=sys.stderr)
    sys.exit(1)
PY
  assert_no_grep 'dummy-test-credential' "$worker_home/config.toml" "grok worker config copied credential material"
  [ -L "$worker_home/auth.json" ] || fail "grok worker auth is not a symlink to the operator sign-in"
  [ "$(readlink "$worker_home/auth.json")" = "$grok_home/auth.json" ] || fail "grok worker auth symlink does not reference the operator sign-in"
  [ "$(cat "$grok_home/config.toml")" = "$operator_config" ] || fail "spawn changed the operator grok config"
  launch=$(grep -F 'grok --always-approve' "$case_dir/launch.log" | tail -n 1)
  [ -n "$launch" ] || fail "grok worker spawn sent no launch command"
  FM_FAKE_GROK_HOME_LOG="$case_dir/grok-home.seen" GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    /bin/sh -c "$launch" >/dev/null 2>&1 || fail "grok worker launch failed to run"
  seen=$(cat "$case_dir/grok-home.seen" 2>/dev/null)
  assert_equals "$worker_home" "$seen" "grok worker launch did not run under the per-task worker home"
  pass "grok worker home trims the discovered launch context and the launch runs under it"
}

test_grok_worker_home_resolves_operator_trust_and_policy() {
  local rec case_dir home proj wt fakebin grok_home id out status worker_home
  rec=$(make_spawn_case worker-trust)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  printf '%s\n' '[[folders]]' 'path = "/trusted/root"' > "$grok_home/trusted_folders.toml"
  printf '%s\n' 'Operator global rule.' > "$grok_home/AGENTS.md"
  mkdir -p "$grok_home/rules"
  printf '%s\n' 'Operator rule file.' > "$grok_home/rules/style.md"
  printf '%s\n' '[policy]' > "$grok_home/managed_config.toml"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok worker spawn should succeed: $out"
  worker_home="$home/state/$id.grok-home"
  assert_equals "$(cat "$grok_home/trusted_folders.toml")" "$(cat "$worker_home/trusted_folders.toml" 2>/dev/null)" \
    "grok worker home does not resolve the operator trust store"
  printf '%s\n' '[[folders]]' 'path = "/trusted/later"' >> "$grok_home/trusted_folders.toml"
  assert_contains "$(cat "$worker_home/trusted_folders.toml" 2>/dev/null)" '/trusted/later' \
    "a folder the operator trusts after spawn does not reach the grok worker home"
  assert_equals 'Operator global rule.' "$(cat "$worker_home/AGENTS.md" 2>/dev/null)" \
    "grok worker home does not resolve the operator global instructions"
  assert_equals 'Operator rule file.' "$(cat "$worker_home/rules/style.md" 2>/dev/null)" \
    "grok worker home does not resolve the operator rules directory"
  assert_equals '[policy]' "$(cat "$worker_home/managed_config.toml" 2>/dev/null)" \
    "grok worker home does not resolve the operator managed policy"
  assert_absent "$worker_home/requirements.toml" "grok worker home has a policy file the operator does not have"
  pass "grok worker home resolves the operator trust store, global instructions, and policy"
}

test_grok_worker_skills_file_keeps_listed_skills() {
  local rec case_dir home proj wt fakebin grok_home id out status
  rec=$(make_spawn_case worker-skills)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  printf '%s\n' '# extra skills for this home' '' '  deslop  ' 'not-discovered' > "$home/config/grok-worker-skills"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok worker spawn with a skills file should succeed: $out"
  python3 -I - "$home/state/$id.grok-home/config.toml" <<'PY' || fail "grok worker skills file did not keep the listed skill enabled and the unlisted one disabled"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    cfg = tomllib.load(fh)
if cfg["skills"]["disabled"] != ["poteto-mode"]:
    print("skills.disabled = %r" % cfg["skills"]["disabled"], file=sys.stderr)
    sys.exit(1)
PY
  pass "grok worker skills file keeps a listed skill enabled while an unlisted one is disabled"
}

test_grok_worker_unreadable_skills_file_refuses_before_wiring() {
  local rec case_dir home proj wt fakebin grok_home id out status
  rec=$(make_spawn_case skills-refuse)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  printf '\377\376not utf-8\n' > "$home/config/grok-worker-skills"
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 1 "$status" "a grok spawn with an unreadable skills file should refuse: $out"
  assert_contains "$out" "grok-worker-skills: not UTF-8 text" "the refusal does not name the unreadable skills file"
  assert_absent "$home/state/$id.grok-turnend-token" "a refused grok spawn left its turn-end token"
  assert_absent "$wt/.fm-grok-turnend" "a refused grok spawn left its worktree turn-end pointer"
  assert_absent "$grok_home/hooks" "a refused grok spawn wrote to the operator grok hooks"
  assert_absent "$home/state/$id.grok-home" "a refused grok spawn left a worker home"
  assert_absent "$home/state/$id.meta" "a refused grok spawn left a task record"
  [ ! -s "$case_dir/launch.log" ] || fail "a refused grok spawn sent a launch"

  printf '%s\n' 'deslop' > "$home/config/grok-worker-skills"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "a grok spawn retried after fixing the skills file should succeed: $out"
  pass "an unreadable grok skills file refuses the spawn before any wiring, and a retry succeeds"
}

test_grok_worker_discovery_failure_warns_and_launches() {
  local rec case_dir home proj wt fakebin grok_home id out status
  rec=$(make_spawn_case discovery-fail)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  out=$(FM_FAKE_GROK_INSPECT_FAIL=1 run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "a grok worker spawn whose discovery fails should still launch: $out"
  assert_contains "$out" "warning: Grok worker home $home/state/$id.grok-home: grok inspect --json failed" \
    "a failed grok discovery did not warn that the worker is untrimmed"
  python3 -I - "$home/state/$id.grok-home/config.toml" <<'PY' || fail "a failed grok discovery did not leave the untrimmed worker config with managed connectors off"
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    cfg = tomllib.load(fh)
if cfg["skills"]["disabled"] != [] or cfg["disabled_mcp_servers"] != []:
    sys.exit(1)
if cfg["managed_mcps"] != {"enabled": False, "gateway_tools_enabled": False}:
    print("managed_mcps = %r" % cfg["managed_mcps"], file=sys.stderr)
    sys.exit(1)
PY
  pass "a failed grok discovery warns that the worker is untrimmed and still launches it"
}

test_grok_worker_transcripts_survive_teardown() {
  local rec case_dir home proj wt fakebin grok_home id out status launch transcript
  rec=$(make_spawn_case transcripts)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  assert_absent "$grok_home/sessions" "the operator grok home already had a sessions directory"
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok worker spawn should succeed: $out"
  launch=$(grep -F 'grok --always-approve' "$case_dir/launch.log" | tail -n 1)
  [ -n "$launch" ] || fail "grok worker spawn sent no launch command"
  assert_equals 700 "$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$home/state/$id.grok-home")" \
    "the grok worker home is not private"
  GROK_HOME="$grok_home" PATH="$fakebin:$PATH" /bin/sh -c "$launch" >/dev/null 2>&1 || fail "grok worker launch failed to run"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$home/state/$id.grok-home" "teardown left the grok worker home"
  assert_equals 700 "$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$grok_home/sessions")" \
    "the operator sessions directory provisioning created is not private"
  transcript="$grok_home/sessions/fake-workspace/chat_history.jsonl"
  assert_present "$transcript" "grok worker transcript did not survive teardown in the operator sessions directory"
  assert_grep 'fake worker turn' "$transcript" "grok worker transcript lost its content"
  pass "grok worker transcripts land in the operator sessions directory and survive teardown"
}

test_grok_slim_launch_brief_defers_only_later_sections() {
  local rec case_dir home proj wt fakebin grok_home id out status brief launch_brief heading status_cmd
  rec=$(make_spawn_case slim-brief)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  : > "$home/config/wait-no-turns"
  printf '%s\n' 'Home addition: keep commits small.' > "$home/config/brief-include.md"
  scaffold_ship_brief "$home" "$id"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok worker spawn should succeed: $out"
  brief="$home/data/$id/brief.md"
  launch_brief="$home/data/$id/launch-brief.md"
  for heading in '# Waiting' '# Project memory' '# Definition of done'; do
    grep -qxF -- "$heading" "$brief" || fail "ship scaffold has no $heading section to defer"
    ! grep -qxF -- "$heading" "$launch_brief" || fail "grok launch brief inlined the later-read $heading section"
    assert_grep "- \`$heading\` before " "$launch_brief" "grok launch brief does not point at the deferred $heading section"
  done
  for heading in '# Task' '# Herdr lifecycle declaration - NOT ENABLED' '# Setup' '# Rules' \
    '# Firstmate instruction inbox' '# Home brief additions'; do
    [ -n "$(section_of "$brief" "$heading")" ] || fail "ship scaffold has no $heading section"
    assert_equals "$(section_of "$brief" "$heading")" "$(section_of "$launch_brief" "$heading")" \
      "grok launch brief did not carry the $heading section verbatim"
  done
  for heading in '# Setup' '# Rules' '# Home brief additions'; do
    assert_contains "$(section_of "$launch_brief" '# Full brief')" "\`$heading\`" \
      "grok launch brief pointer does not name the carried $heading section"
  done
  status_cmd=$(awk 'found { sub(/^[[:space:]]+/, ""); print; exit } /^4\. Report status by appending one line:$/ { found = 1 }' "$brief")
  assert_contains "$status_cmd" 'fm-fleet-ledger.sh' "ship scaffold status command has no fleet-ledger call"
  assert_contains "$(section_of "$launch_brief" '# Rules')" "$status_cmd" "grok launch brief does not carry the brief's own status command"
  grep -qxF -- 'Delivery contract: mode=no-mistakes' "$launch_brief" || fail "grok launch brief does not carry the delivery contract"
  assert_grep "The complete brief is at \`$brief\`." "$launch_brief" "grok launch brief did not name the full brief"
  assert_launch_context_discipline "$brief" "$launch_brief"
  assert_intent_contract_last "$launch_brief"
  [ "$(wc -c < "$launch_brief")" -lt "$(wc -c < "$brief")" ] || fail "grok launch brief is not smaller than the full brief"

  printf '\n## Progress note (2026-10-26T00:00:00Z)\n\nThis task was relaunched. Continue from here.\nprogress-marker-relaunch\n' >> "$brief"
  # The relaunch needs the recorded window present with only a shell left in it.
  mkdir -p "$case_dir/relaunch-bin"
  cat > "$case_dir/relaunch-bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *list-windows*) printf '%s\n' 'fm-$id'; exit 0 ;;
  *'#{pane_current_command}'*) printf '%s\n' zsh; exit 0 ;;
esac
exec '$fakebin/tmux' "\$@"
SH
  chmod +x "$case_dir/relaunch-bin/tmux"
  out=$(GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    fm_test_run_spawn "$home" "$wt" "$case_dir/relaunch-bin" "$id" --relaunch --harness grok)
  status=$?
  expect_code 0 "$status" "grok relaunch should succeed: $out"
  assert_grep 'progress-marker-relaunch' "$launch_brief" "grok relaunch dropped the progress note"
  grep -qxF -- '# Definition of done' "$launch_brief" || fail "grok relaunch did not take the full launch brief"
  assert_launch_context_discipline "$brief" "$launch_brief"
  assert_intent_contract_last "$launch_brief"

  # A restore launches without --relaunch, and with no home brief additions its
  # note ends the Definition of done the slim brief would leave out.
  rec=$(make_spawn_case slim-restore)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  install_fake_grok "$fakebin"
  scaffold_ship_brief "$home" "$id"
  brief="$home/data/$id/brief.md"
  launch_brief="$home/data/$id/launch-brief.md"
  printf '\n## Restore note (2026-10-26T00:00:00Z)\n\nThis task was closed before its done was met and has been restored from its archived record.\nrestore-marker-remaining-work\n' >> "$brief"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "a restored grok worker spawn should succeed: $out"
  assert_grep 'restore-marker-remaining-work' "$launch_brief" "a restored grok worker launch dropped the restore note"
  grep -qxF -- '# Definition of done' "$launch_brief" || fail "a restored grok worker did not take the full launch brief"
  assert_launch_context_discipline "$brief" "$launch_brief"
  assert_intent_contract_last "$launch_brief"
  pass "grok slim launch brief defers only later-read sections, and a relaunch or restore takes the full brief"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
test_grok_worker_home_trims_launch_context
test_grok_worker_home_resolves_operator_trust_and_policy
test_grok_worker_skills_file_keeps_listed_skills
test_grok_worker_unreadable_skills_file_refuses_before_wiring
test_grok_worker_discovery_failure_warns_and_launches
test_grok_worker_transcripts_survive_teardown
test_grok_slim_launch_brief_defers_only_later_sections
