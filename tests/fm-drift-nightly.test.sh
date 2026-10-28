#!/usr/bin/env bash
# Behavior tests for bin/fm-drift-nightly.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT=$ROOT/bin/fm-drift-nightly.sh
assert_present "$SCRIPT" "bin/fm-drift-nightly.sh is missing"

fixture_commit() { # <repo> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

run_check() { # <repo> [extra args...]
  local repo=$1
  shift
  CHECK_RC=0
  CHECK_OUT=$("$SCRIPT" check --no-fetch --repo "$repo" "$@" 2>"$repo.err") || CHECK_RC=$?
  CHECK_ERR=$(cat "$repo.err")
}

fake_launchctl() { # <dir> -> path of a launchctl that logs to FM_DRIFT_LAUNCHCTL_LOG
  cat > "$1/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_DRIFT_LAUNCHCTL_LOG"
if [ "$1" = print ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$1/launchctl"
  printf '%s\n' "$1/launchctl"
}

exiting_launchctl() { # <path> <bootout exit> <print exit>: a logging launchctl with fixed exit statuses
  cat > "$1" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$FM_DRIFT_LAUNCHCTL_LOG"
[ "\$1" = print ] && exit $3
exit $2
EOF
  chmod +x "$1"
}

lint_path() { # <dir> -> PATH whose plutil -lint is real, or a strict plistlib stand-in where plutil is absent
  if command -v plutil >/dev/null 2>&1; then
    printf '%s\n' "$PATH"
    return 0
  fi
  mkdir -p "$1/lint-bin"
  cat > "$1/lint-bin/plutil" <<'EOF'
#!/usr/bin/env python3
import plistlib, sys
try:
    with open(sys.argv[2], "rb") as f:
        plistlib.load(f)
except Exception as e:
    print(f"{sys.argv[2]}: ({e})")
    sys.exit(1)
print(f"{sys.argv[2]}: OK")
EOF
  chmod +x "$1/lint-bin/plutil"
  printf '%s\n' "$1/lint-bin:$PATH"
}

plist_args() { # <plist> -> ProgramArguments, one per line, read by a strict XML plist parser
  python3 -I -c 'import plistlib, sys; print("\n".join(plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"]))' "$1"
}

plist_value() { # <plist> <key> [nested key...] -> that value, read by a strict XML plist parser
  python3 -I -c 'import plistlib, sys
value = plistlib.load(open(sys.argv[1], "rb"))
for key in sys.argv[2:]:
    value = value[key]
print(value)' "$@"
}

nightly_fixture() { # <root>: <root>/repo clones <root>/upstream as its kunchenguid remote; <root>/home is a scratch Firstmate home
  fm_git_init_commit "$1/upstream"
  git clone -q "$1/upstream" "$1/repo"
  git -C "$1/repo" remote rename origin kunchenguid
  mkdir -p "$1/home"
}

run_nightly() { # <root>: one scheduled run, its output appended to <root>/drift.log as launchd does
  NIGHTLY_RC=0
  # nightly only names --log in its note; launchd owns the append, as here.
  # shellcheck disable=SC2094
  FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" FM_DATA_OVERRIDE="$1/home/data" \
    "$SCRIPT" nightly --repo "$1/repo" --log "$1/drift.log" >> "$1/drift.log" 2>&1 || NIGHTLY_RC=$?
}

note_count() { # <home>
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

note_body() { # <home> -> the body of its only note
  sed '1,/^--$/d' "$1"/state/inbox/*.note
}

test_unproven_file_is_path_drift_and_exits_1() {
  local repo sha out
  repo=$(fm_test_tmproot drift-unproven)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "an unproven file exits 1"
  out=$CHECK_OUT
  assert_equals "behind: 0
ahead: 1
path-drift: notes.txt
unproven: $sha add notes" "$out" "unproven notes.txt is the whole report"
  pass "an unproven file is path-drift and the check exits 1"
}

test_proof_sha_makes_that_path_ok_and_exits_0() {
  local repo sha
  repo=$(fm_test_tmproot drift-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a proven file exits 0"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
keep: $sha add notes (#7)" "$CHECK_OUT" "a proof PR marks the path and the commit"
  pass "a proof PR makes that path ok and the check exits 0"
}

test_squash_merged_branch_carries_its_own_manifest_line() {
  local repo sha
  repo=$(fm_test_tmproot drift-squash-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  git -C "$repo" switch -q -c fm/feature
  printf 'custom\n' > "$repo/notes.txt"
  printf 'pr: 7\n' > "$repo/drift-proof.txt"
  git -C "$repo" add notes.txt drift-proof.txt
  fixture_commit "$repo" "add notes"
  git -C "$repo" switch -q main
  git -C "$repo" merge -q --squash fm/feature
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 0 "$CHECK_RC" "a squash carrying its own manifest line exits 0: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: notes.txt' "the squashed path is accepted"
  assert_contains "$CHECK_OUT" "keep: $sha add notes (#7)" "the squash commit is kept by its PR number"
  printf 'unproven\n' >> "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "later unproven edits"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "the same manifest rejects later edits"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "later edits have no exemption"
  pass "a squash-merged branch carries its own manifest line and later edits fail"
}

test_default_proof_comes_from_the_committed_fork_tree() {
  local repo sha proof
  repo=$(fm_test_tmproot drift-worktree-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/drift-proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "an untracked drift-proof.txt naming a proven PR exits 1: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-drift: notes.txt
unproven: $sha add notes (#7)
error: missing manifest entry for PR 7" "$CHECK_OUT" "an untracked drift-proof.txt proves nothing"
  printf '# no proof\n' > "$repo/drift-proof.txt"
  git -C "$repo" add drift-proof.txt
  fixture_commit "$repo" "add empty proof (#8)"
  proof=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\npr: 8\n' >> "$repo/drift-proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "an uncommitted edit to drift-proof.txt exits 1: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "only the committed drift-proof.txt proves commits"
  assert_contains "$CHECK_OUT" "unproven: $sha add notes (#7)" "the working-tree proof line is never read"
  assert_contains "$CHECK_OUT" "unproven: $proof add empty proof (#8)" "the committed empty proof proves nothing"
  pass "the default proof is drift-proof.txt in the committed fork tree, never the working tree"
}

test_guard_files_have_no_exemptions() {
  local repo sha
  repo=$(fm_test_tmproot drift-guard)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  printf '#!/bin/bash\n' > "$repo/bin/fm-drift-nightly.sh"
  printf 'fixture test\n' > "$repo/tests/fm-drift-nightly.test.sh"
  printf 'fixture docs\n' > "$repo/docs/scripts.md"
  printf '# fixture proof\n' > "$repo/drift-proof.txt"
  git -C "$repo" add bin/fm-drift-nightly.sh tests/fm-drift-nightly.test.sh docs/scripts.md drift-proof.txt
  fixture_commit "$repo" "add guard files (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "unproven guard files exit 1"
  assert_equals "behind: 0
ahead: 1
path-drift: bin/fm-drift-nightly.sh
path-drift: docs/scripts.md
path-drift: drift-proof.txt
path-drift: tests/fm-drift-nightly.test.sh
unproven: $sha add guard files (#7)
error: missing manifest entry for PR 7" "$CHECK_OUT" "every unproven guard file drifts"
  printf 'pr: 7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "exact proven guard patches exit 0: $CHECK_ERR"
  printf 'later edit\n' >> "$repo/bin/fm-drift-nightly.sh"
  printf 'later edit\n' >> "$repo/tests/fm-drift-nightly.test.sh"
  printf 'later edit\n' >> "$repo/docs/scripts.md"
  printf '# later edit\n' >> "$repo/drift-proof.txt"
  git -C "$repo" add bin/fm-drift-nightly.sh tests/fm-drift-nightly.test.sh docs/scripts.md drift-proof.txt
  fixture_commit "$repo" "edit proven guard files"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "later unproven guard edits exit 1"
  assert_contains "$CHECK_OUT" 'path-drift: bin/fm-drift-nightly.sh' "guard script drift is reported"
  assert_contains "$CHECK_OUT" 'path-drift: tests/fm-drift-nightly.test.sh' "guard test drift is reported"
  assert_contains "$CHECK_OUT" 'path-drift: docs/scripts.md' "guard documentation drift is reported"
  assert_contains "$CHECK_OUT" 'path-drift: drift-proof.txt' "proof manifest drift is reported"
  pass "guard files require exact proven patches and later edits fail"
}

test_unproven_edit_to_proven_file_exits_1() {
  local repo kept later
  repo=$(fm_test_tmproot drift-proven-edit)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven notes (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  printf 'unproven\n' >> "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "unproven edit"
  later=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "an unproven edit to a proven path exits 1"
  assert_equals "behind: 0
ahead: 2
path-drift: notes.txt
unproven: $later unproven edit
keep: $kept proven notes (#7)" "$CHECK_OUT" "the later edit cannot borrow the earlier proof"
  pass "an unproven edit to an already-proven file fails"
}

test_unproven_deletion_cannot_rename_into_proven_file() {
  local repo kept later
  repo=$(fm_test_tmproot drift-rename)
  fm_git_init_commit "$repo"
  printf 'identical contents\n' > "$repo/original.txt"
  git -C "$repo" add original.txt
  fixture_commit "$repo" "upstream original"
  git -C "$repo" branch upstream
  git -C "$repo" config diff.renames true
  cp "$repo/original.txt" "$repo/copy.txt"
  git -C "$repo" add copy.txt
  fixture_commit "$repo" "proven copy (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  git -C "$repo" rm -q original.txt
  fixture_commit "$repo" "unproven deletion"
  later=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a deletion cannot be hidden by rename detection"
  assert_contains "$CHECK_OUT" 'path-ok: copy.txt' "the proven copy remains accepted"
  assert_contains "$CHECK_OUT" 'path-drift: original.txt' "the unproven deletion is reported"
  assert_contains "$CHECK_OUT" "unproven: $later unproven deletion" "the deletion commit remains unproven"
  pass "an unproven deletion cannot collapse into a rename onto a proven file"
}

test_moving_ref_keeps_one_snapshot() {
  local name=$1 ref=$2 repo kept future shim real_git marker
  repo=$(fm_test_tmproot "drift-moving-$name")
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'proven\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven notes (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  git -C "$repo" switch -q -c future
  printf 'unproven\n' > "$repo/later.txt"
  git -C "$repo" add later.txt
  fixture_commit "$repo" "later commit"
  future=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q main
  shim=$(fm_test_tmproot drift-ref-git)
  real_git=$(command -v git)
  marker=$shim/advanced
  cat > "$shim/git" <<'EOF'
#!/usr/bin/env bash
"$FM_DRIFT_REF_GIT" "$@"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
seen_diff=0
list_paths=0
for arg in "$@"; do
  case $arg in
    diff) seen_diff=1 ;;
    --name-only) list_paths=1 ;;
  esac
done
if [ "$seen_diff" -eq 1 ] && [ "$list_paths" -eq 1 ] && [ ! -e "$FM_DRIFT_REF_MARKER" ]; then
  "$FM_DRIFT_REF_GIT" -C "$FM_DRIFT_REF_REPO" update-ref "$FM_DRIFT_REF_NAME" "$FM_DRIFT_REF_NEW_SHA" || exit 1
  : > "$FM_DRIFT_REF_MARKER"
fi
exit 0
EOF
  chmod +x "$shim/git"
  PATH="$shim:$PATH" FM_DRIFT_REF_GIT="$real_git" FM_DRIFT_REF_REPO="$repo" \
    FM_DRIFT_REF_NAME="$ref" FM_DRIFT_REF_NEW_SHA="$future" FM_DRIFT_REF_MARKER="$marker" \
    run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  assert_present "$marker" "the $name ref was advanced while the check ran"
  assert_equals "$future" "$(git -C "$repo" rev-parse "$ref")" "the $name ref actually reached the later commit"
  expect_code 0 "$CHECK_RC" "the original $name snapshot has no drift: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
keep: $kept proven notes (#7)" "$CHECK_OUT" "counts, paths, and commit reporting use the captured $name snapshot"
  pass "a moving $name ref cannot change the captured check or its report"
}

test_snapshot_includes_fetched_upstream() {
  local upstream_repo repo kept
  upstream_repo=$(fm_test_tmproot drift-fetch-source)
  fm_git_init_commit "$upstream_repo"
  repo=$(fm_test_tmproot drift-fetch-fork)/repo
  git clone -q "$upstream_repo" "$repo" || fail "cannot clone the fetch fixture"
  assert_equals "$repo" "$(git -C "$repo" rev-parse --show-toplevel)" "fetch commands must run in the fixture repository"
  git -C "$repo" remote rename origin kunchenguid || fail "cannot configure the fetch fixture remote"
  printf 'proven\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven notes (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  printf 'upstream\n' > "$upstream_repo/upstream.txt"
  git -C "$upstream_repo" add upstream.txt
  fixture_commit "$upstream_repo" "new upstream commit"
  CHECK_RC=0
  CHECK_OUT=$("$SCRIPT" check --repo "$repo" --proof "$repo/proof.txt" 2>"$repo.err") || CHECK_RC=$?
  CHECK_ERR=$(cat "$repo.err")
  expect_code 0 "$CHECK_RC" "the fetched upstream snapshot preserves the proven patch: $CHECK_ERR"
  assert_equals "behind: 1
ahead: 1
path-ok: notes.txt
keep: $kept proven notes (#7)" "$CHECK_OUT" "upstream is captured after the real fetch updates it"
  assert_equals "$(git -C "$upstream_repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse kunchenguid/main)" "the real fetch advanced the upstream ref"
  pass "the captured upstream includes updates from the completed fetch"
}

test_proven_patches_are_replayed_in_ancestry_order() {
  local repo
  repo=$(fm_test_tmproot drift-ordered-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'first\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "first patch (#1)"
  printf 'second\n' >> "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "second patch (#2)"
  printf 'pr: 2\npr: 1\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "dependent proven patches replay in ancestry order: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: notes.txt' "the cumulative proven patch is accepted"
  pass "dependent proven patches are accepted regardless of proof-file order"
}

test_proven_commit_does_not_accept_earlier_unproven_content() {
  local repo i kept
  repo=$(fm_test_tmproot drift-inherited-content)
  fm_git_init_commit "$repo"
  for ((i = 1; i <= 20; i++)); do printf 'line %s\n' "$i"; done > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "upstream notes"
  git -C "$repo" branch upstream
  {
    printf 'unproven first line\n'
    for ((i = 2; i <= 20; i++)); do printf 'line %s\n' "$i"; done
  } > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "unproven first line"
  {
    printf 'unproven first line\n'
    for ((i = 2; i < 20; i++)); do printf 'line %s\n' "$i"; done
    printf 'proven last line\n'
  } > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven last line (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a proven patch cannot accept unrelated inherited content: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "earlier unproven content is still drift"
  pass "proof approves a patch rather than the commit's entire file snapshot"
}

test_proven_patch_built_on_unproven_change_is_drift_not_a_check_error() {
  local repo i kept later
  repo=$(fm_test_tmproot drift-stacked-proof)
  fm_git_init_commit "$repo"
  for ((i = 1; i <= 20; i++)); do printf 'line %s\n' "$i"; done > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "upstream notes"
  git -C "$repo" branch upstream
  {
    printf 'unproven first line\n'
    for ((i = 2; i <= 20; i++)); do printf 'line %s\n' "$i"; done
  } > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "unproven first line"
  {
    printf 'proven first line\n'
    for ((i = 2; i <= 20; i++)); do printf 'line %s\n' "$i"; done
  } > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven first line (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'proven\n' > "$repo/kept.txt"
  git -C "$repo" add kept.txt
  fixture_commit "$repo" "independent proven file (#8)"
  later=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\npr: 8\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a proven patch that only applies on unproven work exits 1, not 2: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "the stacked proven patch is reported as drift"
  assert_contains "$CHECK_OUT" 'path-ok: kept.txt' "a later independent proven patch is still accepted"
  assert_contains "$CHECK_OUT" "keep: $kept proven first line (#7)" "the stacked commit keeps its entry class and is named by the error line"
  assert_contains "$CHECK_OUT" "keep: $later independent proven file (#8)" "the later independent commit is still reported as keep"
  assert_contains "$CHECK_OUT" "error: proof patch conflicts for PR 7: $kept" "the conflicting proof is named with its PR and commit"
  pass "a proven patch built on unproven work is drift with a named error, not a check failure"
}

test_cut_unproven_changes_do_not_fail_after_restoration() {
  local repo
  repo=$(fm_test_tmproot drift-cut)
  fm_git_init_commit "$repo"
  printf 'upstream\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "upstream notes"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "unproven notes"
  printf 'upstream\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "cut unproven notes"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 0 "$CHECK_RC" "cut changes with no effective drift exit 0: $CHECK_ERR"
  assert_not_contains "$CHECK_OUT" 'path-drift:' "reverted historical changes are not effective drift"
  pass "cut unproven changes pass once their effective changes are gone"
}

test_proven_change_can_also_cut_unproven_changes() {
  local repo kept
  repo=$(fm_test_tmproot drift-proof-and-cut)
  fm_git_init_commit "$repo"
  printf 'upstream\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "upstream notes"
  git -C "$repo" branch upstream
  printf 'unproven\n' > "$repo/notes.txt"
  printf 'unproven\n' > "$repo/extra.txt"
  git -C "$repo" add notes.txt extra.txt
  fixture_commit "$repo" "unproven changes"
  printf 'upstream\n' > "$repo/notes.txt"
  git -C "$repo" rm -q extra.txt
  printf 'proven\n' > "$repo/kept.txt"
  git -C "$repo" add notes.txt kept.txt
  fixture_commit "$repo" "cut unproven changes and add proven patch (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a proven patch with already-cut changes replays: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: kept.txt' "the retained measured patch is accepted"
  assert_not_contains "$CHECK_OUT" 'path-drift:' "cut changes are not required patch dependencies"
  pass "a proven change can cut unrelated unproven changes in the same commit"
}

test_missing_proven_patch_is_drift() {
  local repo kept
  repo=$(fm_test_tmproot drift-missing-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven notes (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  git -C "$repo" rm -q notes.txt
  fixture_commit "$repo" "remove proven notes"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "removing an accepted patch without changing proof exits 1"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "a missing accepted file is reported even when fork matches upstream"
  pass "missing accepted patches are reported as drift"
}

test_unproven_mode_change_is_drift() {
  local repo kept
  repo=$(fm_test_tmproot drift-mode)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "proven notes (#7)"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 7\n' > "$repo/proof.txt"
  chmod +x "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "unproven executable mode"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "unproven file modes exit 1"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "unproven executable mode is reported"
  pass "unproven file modes cannot borrow content proof"
}

test_pending_commit_is_accepted_and_printed_with_its_bead() {
  local repo sha
  repo=$(fm_test_tmproot drift-pending)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf 'pending-pr: 7 bead-7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a pending commit is accepted: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
pending: $sha bead-7 add notes (#7)" "$CHECK_OUT" "a pending commit is printed with its bead, not as keep"
  printf 'pending-pr: 7\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 2 "$CHECK_RC" "a pending line without a bead exits 2"
  assert_contains "$CHECK_ERR" "pending-pr line is not '<number> <bead>'" "a bead-less pending line is an actionable error"
  pass "a pending commit is accepted, printed with its bead on every run, and must name its bead"
}

test_merge_merged_branch_carries_its_own_pending_line() {
  local repo merge carried
  repo=$(fm_test_tmproot drift-merge-pending)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  git -C "$repo" switch -q -c fm/feature
  printf 'custom\n' > "$repo/notes.txt"
  printf 'pending-pr: 8 .agent-config-dtjsb\n' > "$repo/drift-proof.txt"
  git -C "$repo" add notes.txt drift-proof.txt
  fixture_commit "$repo" "add notes"
  carried=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q main
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge -q --no-ff -m "Merge pull request #8 from gsp-agent/fm/feature" fm/feature
  merge=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 0 "$CHECK_RC" "a merge carrying its own pending line exits 0: $CHECK_ERR"
  assert_contains "$CHECK_OUT" "pending: $merge .agent-config-dtjsb Merge pull request #8 from gsp-agent/fm/feature" "the merge is pending by its PR number"
  assert_contains "$CHECK_OUT" "pending: $carried .agent-config-dtjsb add notes" "the carried commit inherits the carrying PR's class"
  pass "a merge-merged branch carries its own pending line and its carried commits inherit it"
}

test_two_open_prs_with_their_own_proof_files_land_without_a_conflict() {
  local repo a b
  repo=$(fm_test_tmproot drift-proof-dir)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf '# closed manifest\npr: 6\n' > "$repo/drift-proof.txt"
  printf 'six\n' > "$repo/six.txt"
  git -C "$repo" add drift-proof.txt six.txt
  fixture_commit "$repo" "add six (#6)"
  # The old way: two open PRs append to the same file, so the second conflicts.
  git -C "$repo" switch -q -c old/a
  printf 'pr: 7\n' >> "$repo/drift-proof.txt"
  git -C "$repo" add drift-proof.txt
  fixture_commit "$repo" "a"
  git -C "$repo" switch -q -c old/b main
  printf 'pr: 8\n' >> "$repo/drift-proof.txt"
  git -C "$repo" add drift-proof.txt
  fixture_commit "$repo" "b"
  git -C "$repo" switch -q main
  git -C "$repo" merge -q --squash old/a && fixture_commit "$repo" "old a (#7)"
  if git -C "$repo" merge -q --squash old/b >/dev/null 2>&1; then
    fail "two appends to drift-proof.txt were expected to conflict"
  fi
  git -C "$repo" reset -q --hard main~1
  # The new way: each PR writes drift-proof/<N>.proof, so both land cleanly.
  git -C "$repo" switch -q -c fm/a
  mkdir -p "$repo/drift-proof"
  printf 'a\n' > "$repo/a.txt"
  printf '# a test\npr: 7\n' > "$repo/drift-proof/7.proof"
  git -C "$repo" add a.txt drift-proof/7.proof
  fixture_commit "$repo" "a"
  git -C "$repo" switch -q -c fm/b main
  mkdir -p "$repo/drift-proof"
  printf 'b\n' > "$repo/b.txt"
  printf 'pending-pr: 8 bead-8\n' > "$repo/drift-proof/8.proof"
  git -C "$repo" add b.txt drift-proof/8.proof
  fixture_commit "$repo" "b"
  git -C "$repo" switch -q main
  git -C "$repo" merge -q --squash fm/a || fail "the first PR's squash failed"
  fixture_commit "$repo" "add a (#7)"
  a=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" merge -q --squash fm/b || fail "the second PR's squash conflicted"
  fixture_commit "$repo" "add b (#8)"
  b=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 0 "$CHECK_RC" "drift-proof.txt and drift-proof/<N>.proof together prove every PR: $CHECK_OUT $CHECK_ERR"
  assert_contains "$CHECK_OUT" "keep: $a add a (#7)" "drift-proof/7.proof proves PR 7"
  assert_contains "$CHECK_OUT" "pending: $b bead-8 add b (#8)" "drift-proof/8.proof carries PR 8's pending line"
  assert_contains "$CHECK_OUT" 'path-ok: drift-proof/8.proof' "the proof files are replayed like any other path"
  assert_not_contains "$CHECK_OUT" 'error:' "no PR is missing an entry"
  printf 'pr: 7\n' > "$repo/drift-proof/9.proof"
  git -C "$repo" add drift-proof/9.proof
  fixture_commit "$repo" "copy (#9)"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 2 "$CHECK_RC" "a proof file naming another PR exits 2"
  assert_contains "$CHECK_ERR" 'drift-proof/9.proof holds an entry for another PR: pr: 7' "the wrong file is named"
  git -C "$repo" rm -q drift-proof/9.proof
  printf 'pr: 9\n' > "$repo/drift-proof/nine.proof"
  git -C "$repo" add drift-proof/nine.proof
  fixture_commit "$repo" "misnamed (#10)"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 2 "$CHECK_RC" "a proof file not named <number>.txt exits 2"
  assert_contains "$CHECK_ERR" 'drift-proof entry is not drift-proof/<number>.proof: drift-proof/nine.proof' "the misnamed file is named"
  git -C "$repo" rm -q drift-proof/nine.proof
  printf 'pr: 7\n' >> "$repo/drift-proof.txt"
  git -C "$repo" add drift-proof.txt
  fixture_commit "$repo" "dup (#11)"
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 2 "$CHECK_RC" "an entry in both places exits 2"
  assert_contains "$CHECK_ERR" 'duplicate proof entry for PR 7' "a PR proven twice is an error"
  pass "two open PRs with their own drift-proof/<N>.proof land without a conflict and both are proven"
}

test_repo_drift_proof_txt_takes_no_entry_after_pr_167() {
  local late
  # drift-proof.txt closed at PR 167; every later PR writes drift-proof/<N>.proof.
  late=$(awk '/^(pr|pending-pr): / { if ($2 + 0 > 167) print }' "$ROOT/drift-proof.txt")
  assert_equals '' "$late" "move these entries to drift-proof/<N>.proof"
  pass "this repo's drift-proof.txt takes no entry after PR 167"
}

test_forgotten_manifest_line_is_path_drift_and_unproven() {
  local repo sha
  repo=$(fm_test_tmproot drift-forgotten-line)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  git -C "$repo" switch -q -c fm/feature
  printf 'custom\n' > "$repo/notes.txt"
  printf '# no line for this PR\n' > "$repo/drift-proof.txt"
  git -C "$repo" add notes.txt drift-proof.txt
  fixture_commit "$repo" "add notes"
  git -C "$repo" switch -q main
  git -C "$repo" merge -q --squash fm/feature
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "a PR that forgets its manifest line exits 1"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "the forgotten PR's path drifts"
  assert_contains "$CHECK_OUT" "unproven: $sha add notes (#7)" "the forgotten PR is unproven"
  pass "a forgotten manifest line is path-drift and unproven"
}

test_wrong_proof_pr_number_stays_red_and_is_named() {
  local repo sha
  repo=$(fm_test_tmproot drift-wrongnum-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'custom\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "add notes (#7)"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf 'pr: 99\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a wrong PR number exits 1: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-drift: notes.txt
unproven: $sha add notes (#7)
error: missing manifest entry for PR 7
unmatched: 99" "$CHECK_OUT" "the wrong number authorizes nothing and is named unmatched"
  pass "a wrong proof PR number authorizes nothing, stays red, and is named unmatched"
}

test_reverted_numbered_pr_without_manifest_stays_red() {
  local kind root repo entry
  for kind in squash merge; do
    root=$(fm_test_tmproot "drift-reverted-$kind")
    nightly_fixture "$root"
    repo=$root/repo
    git -C "$repo" switch -q -c fm/feature
    printf 'custom\n' > "$repo/notes.txt"
    git -C "$repo" add notes.txt
    fixture_commit "$repo" "add notes (#17)"
    git -C "$repo" switch -q main
    if [ "$kind" = squash ]; then
      git -C "$repo" merge -q --squash fm/feature
      fixture_commit "$repo" "add notes (#7)"
    else
      git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge -q --no-ff -m "Merge pull request #7 from gsp-agent/fm/feature" fm/feature
    fi
    git -C "$repo" rm -q notes.txt
    printf 'pr: 8\n' > "$repo/drift-proof.txt"
    git -C "$repo" add drift-proof.txt
    fixture_commit "$repo" "cut notes (#8)"
    run_check "$repo" --upstream kunchenguid/main
    expect_code 1 "$CHECK_RC" "a forgotten $kind PR stays red after a listed PR reverts it: $CHECK_ERR"
    assert_not_contains "$CHECK_OUT" 'path-drift:' "the $kind replay matches the fork tree"
    assert_contains "$CHECK_OUT" 'error: missing manifest entry for PR 7' "the forgotten $kind PR is named"
    assert_not_contains "$CHECK_OUT" 'error: missing manifest entry for PR 17' "a carried PR is not a first-parent PR"
    run_nightly "$root"
    expect_code 1 "$NIGHTLY_RC" "the nightly stays red for the forgotten $kind PR"
    assert_equals 1 "$(note_count "$root/home")" "the forgotten $kind PR sends one note"
    assert_contains "$(note_body "$root/home")" 'error: missing manifest entry for PR 7' "the nightly note names the forgotten $kind PR"
    for entry in 'pr: 7' 'pending-pr: 7 bead-7'; do
      printf 'pr: 8\n%s\n' "$entry" > "$repo/proof.txt"
      run_check "$repo" --upstream kunchenguid/main --proof "$repo/proof.txt"
      expect_code 0 "$CHECK_RC" "the reverted $kind PR accepts $entry: $CHECK_ERR"
      assert_not_contains "$CHECK_OUT" 'error:' "a listed $kind PR has no missing entry"
    done
  done
  pass "reverted numbered squash and merge PRs require manifest entries and send nightly notes"
}

test_open_pr_own_line_is_unmatched_until_its_squash_lands() {
  local repo branch squash
  repo=$(fm_test_tmproot drift-open-pr)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  git -C "$repo" switch -q -c fm/feature
  printf 'custom\n' > "$repo/notes.txt"
  printf 'pr: 7\n' > "$repo/drift-proof.txt"
  git -C "$repo" add notes.txt drift-proof.txt
  fixture_commit "$repo" "add notes"
  branch=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "an open PR carrying its own line exits 1, not 2: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-drift: drift-proof.txt
path-drift: notes.txt
unproven: $branch add notes
unmatched: 7" "$CHECK_OUT" "the open branch reports its own unsquashed changes and its own line"
  git -C "$repo" switch -q main
  git -C "$repo" merge -q --squash fm/feature
  fixture_commit "$repo" "add notes (#7)"
  squash=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 0 "$CHECK_RC" "the same line passes once its squash lands: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-ok: drift-proof.txt
path-ok: notes.txt
keep: $squash add notes (#7)" "$CHECK_OUT" "the landed squash matches its line"
  pass "an open PR's own line is reported unmatched without failing the check, and matches once its squash lands"
}

test_behind_count_is_reported_and_does_not_fail_alone() {
  local repo
  repo=$(fm_test_tmproot drift-behind)
  fm_git_init_commit "$repo"
  git -C "$repo" branch fork
  printf 'upstream\n' > "$repo/upstream.txt"
  git -C "$repo" add upstream.txt
  fixture_commit "$repo" "upstream only"
  git -C "$repo" switch -q fork
  run_check "$repo" --fork fork --upstream main
  expect_code 0 "$CHECK_RC" "behind alone exits 0: $CHECK_ERR"
  assert_equals "behind: 1
ahead: 0" "$CHECK_OUT" "behind is 1 and ahead is 0 with no path lines"
  pass "behind is reported and does not fail the check by itself"
}

test_merge_commit_is_labeled_merge() {
  local repo side merge
  repo=$(fm_test_tmproot drift-merge)
  fm_git_init_commit "$repo"
  git -C "$repo" branch side
  git -C "$repo" switch -q side
  printf 'side\n' > "$repo/side.txt"
  git -C "$repo" add side.txt
  fixture_commit "$repo" "side file"
  side=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q main
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge --no-ff -qm "merge side" side
  merge=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork main --upstream side
  expect_code 0 "$CHECK_RC" "a merge with no extra file exits 0: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
merge: $merge merge side" "$CHECK_OUT" "the merge commit is labeled merge"
  # side sha is not listed because it is the upstream ref.
  assert_not_contains "$CHECK_OUT" "$side" "the upstream side commit is not an ahead commit"
  pass "a merge commit is labeled merge and adds no path-drift when its tree matches upstream"
}

test_nightly_red_sends_one_note_a_day_and_green_sends_none() {
  local root day
  root=$(fm_test_tmproot drift-nightly-note)
  nightly_fixture "$root"
  run_nightly "$root"
  expect_code 0 "$NIGHTLY_RC" "a green nightly exits 0: $(cat "$root/drift.log")"
  assert_equals 0 "$(note_count "$root/home")" "a green nightly sent a note"
  printf 'custom\n' > "$root/repo/notes.txt"
  git -C "$root/repo" add notes.txt
  fixture_commit "$root/repo" "add notes"
  day=$(date +%F)
  run_nightly "$root"
  expect_code 1 "$NIGHTLY_RC" "a nightly with path-drift exits 1"
  run_nightly "$root"
  expect_code 1 "$NIGHTLY_RC" "a same-day rerun still exits 1"
  assert_equals 1 "$(note_count "$root/home")" "a red nightly and its same-day rerun make exactly one note"
  assert_equals "Nightly drift check red on $day: exit 1 for $root/repo.
path-drift: notes.txt
Log: $root/drift.log" "$(note_body "$root/home")" "the note names the red line and the log"
  assert_grep "request_id=fm-drift-nightly-$day" "$root/home/state/inbox/"*.note "the note is keyed to the run date"
  assert_grep 'ahead: 0' "$root/drift.log" "the log keeps the green run's report"
  assert_grep 'path-drift: notes.txt' "$root/drift.log" "the log keeps the red run's report"
  pass "a red nightly sends one note a day naming its red lines and log, and a green one sends none"
}

test_nightly_check_error_is_red() {
  local root
  root=$(fm_test_tmproot drift-nightly-error)
  fm_git_init_commit "$root/repo"
  mkdir -p "$root/home"
  run_nightly "$root"
  expect_code 2 "$NIGHTLY_RC" "a nightly whose check cannot run exits 2"
  assert_equals "Nightly drift check red on $(date +%F): exit 2 for $root/repo.
error: kunchenguid remote is missing
Log: $root/drift.log" "$(note_body "$root/home")" "the note names the check error and the log"
  pass "a nightly whose check exits 2 sends one note naming the error"
}

test_nightly_note_names_at_most_ten_red_lines() {
  local root i body
  root=$(fm_test_tmproot drift-nightly-cap)
  nightly_fixture "$root"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    printf 'custom\n' > "$root/repo/notes-$i.txt"
  done
  git -C "$root/repo" add .
  fixture_commit "$root/repo" "add twelve notes"
  run_nightly "$root"
  expect_code 1 "$NIGHTLY_RC" "a nightly with twelve drifted paths exits 1"
  body=$(note_body "$root/home")
  assert_contains "$body" "path-drift: notes-10.txt
2 more red lines in the log.
Log: $root/drift.log" "the note stops after ten red lines and points at the log"
  assert_not_contains "$body" "notes-11.txt" "the note pasted an eleventh red line"
  assert_grep 'path-drift: notes-12.txt' "$root/drift.log" "the log keeps every red line"
  pass "a nightly note names at most ten red lines and counts the rest in the log"
}

test_install_dry_run_writes_nothing() {
  local dir out rc
  dir=$(fm_test_tmproot drift-dry-install)
  rc=0
  out=$(HOME="$dir/home" FM_DRIFT_AGENT_DIR="$dir" "$SCRIPT" install --dry-run --hour 4 --minute 5 --repo /tmp/example-repo) || rc=$?
  expect_code 0 "$rc" "install --dry-run exits 0"
  assert_equals "dry-run: install
label: dev.firstmate.drift-nightly
hour: 4
minute: 5
plist: $dir/dev.firstmate.drift-nightly.plist
repo: /tmp/example-repo
log: $dir/home/Library/Logs/dev.firstmate.drift-nightly.log" "$out" "install --dry-run prints the job and does not describe a write"
  assert_absent "$dir/dev.firstmate.drift-nightly.plist" "install --dry-run created a plist"
  assert_absent "$dir/home" "install --dry-run created the log directory"
  pass "install --dry-run prints the job and writes nothing"
}

test_install_and_uninstall_round_trip() {
  local dir log fake repo out rc plist lint joblog
  dir=$(fm_test_tmproot drift-install)
  log=$dir/launchctl.log
  fake=$(fake_launchctl "$dir")
  lint=$(lint_path "$dir")
  repo=$dir/repo
  joblog=$dir/logs/drift.log
  mkdir -p "$repo"
  plist=$dir/agents/dev.firstmate.drift-nightly.plist
  rc=0
  out=$(PATH="$lint" FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" install --hour 3 --minute 17 --repo "$repo" --log "$joblog") || rc=$?
  expect_code 0 "$rc" "install exits 0"
  assert_equals "installed: $plist" "$out" "install names the plist it wrote"
  assert_present "$plist" "install did not write the plist"
  assert_grep "bootstrap gui/$(id -u) $plist" "$log" "install did not bootstrap the agent"
  python3 -I - "$plist" "$SCRIPT" "$repo" "$joblog" <<'PY' || fail 'the plist schedule or command arguments are incorrect'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    job = plistlib.load(stream)
assert job["StartCalendarInterval"] == {"Hour": 3, "Minute": 17}, job["StartCalendarInterval"]
assert job["ProgramArguments"] == [
    "/bin/bash", sys.argv[2], "nightly", "--repo", sys.argv[3], "--log", sys.argv[4]
], job["ProgramArguments"]
PY
  assert_present "$dir/logs" "install did not create the log directory launchd writes into"
  assert_equals "$joblog" "$(plist_value "$plist" StandardOutPath)" "the job's stdout does not go to the log"
  assert_equals "$joblog" "$(plist_value "$plist" StandardErrorPath)" "the job's stderr does not go to the log"
  printf 'red run report\n' > "$joblog"
  : > "$log"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall) || rc=$?
  expect_code 0 "$rc" "uninstall exits 0"
  assert_equals "uninstalled: removed" "$out" "uninstall reports removed"
  assert_absent "$plist" "uninstall left the plist"
  assert_grep "bootout gui/$(id -u)/dev.firstmate.drift-nightly" "$log" "uninstall did not bootout the agent"
  assert_equals "red run report" "$(cat "$joblog")" "uninstall did not keep the log"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall) || rc=$?
  expect_code 0 "$rc" "a second uninstall exits 0"
  assert_equals "uninstalled: absent" "$out" "a second uninstall reports absent"
  pass "install writes the nightly agent and its log path, and uninstall removes it, keeps the log, and repeats"
}

test_install_escapes_xml_in_script_repo_and_log_paths() {
  local dir log fake lint tools repo joblog out rc plist
  dir=$(fm_test_tmproot drift-install-xml)
  log=$dir/launchctl.log
  fake=$(fake_launchctl "$dir")
  lint=$(lint_path "$dir")
  tools="$dir/tools & <bin>"
  repo="$dir/repo & <copy> \"it's\""
  joblog="$dir/logs & <x>/drift.log"
  mkdir -p "$tools" "$repo"
  cp "$SCRIPT" "$tools/fm-drift-nightly.sh"
  plist=$dir/agents/dev.firstmate.drift-nightly.plist
  rc=0
  out=$(PATH="$lint" FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    bash "$tools/fm-drift-nightly.sh" install --repo "$repo" --log "$joblog" 2>&1) || rc=$?
  expect_code 0 "$rc" "install from paths holding XML specials exits 0: $out"
  assert_equals "/bin/bash
$tools/fm-drift-nightly.sh
nightly
--repo
$repo
--log
$joblog" "$(plist_args "$plist" 2>&1)" "a plist parser reads back the exact script, repo and log paths"
  assert_equals "$joblog" "$(plist_value "$plist" StandardOutPath 2>&1)" "a plist parser reads back the exact log path"
  assert_equals "bootout gui/$(id -u)/dev.firstmate.drift-nightly
bootstrap gui/$(id -u) $plist" "$(cat "$log")" "install boots out the old job, then bootstraps the new plist"
  pass "install escapes &, <, > and quotes in the script, repo and log paths"
}

test_install_keeps_the_installed_job_when_the_plist_is_invalid() {
  local dir log fake lint repo out rc plist before
  dir=$(fm_test_tmproot drift-install-invalid)
  log=$dir/launchctl.log
  fake=$(fake_launchctl "$dir")
  lint=$(lint_path "$dir")
  repo=$dir/repo
  mkdir -p "$repo"
  plist=$dir/agents/dev.firstmate.drift-nightly.plist
  rc=0
  out=$(PATH="$lint" FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" install --repo "$repo" --log "$dir/drift.log" 2>&1) || rc=$?
  expect_code 0 "$rc" "the first install exits 0: $out"
  before=$(cat "$plist")
  : > "$log"
  rc=0
  out=$(PATH="$lint" FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$fake" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" install --repo "$dir/not-utf8-"$'\377' --log "$dir/drift.log" 2>&1) || rc=$?
  expect_code 2 "$rc" "a reinstall whose plist fails lint exits 2"
  assert_contains "$out" "installed job unchanged" "the refusal says the installed job is unchanged"
  assert_equals "" "$(cat "$log")" "a refused reinstall called launchctl"
  assert_equals "$before" "$(cat "$plist")" "a refused reinstall changed the installed plist"
  assert_equals "dev.firstmate.drift-nightly.plist" "$(ls -A "$dir/agents")" "a refused reinstall leaves a stray file"
  pass "a reinstall whose plist fails lint leaves the installed job and plist unchanged"
}

test_uninstall_keeps_the_plist_unless_launchctl_reports_the_job_gone() {
  local dir log lint repo out rc plist
  dir=$(fm_test_tmproot drift-uninstall-error)
  log=$dir/launchctl.log
  lint=$(lint_path "$dir")
  repo=$dir/repo
  mkdir -p "$repo"
  plist=$dir/agents/dev.firstmate.drift-nightly.plist
  exiting_launchctl "$dir/launchctl-ok" 0 1
  exiting_launchctl "$dir/launchctl-71" 71 71
  exiting_launchctl "$dir/launchctl-absent" 3 113
  rc=0
  out=$(PATH="$lint" FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$dir/launchctl-ok" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" install --repo "$repo" --log "$dir/drift.log" 2>&1) || rc=$?
  expect_code 0 "$rc" "install exits 0: $out"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$dir/launchctl-71" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall 2>&1) || rc=$?
  expect_code 2 "$rc" "uninstall exits 2 when launchctl fails with 71"
  assert_equals "error: launchctl bootout gui/$(id -u)/dev.firstmate.drift-nightly failed with exit 71; kept $plist" "$out" "uninstall names the launchctl failure and the kept plist"
  assert_present "$plist" "uninstall deleted the plist after launchctl failed"
  rc=0
  out=$(FM_DRIFT_AGENT_DIR="$dir/agents" FM_DRIFT_LAUNCHCTL="$dir/launchctl-absent" FM_DRIFT_LAUNCHCTL_LOG="$log" \
    "$SCRIPT" uninstall 2>&1) || rc=$?
  expect_code 0 "$rc" "uninstall exits 0 when launchctl reports no such service"
  assert_equals "uninstalled: removed" "$out" "uninstall reports removed when the job is not loaded"
  assert_absent "$plist" "uninstall kept the plist of a job launchctl reports absent"
  pass "uninstall deletes the plist only when bootout succeeds or launchctl reports no such service"
}

test_documented_cut_recovery_restores_a_cut_from_the_bundle() {
  local dir scratch cmd sha base out rc
  sha=b606779ed08299d160ccbb154ec7c0dc8277b9d8
  base=20dcbf91520b1816663b81873ad67d0b93b3e4d6
  cmd=$(sed -n 's/^# Recover a cut: //p' "$ROOT/drift-proof.txt")
  assert_contains "$cmd" "<sha>" "drift-proof.txt documents no '# Recover a cut: ' command taking <sha>"
  dir=$(fm_test_tmproot drift-recover)
  scratch=$dir/repo
  git init -q "$scratch"
  git -C "$scratch" fetch -q "$ROOT" "$base" 7df545bf74ff729ed1733f77b0aea02a9b164ac1 ||
    fail "cannot fetch the bundle prerequisites from $ROOT"
  git -C "$scratch" switch -q --detach "$base"
  ! git -C "$scratch" cat-file -e "$sha^{commit}" 2>/dev/null || fail "the scratch repository already holds the cut commit"
  mkdir -p "$scratch/archives"
  cp "$ROOT/archives/fork-cuts.bundle" "$scratch/archives/"
  rc=0
  out=$(cd "$scratch" &&
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid' \
      GIT_COMMITTER_NAME='Firstmate Tests' GIT_COMMITTER_EMAIL='tests@example.invalid' &&
    eval "${cmd//<sha>/$sha}" 2>&1) || rc=$?
  expect_code 0 "$rc" "the documented recovery command exits 0: $out"
  assert_equals "$base" "$(git -C "$scratch" rev-parse 'HEAD^')" "the recovery adds one commit on top of the starting head"
  assert_equals "$(git -C "$scratch" rev-parse "$sha^{tree}")" "$(git -C "$scratch" rev-parse 'HEAD^{tree}')" "the recovered commit has the cut commit's tree"
  pass "the documented cut recovery restores a cut commit from the bundle alone"
}

test_bad_install_arguments_exit_2() {
  local rc out
  rc=0
  out=$("$SCRIPT" install --hour 24 2>&1) || rc=$?
  expect_code 2 "$rc" "hour 24 exits 2"
  assert_equals "error: --hour must be 0 through 23" "$out" "hour 24 names the rejected range"
  rc=0
  out=$("$SCRIPT" install --dry-run --log drift.log 2>&1) || rc=$?
  expect_code 2 "$rc" "a relative log path exits 2"
  assert_equals "error: --log must be an absolute path" "$out" "a relative log path is named as the error"
  pass "install rejects hour 24 and a relative log path"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit
fi

test_unproven_file_is_path_drift_and_exits_1
test_proof_sha_makes_that_path_ok_and_exits_0
test_squash_merged_branch_carries_its_own_manifest_line
test_default_proof_comes_from_the_committed_fork_tree
test_guard_files_have_no_exemptions
test_unproven_edit_to_proven_file_exits_1
test_unproven_deletion_cannot_rename_into_proven_file
test_moving_ref_keeps_one_snapshot fork refs/heads/main
test_moving_ref_keeps_one_snapshot upstream refs/heads/upstream
test_snapshot_includes_fetched_upstream
test_proven_patches_are_replayed_in_ancestry_order
test_proven_commit_does_not_accept_earlier_unproven_content
test_proven_patch_built_on_unproven_change_is_drift_not_a_check_error
test_cut_unproven_changes_do_not_fail_after_restoration
test_proven_change_can_also_cut_unproven_changes
test_missing_proven_patch_is_drift
test_unproven_mode_change_is_drift
test_pending_commit_is_accepted_and_printed_with_its_bead
test_merge_merged_branch_carries_its_own_pending_line
test_two_open_prs_with_their_own_proof_files_land_without_a_conflict
test_repo_drift_proof_txt_takes_no_entry_after_pr_167
test_forgotten_manifest_line_is_path_drift_and_unproven
test_wrong_proof_pr_number_stays_red_and_is_named
test_reverted_numbered_pr_without_manifest_stays_red
test_open_pr_own_line_is_unmatched_until_its_squash_lands
test_behind_count_is_reported_and_does_not_fail_alone
test_merge_commit_is_labeled_merge
test_nightly_red_sends_one_note_a_day_and_green_sends_none
test_nightly_check_error_is_red
test_nightly_note_names_at_most_ten_red_lines
test_install_dry_run_writes_nothing
test_install_and_uninstall_round_trip
test_install_escapes_xml_in_script_repo_and_log_paths
test_install_keeps_the_installed_job_when_the_plist_is_invalid
test_uninstall_keeps_the_plist_unless_launchctl_reports_the_job_gone
test_documented_cut_recovery_restores_a_cut_from_the_bundle
test_bad_install_arguments_exit_2
