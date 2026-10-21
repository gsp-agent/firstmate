#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-trust.sh and the codex spawn that calls it.
#
# The helper half proves the registration Codex itself would read: the
# repository root a linked worktree resolves to (the primary checkout) gains
# trust_level = "trusted" in ${CODEX_HOME:-$HOME/.codex}/config.toml, every
# other byte of that file survives, and anything that would need an in-place
# edit, override an explicit decline, or reach outside a linked worktree of the
# project is refused with the store left untouched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-trust)

TRUST="$ROOT/bin/fm-codex-trust.sh"

real_dir() { (cd -P -- "$1" && pwd -P); }

# make_case <name>: a project with one linked worktree plus an isolated HOME.
# Echoes "<case>|<proj>|<wt>|<home>".
make_case() {
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT HOME_DIR <<EOF
$1
EOF
  STORE="$HOME_DIR/.codex/config.toml"
}

# run_trust <home> <worktree> <project>: invoke against an isolated store, with
# CODEX_HOME cleared so a developer's own value cannot redirect the write.
run_trust() {
  CODEX_HOME='' HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

# codex_trust_level <store> <root>: the trust_level Codex reads for <root>, or
# "absent" when the store holds no entry for it.
codex_trust_level() {
  python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    entry = tomllib.load(handle).get("projects", {}).get(sys.argv[2])
print("absent" if entry is None else entry.get("trust_level"))
' "$1" "$2"
}

# toml_without_root <store> <root>: the parsed store minus <root>'s entry.
toml_without_root() {
  python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
data.get("projects", {}).pop(sys.argv[2], None)
if data.get("projects") == {}:
    data.pop("projects")
print(repr(data))
' "$1" "$2"
}

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

python_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no python3
  local dir=$1/nopython-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir dirname; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_fresh_worktree_trusts_the_primary_checkout_root() {
  local rec out root
  rec=$(make_case fresh)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_equals "trusted: $root" "$out" "the helper did not name the root it trusted"
  assert_equals trusted "$(codex_trust_level "$STORE" "$root")" \
    "the primary checkout Codex resolves for the worktree was not trusted"
  assert_equals absent "$(codex_trust_level "$STORE" "$(real_dir "$WT")")" \
    "the worktree path itself was registered although Codex never looks it up"
  assert_equals 600 "$(file_mode "$STORE")" "a created store was not private to this user"
  pass "fm-codex-trust.sh: a fresh worktree trusts the primary checkout root in a created store"
}

test_append_preserves_every_existing_byte() {
  local rec out root before
  rec=$(make_case preserve)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  mkdir -p "$HOME_DIR/.codex"
  printf '%s\n' \
    '# operator notes stay exactly as written' \
    'model = "gpt-6.1-sol"' \
    '' \
    '[projects."/home/someone/elsewhere"]' \
    'trust_level = "trusted"' \
    '' \
    '[tui]' > "$STORE"
  printf '%s' 'screen_reader_detection_done = true' >> "$STORE"
  chmod 640 "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "registration into an existing store must succeed: $out"
  case "$(cat "$STORE")" in
    "$before"*) : ;;
    *) fail "the original store bytes are no longer an untouched prefix of the file" ;;
  esac
  assert_equals trusted "$(codex_trust_level "$STORE" "$root")" "the root was not trusted"
  assert_equals trusted "$(codex_trust_level "$STORE" /home/someone/elsewhere)" \
    "an existing project entry lost its trust"
  assert_equals \
    "{'model': 'gpt-6.1-sol', 'projects': {'/home/someone/elsewhere': {'trust_level': 'trusted'}}, 'tui': {'screen_reader_detection_done': True}}" \
    "$(toml_without_root "$STORE" "$root")" \
    "registration changed a setting other than the one trust entry"
  assert_equals 640 "$(file_mode "$STORE")" "registration changed the store's file mode"
  pass "fm-codex-trust.sh: appends one entry and leaves every existing byte and the file mode intact"
}

test_registration_is_idempotent() {
  local rec out first
  rec=$(make_case idempotent)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ") || fail "first registration failed: $out"
  first=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  assert_equals "$first" "$(cat "$STORE")" "a repeat registration rewrote the store"
  pass "fm-codex-trust.sh: a repeat registration leaves the store byte-identical"
}

test_concurrent_registrations_preserve_all_roots() {
  local shared i
  local cases=()
  shared="$TMP_ROOT/concurrent-store"
  mkdir -p "$shared"
  for i in 1 2 3 4 5 6; do
    read_case "$(make_case "concurrent-$i")"
    cases+=("$HOME_DIR" "$WT" "$PROJ")
  done
  python3 -I - "$TRUST" "$shared" "${cases[@]}" <<'PY' || fail "concurrent trust registrations failed"
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tomllib

helper, shared, *cases = sys.argv[1:]
processes = []
lock_fd = os.open(shared, os.O_RDONLY)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    for home, wt, proj in zip(cases[::3], cases[1::3], cases[2::3]):
        env = dict(os.environ, HOME=home, CODEX_HOME=shared)
        processes.append(subprocess.Popen([helper, wt, proj], env=env,
                                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    for process in processes:
        try:
            output, _ = process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            continue
        raise AssertionError(f"registration did not wait for the shared directory lock: {output}")
finally:
    os.close(lock_fd)
    outputs = [process.communicate(timeout=35)[0] for process in processes]

for process, output in zip(processes, outputs):
    assert process.returncode == 0, output
with open(Path(shared) / "config.toml", "rb") as handle:
    projects = tomllib.load(handle)["projects"]
for proj in cases[2::3]:
    assert projects[str(Path(proj).resolve())]["trust_level"] == "trusted", proj
assert {path.name for path in Path(shared).iterdir()} == {"config.toml"}
PY
  pass "fm-codex-trust.sh: concurrent registrations wait for the store directory lock and preserve every root"
}

test_existing_trusted_entry_in_any_spelling_is_left_alone() {
  local rec out root before
  rec=$(make_case already)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  mkdir -p "$HOME_DIR/.codex"
  printf '[projects]\n"%s" = { trust_level = "trusted" }\n' "$root" > "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "an already-trusted root must succeed: $out"
  assert_equals "$before" "$(cat "$STORE")" "an already-trusted root was written again"
  pass "fm-codex-trust.sh: an already-trusted root in inline-table form is left untouched"
}

test_explicit_untrusted_decision_is_not_overridden() {
  local rec out root before
  rec=$(make_case declined)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  mkdir -p "$HOME_DIR/.codex"
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$root" > "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an explicit untrusted decision must be refused: $out"
  assert_contains "$out" "explicit decision" "the refusal did not name the standing decline"
  assert_equals "$before" "$(cat "$STORE")" "a standing decline was rewritten"
  pass "fm-codex-trust.sh: an explicit untrusted decision is refused, never flipped"
}

test_entries_that_need_an_in_place_edit_are_refused() {
  local rec out root before
  rec=$(make_case inplace)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  mkdir -p "$HOME_DIR/.codex"
  printf '[projects."%s"]\nnote = "kept"\n' "$root" > "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an entry without trust_level must be refused: $out"
  assert_contains "$out" "no trust_level" "the refusal did not name the incomplete entry"
  assert_equals "$before" "$(cat "$STORE")" "an incomplete entry was edited"
  printf 'projects = { "/home/someone/elsewhere" = { trust_level = "trusted" } }\n' > "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a projects inline table cannot take an appended table and must be refused: $out"
  assert_equals "$before" "$(cat "$STORE")" "a store that cannot take an appended table was written"
  pass "fm-codex-trust.sh: entries that would need an in-place edit are refused and left untouched"
}

test_invalid_store_is_refused_untouched() {
  local rec out before
  rec=$(make_case invalid)
  read_case "$rec"
  mkdir -p "$HOME_DIR/.codex"
  printf '%s\n' '[projects' 'not toml' > "$STORE"
  before=$(cat "$STORE")
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_contains "$out" "not valid TOML" "the refusal did not name the parse failure"
  assert_equals "$before" "$(cat "$STORE")" "an unparseable store was rewritten"
  pass "fm-codex-trust.sh: an unparseable store is refused and left untouched"
}

test_root_needing_toml_escapes_round_trips() {
  local case_dir proj wt home out root
  case_dir="$TMP_ROOT/escapes"
  proj="$case_dir/pro\"ject \\ dir"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" wt-escapes
  root=$(real_dir "$proj")
  out=$(run_trust "$home" "$wt" "$proj")
  expect_code 0 $? "a root whose path needs TOML escapes must be trusted: $out"
  assert_equals trusted "$(codex_trust_level "$home/.codex/config.toml" "$root")" \
    "a quoted and backslashed root did not parse back to the same path"
  pass "fm-codex-trust.sh: a root path needing TOML escapes round-trips exactly"
}

test_out_of_scope_paths_are_refused() {
  local rec out plain other_proj other_wt
  rec=$(make_case scope)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked its reason"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$HOME_DIR" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  mkdir -p "$WT/sub"
  out=$(run_trust "$HOME_DIR" "$WT/sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "not a worktree root" "subdirectory refusal lacked its reason"
  other_proj="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other_proj" "$other_wt" wt-other
  out=$(run_trust "$HOME_DIR" "$other_wt" "$PROJ")
  expect_code 1 $? "a worktree of another project must be refused: $out"
  assert_contains "$out" "not a worktree of project" "foreign-worktree refusal lacked its reason"
  out=$(run_trust "$HOME_DIR" "$HOME_DIR" "$PROJ")
  expect_code 1 $? "the home directory must be refused: $out"
  [ ! -e "$STORE" ] || fail "a refused registration still wrote the store"
  pass "fm-codex-trust.sh: primary checkouts, plain dirs, subdirectories, foreign worktrees, and HOME are refused"
}

# A bare repository's worktree resolves to the bare repo's parent directory,
# which is not a checkout of the project at all, so it is never trusted.
test_nonstandard_layout_root_is_refused() {
  local case_dir home bare wt out
  case_dir="$TMP_ROOT/bare"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_init_commit "$case_dir/seed"
  git clone --quiet --bare "$case_dir/seed" "$case_dir/repos/project.git"
  bare="$case_dir/repos/project.git"
  wt="$case_dir/wt"
  git -C "$bare" worktree add --quiet -b wt-bare "$wt"
  out=$(run_trust "$home" "$wt" "$bare")
  expect_code 1 $? "a bare-repository worktree must be refused: $out"
  assert_contains "$out" "not the primary checkout" "the bare-layout refusal lacked its reason"
  [ ! -e "$home/.codex/config.toml" ] || fail "a bare-layout refusal still wrote the store"
  pass "fm-codex-trust.sh: a worktree whose resolved root is not a primary checkout is refused"
}

test_codex_home_selects_the_store() {
  local rec out root codex_home
  rec=$(make_case codexhome)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  codex_home="$CASE_DIR/codex-home"
  mkdir -p "$codex_home"
  out=$(CODEX_HOME="$codex_home" HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an absolute CODEX_HOME must be honored: $out"
  assert_equals trusted "$(codex_trust_level "$codex_home/config.toml" "$root")" \
    "the store under CODEX_HOME was not written"
  [ ! -e "$STORE" ] || fail "HOME's store was written although CODEX_HOME names another"
  out=$(cd "$CASE_DIR" && CODEX_HOME=codex-home HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative CODEX_HOME must be refused: $out"
  assert_contains "$out" "relative path" "relative CODEX_HOME refusal lacked its reason"
  out=$(CODEX_HOME="$CASE_DIR/missing" HOME="$HOME_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a missing CODEX_HOME must be refused: $out"
  [ ! -e "$CASE_DIR/missing" ] || fail "a missing CODEX_HOME was created"
  pass "fm-codex-trust.sh: an absolute CODEX_HOME selects the store, a relative or missing one is refused"
}

test_symlinked_store_writes_its_target() {
  local rec out root target
  rec=$(make_case symlink)
  read_case "$rec"
  root=$(real_dir "$PROJ")
  target="$CASE_DIR/dotfiles/codex-config.toml"
  mkdir -p "$(dirname "$target")" "$HOME_DIR/.codex"
  printf 'model = "kept"\n' > "$target"
  ln -s "$target" "$STORE"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a symlinked store to an owned file must be accepted: $out"
  [ -L "$STORE" ] || fail "the store symlink was replaced by a regular file"
  assert_equals trusted "$(codex_trust_level "$target" "$root")" "the symlink target was not written"
  pass "fm-codex-trust.sh: a symlinked store keeps its link and writes the target"
}

test_missing_python_is_refused() {
  local rec out bindir
  rec=$(make_case nopython)
  read_case "$rec"
  bindir=$(python_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a missing python3 must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "python3" "the refusal did not name the missing interpreter"
  [ ! -e "$STORE" ] || fail "a store was written without the interpreter that verifies it"
  pass "fm-codex-trust.sh: a missing python3 is refused rather than degraded"
}

# The spawn half drives the real bin/fm-spawn.sh against a fake tmux whose
# codex screen follows what codex-cli 0.163.0 was observed to draw
# (docs/verification/codex.md): a root with a trusted entry in the store goes
# from the launch straight to a running turn, and any other root shows the
# welcome screen for one capture before the folder-access prompt replaces it.
SPAWN="$ROOT/bin/fm-spawn.sh"

make_codex_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_CODEX_STATE" 2>/dev/null || true)
welcome() {
  printf '  >_ OpenAI Codex (v0.163.0)\n     %s\n\n› Ask Codex to do anything\n  ? for shortcuts\n' "$FM_FAKE_PANE_PATH"
}
fake_screen() {
  if [ -n "${FM_FAKE_CODEX_HISTORY:-}" ]; then
    cat "$FM_FAKE_CODEX_HISTORY"
  fi
  if [ "${FM_FAKE_CODEX_ECHO_LAUNCH:-0}" = 1 ] && [ -f "$FM_FAKE_CODEX_STATE.command" ]; then
    if [ "${FM_FAKE_CODEX_WRAP_ECHO:-0}" = 1 ]; then
      python3 -I -c '
import sys
command = open(sys.argv[1]).read().rstrip("\n")
print("\n".join(command[i:i+10] for i in range(0, len(command), 10)))
' "$FM_FAKE_CODEX_STATE.command"
    else
      cat "$FM_FAKE_CODEX_STATE.command"
    fi
  fi
  case "$state" in
    welcome-then-prompt) welcome; printf 'prompt\n' > "$FM_FAKE_CODEX_STATE" ;;
    welcome) welcome ;;
    prompt|restricted-prompt)
      printf '  Folder access\n  %s\n  Note: You are in a subdirectory of a Git project. Trusting will apply to the repository root:\n  %s\n' \
        "$FM_FAKE_PANE_PATH" "$FM_FAKE_CODEX_ROOT"
      if [ "$state" = prompt ]; then
        printf '  Trust this folder? Codex can read, edit, and run files here.\n› 1. Trust and continue\n'
      else
        printf '  Config, hooks, and exec policies from untrusted folders stay disabled.\n› 1. Open restricted\n'
      fi
      printf '  2. Quit\n  enter continue · esc quit\n'
      ;;
    turn) printf '› Read the brief\n• Working (1s • esc to interrupt)\n› Ask Codex to do anything\n  ? for shortcuts\n' ;;
    quoted-turn|quoted-finished)
      cat <<'EOF'
› Investigate these Codex folder-access dialogs:
  Folder access
  Trust this folder? Codex can read, edit, and run files here.
› 1. Trust and continue
  2. Quit
  enter continue · esc quit
  Folder access
  Config, hooks, and exec policies from untrusted folders stay disabled.
› 1. Open restricted
  2. Quit
  enter continue · esc quit
EOF
      if [ "$state" = quoted-turn ]; then
        printf '• Working (1s • esc to interrupt)\n'
      else
        printf '• Worked for 1s\n'
      fi
      printf '› Ask Codex to do anything\n  ? for shortcuts\n'
      ;;
    *) printf 'shell starting\n$ \n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'")
          [ "${FM_FAKE_CODEX_ECHO_LAUNCH:-0}" != 1 ] || printf '%s\n' "$literal" > "$FM_FAKE_CODEX_STATE.command"
          staged=${literal#". '"}
          staged=${staged%"'"}
          printf '%s\n' "$staged" > "$FM_FAKE_CODEX_STATE.script"
          [ ! -f "$staged" ] || literal=$(cat "$staged")
          ;;
      esac
      case "$literal" in
        *"codex "*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_CODEX_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        if [ "$state" = launched ]; then
          HOME="${FM_FAKE_PANE_HOME:-$HOME}" CODEX_HOME="${FM_FAKE_PANE_CODEX_HOME:-}" \
            bash "$(cat "$FM_FAKE_CODEX_STATE.script")" || exit 1
        fi
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'codex-cli 0.163.0\n'
  exit 0
fi
store="${CODEX_HOME:-$HOME/.codex}/config.toml"
printf '%s\n' "$store" > "$FM_FAKE_CODEX_STATE.store"
if [ -n "${FM_FAKE_CODEX_LINGER:-}" ]; then
  # The real CLI outlives its pane's hangup, so this stand-in ignores SIGHUP.
  (cd "$FM_FAKE_PANE_PATH" && trap '' HUP && exec sleep 600) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$FM_FAKE_CODEX_LINGER"
fi
if [ -n "${FM_FAKE_CODEX_SCREEN:-}" ]; then
  printf '%s\n' "$FM_FAKE_CODEX_SCREEN" > "$FM_FAKE_CODEX_STATE"
elif [ "${FM_FAKE_CODEX_IGNORE_TRUST:-0}" != 1 ] && python3 -I -c '
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as handle:
        entry = tomllib.load(handle).get("projects", {}).get(sys.argv[2], {})
except FileNotFoundError:
    sys.exit(1)
sys.exit(0 if entry.get("trust_level") == "trusted" else 1)
' "$store" "$FM_FAKE_CODEX_ROOT"; then
  printf 'turn\n' > "$FM_FAKE_CODEX_STATE"
else
  printf 'welcome-then-prompt\n' > "$FM_FAKE_CODEX_STATE"
fi
SH
  chmod +x "$fakebin/codex"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_codex_spawn_case <name> <id>: a firstmate home, a project with one linked
# worktree, and the fake tools. Echoes "<case>|<home>|<proj>|<wt>|<fakebin>".
make_codex_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_codex_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Codex dispatch.

## Firstmate spec
Verify launch behavior.
EOF
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/codex.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_codex_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ WT FAKEBIN <<EOF
$1
EOF
  ROOT_KEY=$(real_dir "$PROJ")
  STORE="${SPAWN_CODEX_HOME:-$HOME_DIR/.codex}/config.toml"
}

# run_codex_spawn <id> [fm-spawn args...]: spawn a codex crewmate for the case
# read last, with SPAWN_CODEX_HOME (empty by default) as the worker's CODEX_HOME.
run_codex_spawn() {
  local id=$1
  shift
  HOME="$HOME_DIR" CODEX_HOME="${SPAWN_CODEX_HOME:-}" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    FM_FAKE_CODEX_STATE="$CASE_DIR/codex.state" \
    FM_FAKE_CODEX_ROOT="$ROOT_KEY" \
    FM_FAKE_CODEX_IGNORE_TRUST="${FM_FAKE_CODEX_IGNORE_TRUST:-0}" \
    FM_FAKE_CODEX_SCREEN="${FM_FAKE_CODEX_SCREEN:-}" \
    FM_FAKE_CODEX_LINGER="${FM_FAKE_CODEX_LINGER:-}" \
    FM_CODEX_READY_POLLS=4 FM_CODEX_POLL_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ" --harness codex --mode no-mistakes --yolo off "$@" 2>&1
}

gate_captures() {  # <tmux-call-log>: pane captures taken after the launch was typed
  awk '/^send-keys .* -l \. /{launched=1} launched && /^capture-pane/{n++} END{print n+0}' "$1"
}

status_text() {  # <id>: the task's status lines without their time stamps
  sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$1.status" 2>/dev/null
}

test_spawn_pre_trusts_the_root_and_launches_into_a_running_turn() {
  local id out launch
  id="codex-trust-c1-$$"
  read_codex_spawn_case "$(make_codex_spawn_case pretrust "$id")"
  out=$(run_codex_spawn "$id")
  expect_code 0 $? "a codex spawn into a fresh worktree should succeed: $out"
  assert_contains "$out" "spawned $id harness=codex" "the codex spawn did not report success"
  assert_equals trusted "$(codex_trust_level "$STORE" "$ROOT_KEY")" \
    "the spawn did not pre-register the root Codex resolves for the worktree"
  assert_equals turn "$(cat "$CASE_DIR/codex.state")" \
    "the spawn reported success before the pane reached a running turn"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--disable hooks" "the crewmate launch stopped disabling codex hooks"
  assert_equals "$STORE" "$(cat "$CASE_DIR/codex.state.store")" \
    "the worker did not read the default store that registration wrote"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful codex spawn tore down the endpoint it launched"
  pass "fm-spawn: codex pre-trusts the worktree's root and launches into a running turn"
}

test_spawn_forwards_codex_home_to_the_store_it_wrote() {
  local id out launch codex_home
  id="codex-home-c2-$$"
  codex_home="$TMP_ROOT/spawn-codexhome-store"
  mkdir -p "$codex_home"
  SPAWN_CODEX_HOME=$codex_home read_codex_spawn_case "$(make_codex_spawn_case codexhome "$id")"
  out=$(SPAWN_CODEX_HOME=$codex_home run_codex_spawn "$id")
  expect_code 0 $? "a codex spawn with CODEX_HOME set should succeed: $out"
  assert_equals trusted "$(codex_trust_level "$codex_home/config.toml" "$ROOT_KEY")" \
    "the spawn did not register trust in the CODEX_HOME store"
  assert_equals "$codex_home/config.toml" "$(cat "$CASE_DIR/codex.state.store")" \
    "the worker did not read the explicit CODEX_HOME store that registration wrote"
  [ ! -e "$HOME_DIR/.codex/config.toml" ] || fail "HOME's store was written although CODEX_HOME names another"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "CODEX_HOME='$codex_home' " \
    "the launch did not carry the CODEX_HOME whose store holds the trust"
  pass "fm-spawn: codex forwards CODEX_HOME so the worker reads the store the spawn wrote"
}

test_spawn_overrides_the_destination_store_and_home() {
  local id out pane_home pane_codex inherited
  for inherited in set unset; do
    id="codex-pane-$inherited-$$"
    read_codex_spawn_case "$(make_codex_spawn_case "pane-$inherited" "$id")"
    pane_home="$CASE_DIR/pane-home"
    pane_codex="$CASE_DIR/pane-codex"
    mkdir -p "$pane_home" "$pane_codex"
    [ "$inherited" = set ] || pane_codex=
    out=$(FM_FAKE_PANE_HOME=$pane_home FM_FAKE_PANE_CODEX_HOME=$pane_codex run_codex_spawn "$id")
    expect_code 0 $? "a different destination environment must not change the worker's store: $out"
    assert_equals "$STORE" "$(cat "$CASE_DIR/codex.state.store")" \
      "the worker read the destination pane's store instead of the registered store"
    assert_equals trusted "$(codex_trust_level "$STORE" "$ROOT_KEY")" "the intended store lost the root's trust"
    [ ! -e "$pane_home/.codex/config.toml" ] || fail "the destination HOME's store was written"
    [ ! -e "$CASE_DIR/pane-codex/config.toml" ] || fail "the destination CODEX_HOME's store was written"
  done
  pass "fm-spawn: a destination pane's CODEX_HOME and HOME cannot redirect the worker's store"
}

test_spawn_accepts_turns_quoting_both_folder_access_dialogs() {
  local id screen out
  for screen in quoted-turn quoted-finished; do
    id="codex-$screen-$$"
    read_codex_spawn_case "$(make_codex_spawn_case "$screen" "$id")"
    out=$(FM_FAKE_CODEX_SCREEN=$screen run_codex_spawn "$id")
    expect_code 0 $? "a codex turn quoting the dialogs must pass the spawn gate: $out"
    assert_contains "$out" "spawned $id harness=codex" "the quoted $screen did not report success"
    assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
      "a codex $screen quoting the dialogs had its endpoint closed"
  done
  pass "fm-spawn: running and finished turns quoting both folder-access dialogs pass the launch gate"
}

test_prompt_despite_registration_fails_the_spawn_at_once() {
  local id out rc calls captures
  id="codex-prompt-c3-$$"
  read_codex_spawn_case "$(make_codex_spawn_case prompt "$id")"
  rc=0
  out=$(FM_FAKE_CODEX_IGNORE_TRUST=1 run_codex_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a codex launch parked on the folder-access prompt must fail the spawn"
  assert_contains "$out" "parked on its folder-access prompt" "the failure did not name the prompt"
  assert_not_contains "$out" "spawned $id" "a parked codex launch still reported a successful spawn"
  assert_grep 'failed: codex parked on its folder-access prompt' <(status_text "$id") \
    "the parked launch was not recorded as failed in the task status"
  calls=$(cat "$CASE_DIR/tmux-calls.log")
  assert_contains "$calls" "kill-window" "a parked codex launch left its endpoint running"
  captures=$(gate_captures "$CASE_DIR/tmux-calls.log")
  [ "$captures" -eq 2 ] \
    || fail "the welcome screen must not pass the gate and the prompt must fail it on sight; got $captures captures"
  assert_equals 1 "$(grep -c '^send-keys -t [^ ]* Enter$' "$CASE_DIR/tmux-calls.log")" \
    "the gate sent a key into the folder-access prompt instead of only the launch Enter"
  pass "fm-spawn: a codex launch showing the folder-access prompt fails at once and closes the endpoint"
}

test_reused_pane_history_never_confirms_a_replacement_launch() {
  local id out rc wrapped screen
  for wrapped in 0 1; do
    for screen in welcome-then-prompt restricted-prompt; do
      id="codex-old-$wrapped-$screen-$$"
      read_codex_spawn_case "$(make_codex_spawn_case "old-$wrapped-$screen" "$id")"
      printf '$ . /tmp/launch.previous.sh\n• Worked for 1s\n• Working (1s • esc to interrupt)\n' > "$CASE_DIR/history"
      rc=0
      out=$(FM_FAKE_CODEX_HISTORY="$CASE_DIR/history" FM_FAKE_CODEX_ECHO_LAUNCH=1 \
        FM_FAKE_CODEX_WRAP_ECHO=$wrapped FM_FAKE_CODEX_SCREEN=$screen run_codex_spawn "$id") || rc=$?
      [ "$rc" -ne 0 ] || fail "a previous worker's turn confirmed a replacement on its folder-access prompt"
      assert_contains "$out" "parked on its folder-access prompt" "the reused pane did not report its live dialog"
      assert_not_contains "$out" "spawned $id" "the reused pane reported success before the replacement started"
      assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" "a parked replacement left its endpoint running"
    done
  done
  pass "fm-spawn: inline history above a plain or wrapped launch echo cannot hide either live dialog"
}

test_running_turn_without_a_launch_echo_passes() {
  local id out
  id="codex-no-echo-$$"
  read_codex_spawn_case "$(make_codex_spawn_case no-echo "$id")"
  out=$(FM_FAKE_CODEX_ECHO_LAUNCH=0 FM_FAKE_CODEX_SCREEN=turn run_codex_spawn "$id")
  expect_code 0 $? "a running codex turn without a launch echo must pass: $out"
  assert_contains "$out" "spawned $id harness=codex" "the turn without an echo did not report success"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a healthy worker without a launch echo had its endpoint closed"
  pass "fm-spawn: a running turn passes without a launch echo"
}

test_launch_that_never_starts_a_turn_fails_the_spawn() {
  local id out rc
  id="codex-welcome-c4-$$"
  read_codex_spawn_case "$(make_codex_spawn_case welcome "$id")"
  rc=0
  out=$(FM_FAKE_CODEX_SCREEN=welcome run_codex_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a codex launch that never starts a turn must fail the spawn"
  assert_contains "$out" "codex-cli 0.163.0 showed neither its folder-access prompt nor a started turn" \
    "the expiry failure did not name the installed codex version"
  assert_grep 'failed: codex-cli 0.163.0 showed neither' <(status_text "$id") \
    "the expired launch was not recorded as failed in the task status"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "an expired codex launch left its endpoint running"
  assert_equals 4 "$(gate_captures "$CASE_DIR/tmux-calls.log")" \
    "the gate did not poll for its full bound before failing"
  pass "fm-spawn: a codex launch that never starts a turn fails after the bound, naming the version"
}

test_rejected_launch_leaves_no_worker_running() {
  local id out rc pid screen
  for screen in welcome-then-prompt welcome; do
    id="codex-orphan-$screen-$$"
    read_codex_spawn_case "$(make_codex_spawn_case "orphan-$screen" "$id")"
    rc=0
    out=$(FM_FAKE_CODEX_LINGER="$CASE_DIR/worker.pid" FM_FAKE_CODEX_IGNORE_TRUST=1 \
      FM_FAKE_CODEX_SCREEN=$screen run_codex_spawn "$id") || rc=$?
    [ "$rc" -ne 0 ] || fail "the $screen launch must fail the spawn: $out"
    pid=$(cat "$CASE_DIR/worker.pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) fail "the fake codex did not start its lingering worker" ;; esac
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      fail "a rejected $screen codex launch left its SIGHUP-ignoring worker running in the worktree"
    fi
  done
  pass "fm-spawn: a rejected codex launch stops the worker it started, not only its endpoint"
}

test_unregistrable_root_refuses_before_launch() {
  local id out rc before
  id="codex-refuse-c5-$$"
  read_codex_spawn_case "$(make_codex_spawn_case refuse "$id")"
  mkdir -p "$(dirname "$STORE")"
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$ROOT_KEY" > "$STORE"
  before=$(cat "$STORE")
  rc=0
  out=$(run_codex_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a root whose trust cannot be registered must refuse the codex spawn"
  assert_contains "$out" "could not pre-register Codex folder trust" "the refusal did not name the trust step"
  assert_contains "$out" "explicit decision" "the refusal did not carry the helper's reason"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "a refused codex spawn still launched the worker"
  assert_equals "$before" "$(cat "$STORE")" "a refused codex spawn rewrote the store"
  pass "fm-spawn: a codex root whose trust cannot be registered refuses before launch"
}

test_fresh_worktree_trusts_the_primary_checkout_root
test_append_preserves_every_existing_byte
test_registration_is_idempotent
test_concurrent_registrations_preserve_all_roots
test_existing_trusted_entry_in_any_spelling_is_left_alone
test_explicit_untrusted_decision_is_not_overridden
test_entries_that_need_an_in_place_edit_are_refused
test_invalid_store_is_refused_untouched
test_root_needing_toml_escapes_round_trips
test_out_of_scope_paths_are_refused
test_nonstandard_layout_root_is_refused
test_codex_home_selects_the_store
test_symlinked_store_writes_its_target
test_missing_python_is_refused
test_spawn_pre_trusts_the_root_and_launches_into_a_running_turn
test_spawn_forwards_codex_home_to_the_store_it_wrote
test_spawn_overrides_the_destination_store_and_home
test_spawn_accepts_turns_quoting_both_folder_access_dialogs
test_prompt_despite_registration_fails_the_spawn_at_once
test_reused_pane_history_never_confirms_a_replacement_launch
test_running_turn_without_a_launch_echo_passes
test_launch_that_never_starts_a_turn_fails_the_spawn
test_rejected_launch_leaves_no_worker_running
test_unregistrable_root_refuses_before_launch
