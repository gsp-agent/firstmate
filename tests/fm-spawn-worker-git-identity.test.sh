#!/usr/bin/env bash
# tests/fm-spawn-worker-git-identity.test.sh - every agent commits as gsp-agent
# or the configured identity, without writing the captain's global git config
# or the project's shared repository config.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received, under a synthetic pane environment whose global git
# config holds a captain identity, with the harness binary replaced by a probe
# that reads git's identity and makes a commit. What the probe reports is what a
# real agent's first commit would carry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-git-identity)

AGENT_NAME='Fleet Agent'
AGENT_EMAIL='fleet-agent@example.invalid'
AGENT_IDENT="$AGENT_NAME <$AGENT_EMAIL>"
CAPTAIN_GITCONFIG="$TMP_ROOT/captain.gitconfig"
printf '[user]\n\tname = Captain Person\n\temail = captain@example.invalid\n' > "$CAPTAIN_GITCONFIG"

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

install_git_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf 'name=%s\n' "$(git config user.name)"
printf 'email=%s\n' "$(git config user.email)"
printf 'hooks=%s\n' "$(git config core.hooksPath)"
git commit -q --allow-empty -m 'probe: first worker commit' || exit 1
printf 'author=%s\n' "$(git log -1 --format='%an <%ae>')"
printf 'committer=%s\n' "$(git log -1 --format='%cn <%ce>')"
SH
  chmod +x "$1/$2"
}

# Replay the pane exports and the emitted launch in <dir>, the way the pane
# shell would run them, with the captain's identity as the global git config.
emitted_launch_git() {  # <fakebin> <launch-log> <pane-log> <dir> [NAME=value]...
  local launch preamble fakebin=$1 dir=$4
  launch=$(cat "$2")
  preamble=$(grep '^export ' "$3")
  shift 4
  (cd "$dir" && env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane GIT_CONFIG_GLOBAL="$CAPTAIN_GITCONFIG" GIT_CONFIG_NOSYSTEM=1 \
    "$@" /bin/sh -c "$preamble
$launch")
}

probe_field() {  # <probe-output> <field>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

file_sum() { cksum < "$1"; }

assert_agent_commit() {  # <probe-output> <label> [name] [email]
  local name=${3:-$AGENT_NAME} email=${4:-$AGENT_EMAIL}
  assert_equals "$name" "$(probe_field "$1" name)" "$2: git config user.name"
  assert_equals "$email" "$(probe_field "$1" email)" "$2: git config user.email"
  assert_equals "$name <$email>" "$(probe_field "$1" author)" "$2: the first commit's author"
  assert_equals "$name <$email>" "$(probe_field "$1" committer)" "$2: the first commit's committer"
}

test_ship_commits_as_the_configured_identity() {
  local rec id out status seen captain_before shared_before state
  id=ident-ship-a1
  rec=$(make_case ship codex "$id")
  read_case "$rec"
  printf '%s\n' "$AGENT_IDENT" > "$HOME_DIR/config/worker-git-identity"
  captain_before=$(file_sum "$CAPTAIN_GITCONFIG")
  shared_before=$(file_sum "$PROJ_DIR/.git/config")

  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn with a worker git identity should succeed: $out"
  install_git_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR") \
    || fail "ship: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "ship worker"
  state=$(CDPATH='' cd -- "$HOME_DIR/state" && pwd -P)
  assert_equals "$state/$id.git-hooks" "$(probe_field "$seen" hooks)" \
    "ship worker: the AI-trailer strip hooksPath must still apply beside the identity"

  assert_equals "$captain_before" "$(file_sum "$CAPTAIN_GITCONFIG")" \
    "the captain's global git config was written"
  assert_equals "$shared_before" "$(file_sum "$PROJ_DIR/.git/config")" \
    "the project's shared repository config was written"
  assert_absent "$(git -C "$WT_DIR" rev-parse --git-dir)/config.worktree" \
    "the worker copy gained a per-worktree config file"
  assert_equals 'captain@example.invalid' \
    "$(GIT_CONFIG_GLOBAL="$CAPTAIN_GITCONFIG" git -C "$WT_DIR" config user.email)" \
    "a shell outside the worker must keep reading the captain's identity in the same copy"
  pass "a ship worker's first commit carries the configured identity; no git config file changes"
}

test_identity_applies_when_ai_trailers_are_kept() {
  local rec id out status seen
  id=ident-keep-a1
  rec=$(make_case keep codex "$id")
  read_case "$rec"
  printf '%s\n' "$AGENT_IDENT" > "$HOME_DIR/config/worker-git-identity"
  : > "$HOME_DIR/config/keep-ai-trailers"

  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with keep-ai-trailers and a worker git identity should succeed: $out"
  install_git_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR") \
    || fail "keep-ai-trailers: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "keep-ai-trailers worker"
  assert_equals '' "$(probe_field "$seen" hooks)" \
    "keep-ai-trailers worker: the repository hooksPath must not be overridden"
  pass "the identity applies on its own when the home keeps AI trailers"
}

test_absent_identity_uses_the_agent_default() {
  local rec id out status seen
  id=ident-absent-a1
  rec=$(make_case absent codex "$id")
  read_case "$rec"

  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without a worker git identity should succeed: $out"
  install_git_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR") \
    || fail "absent identity: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "unconfigured worker" gsp-agent dale+gspagent@groovejones.com
  pass "an unconfigured worker's first commit carries the gsp-agent identity"
}

test_raw_identity_overrides_refuse_the_spawn() {
  local rec id out status seen override n=0
  for override in \
    "GIT_AUTHOR_NAME='Captain Person' GIT_AUTHOR_EMAIL=captain@example.invalid identity-probe --commit" \
    "env GIT_AUTHOR_EMAIL=captain@example.invalid identity-probe --commit" \
    "GIT_COMMITTER_NAME='Captain Person' identity-probe --commit" \
    "export GIT_COMMITTER_EMAIL=captain@example.invalid; identity-probe --commit"; do
    n=$((n + 1))
    id="ident-raw-$n"
    rec=$(make_case "raw-$n" codex "$id")
    read_case "$rec"
    printf '%s\n' "$AGENT_IDENT" > "$HOME_DIR/config/worker-git-identity"

    out=$(run_case_spawn "$id" "$PROJ_DIR" "$override" --mode no-mistakes --yolo off)
    status=$?
    if [ "$status" -eq 0 ]; then
      install_git_probe "$FAKEBIN_DIR" identity-probe
      seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR") \
        || fail "raw override: the emitted launch failed to run"$'\n'"$seen"
      fail "a raw identity override launched a worker: $seen"
    fi
    assert_contains "$out" 'worker git identity' "the raw override refusal should explain the conflict"
    assert_equals '' "$(cat "$LAUNCH_LOG")" "a raw identity override still launched a worker"
  done
  pass "raw author and committer overrides refuse the spawn before launch"
}

test_raw_launch_replaces_inherited_identity() {
  local rec id out status seen
  id=ident-inherited-a1
  rec=$(make_case inherited codex "$id")
  read_case "$rec"
  : > "$HOME_DIR/config/keep-ai-trailers"

  out=$(run_case_spawn "$id" "$PROJ_DIR" 'identity-probe --commit' --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a raw launch without identity assignments should succeed: $out"
  install_git_probe "$FAKEBIN_DIR" identity-probe
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR" \
    'GIT_AUTHOR_NAME=Captain Person' GIT_AUTHOR_EMAIL=captain@example.invalid \
    'GIT_COMMITTER_NAME=Captain Person' GIT_COMMITTER_EMAIL=captain@example.invalid) \
    || fail "inherited identity: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "raw worker with inherited identity" gsp-agent dale+gspagent@groovejones.com
  pass "an unconfigured raw worker replaces inherited author and committer identity with trailers kept"
}

test_malformed_identity_refuses_the_spawn() {
  local bad n=0 rec id out status
  for bad in 'gsp-agent' 'gsp-agent <>' '<agent@example.invalid>' \
    'gsp-agent <agent @example.invalid>' 'gsp-agent <agent@example.invalid> extra' \
    "gsp-agent <agent@example.invalid>"$'\n'"other <other@example.invalid>"; do
    n=$((n + 1))
    id="ident-bad-$n"
    rec=$(make_case "bad-$n" codex "$id")
    read_case "$rec"
    printf '%s\n' "$bad" > "$HOME_DIR/config/worker-git-identity"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "a malformed identity ('$bad') should refuse the spawn"
    assert_contains "$out" 'config/worker-git-identity' \
      "the refusal for '$bad' should name the setting"
    assert_equals '' "$(cat "$LAUNCH_LOG")" "a malformed identity ('$bad') still launched a worker"
  done
  pass "a malformed config/worker-git-identity refuses the spawn before any launch"
}

test_secondmate_and_its_crew_inherit_the_identity() {
  local rec sm_rec sm_id crew_id sm out status seen
  sm_id=ident-sm-a1
  crew_id=ident-sm-crew-a1
  rec=$(make_case sm-primary codex "$sm_id")
  sm_rec=$(make_case sm-home codex "$crew_id")
  read_case "$rec"
  printf '%s\n' "$AGENT_IDENT" > "$HOME_DIR/config/worker-git-identity"
  sm="${sm_rec#*|}"
  sm="${sm%%|*}"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$sm_id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$sm_id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main

  out=$(run_case_spawn "$sm_id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with a worker git identity should succeed: $out"
  assert_equals "$AGENT_IDENT" "$(cat "$sm/config/worker-git-identity" 2>/dev/null)" \
    "the secondmate home did not inherit config/worker-git-identity"
  install_git_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$sm") \
    || fail "secondmate: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "secondmate"

  read_case "$sm_rec"
  out=$(run_case_spawn "$crew_id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "secondmate crew spawn should succeed: $out"
  install_git_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_git "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$WT_DIR") \
    || fail "secondmate crew: the emitted launch failed to run"$'\n'"$seen"
  assert_agent_commit "$seen" "secondmate crew"
  pass "a secondmate and its own crew inherit the worker git identity"
}

test_ship_commits_as_the_configured_identity
test_identity_applies_when_ai_trailers_are_kept
test_absent_identity_uses_the_agent_default
test_raw_identity_overrides_refuse_the_spawn
test_raw_launch_replaces_inherited_identity
test_malformed_identity_refuses_the_spawn
test_secondmate_and_its_crew_inherit_the_identity
