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

plist_value() { # <plist> <key> -> that string value, read by a strict XML plist parser
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
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
  fixture_commit "$repo" "add notes"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$sha" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a proven file exits 0"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
keep: $sha add notes" "$CHECK_OUT" "a proof sha marks the path and the commit"
  pass "a proof sha makes that path ok and the check exits 0"
}

test_manifest_accepts_its_own_commit_without_accepting_later_edits() {
  local repo parent kept later
  repo=$(fm_test_tmproot drift-self-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  parent=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$repo/bin"
  printf 'guard contract\n' > "$repo/bin/fm-drift-nightly.sh"
  printf 'after: %s\n' "$parent" > "$repo/drift-proof.txt"
  git -C "$repo" add bin/fm-drift-nightly.sh drift-proof.txt
  fixture_commit "$repo" "finalized measured patches and proof"
  kept=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --upstream upstream
  expect_code 0 "$CHECK_RC" "the shipped manifest accepts its finalized patch: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: drift-proof.txt' "the proof file itself matches the accepted patch"
  assert_contains "$CHECK_OUT" "keep: $kept finalized measured patches and proof" "the fixed parent resolves to the acceptance commit"
  printf 'unproven guard edit\n' >> "$repo/bin/fm-drift-nightly.sh"
  printf '# unproven proof edit\n' >> "$repo/drift-proof.txt"
  git -C "$repo" add bin/fm-drift-nightly.sh drift-proof.txt
  fixture_commit "$repo" "later unproven edits"
  later=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --upstream upstream
  expect_code 1 "$CHECK_RC" "the same manifest rejects later guard and proof edits"
  assert_contains "$CHECK_OUT" 'path-drift: bin/fm-drift-nightly.sh' "the guard has no exemption"
  assert_contains "$CHECK_OUT" 'path-drift: drift-proof.txt' "the manifest has no exemption"
  assert_contains "$CHECK_OUT" "unproven: $later later unproven edits" "acceptance stays pinned after another commit"
  pass "a shipped proof accepts its own patch and rejects later edits"
}

test_parent_proof_does_not_accept_inherited_unproven_changes() {
  local repo parent
  repo=$(fm_test_tmproot drift-parent-inherited)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'unproven\n' > "$repo/unproven.txt"
  git -C "$repo" add unproven.txt
  fixture_commit "$repo" "unproven earlier change"
  parent=$(git -C "$repo" rev-parse HEAD)
  printf 'after: %s\n' "$parent" > "$repo/drift-proof.txt"
  git -C "$repo" add drift-proof.txt
  fixture_commit "$repo" "accepted manifest patch"
  run_check "$repo" --upstream upstream
  expect_code 1 "$CHECK_RC" "parent proof accepts only the child patch: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: drift-proof.txt' "the accepted manifest patch is replayed"
  assert_contains "$CHECK_OUT" 'path-drift: unproven.txt' "unproven parent content remains drift"
  pass "parent proof does not approve inherited unproven content"
}

test_parent_proof_requires_one_direct_child() {
  local repo parent
  repo=$(fm_test_tmproot drift-parent-ambiguity)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  parent=$(git -C "$repo" rev-parse HEAD)
  printf 'after: %s\n' "$parent" > "$repo/proof.txt"
  run_check "$repo" --upstream upstream --proof "$repo/proof.txt"
  expect_code 2 "$CHECK_RC" "an acceptance parent with no child is an error"
  assert_contains "$CHECK_ERR" 'proof parent has no direct child:' "missing acceptance is actionable"
  git -C "$repo" switch -q -c side
  printf 'side\n' > "$repo/side.txt"
  git -C "$repo" add side.txt
  fixture_commit "$repo" "side child"
  git -C "$repo" switch -q main
  printf 'main\n' > "$repo/main.txt"
  git -C "$repo" add main.txt
  fixture_commit "$repo" "main child"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge --no-ff -qm "merge both children" side
  run_check "$repo" --upstream upstream --proof "$repo/proof.txt"
  expect_code 2 "$CHECK_RC" "two reachable children cannot share an acceptance parent"
  assert_contains "$CHECK_ERR" 'proof parent has multiple direct children:' "ambiguous acceptance fails closed"
  pass "parent proof refuses missing or ambiguous acceptance commits"
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
  fixture_commit "$repo" "add guard files"
  sha=$(git -C "$repo" rev-parse HEAD)
  run_check "$repo" --fork HEAD --upstream upstream
  expect_code 1 "$CHECK_RC" "unproven guard files exit 1"
  assert_equals "behind: 0
ahead: 1
path-drift: bin/fm-drift-nightly.sh
path-drift: docs/scripts.md
path-drift: drift-proof.txt
path-drift: tests/fm-drift-nightly.test.sh
unproven: $sha add guard files" "$CHECK_OUT" "every unproven guard file drifts"
  printf '%s\n' "$sha" > "$repo/proof.txt"
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
  fixture_commit "$repo" "proven notes"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
keep: $kept proven notes" "$CHECK_OUT" "the later edit cannot borrow the earlier proof"
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
  fixture_commit "$repo" "proven copy"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
  fixture_commit "$repo" "proven notes"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
keep: $kept proven notes" "$CHECK_OUT" "counts, paths, and commit reporting use the captured $name snapshot"
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
  fixture_commit "$repo" "proven notes"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
keep: $kept proven notes" "$CHECK_OUT" "upstream is captured after the real fetch updates it"
  assert_equals "$(git -C "$upstream_repo" rev-parse HEAD)" "$(git -C "$repo" rev-parse kunchenguid/main)" "the real fetch advanced the upstream ref"
  pass "the captured upstream includes updates from the completed fetch"
}

test_proven_patches_are_replayed_in_ancestry_order() {
  local repo first second
  repo=$(fm_test_tmproot drift-ordered-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf 'first\n' > "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "first patch"
  first=$(git -C "$repo" rev-parse HEAD)
  printf 'second\n' >> "$repo/notes.txt"
  git -C "$repo" add notes.txt
  fixture_commit "$repo" "second patch"
  second=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n%s\n' "$second" "$first" > "$repo/proof.txt"
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
  fixture_commit "$repo" "proven last line"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a proven patch cannot accept unrelated inherited content: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-drift: notes.txt' "earlier unproven content is still drift"
  pass "proof approves a patch rather than the commit's entire file snapshot"
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
  fixture_commit "$repo" "cut unproven changes and add proven patch"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
  fixture_commit "$repo" "proven notes"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
  fixture_commit "$repo" "proven notes"
  kept=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' "$kept" > "$repo/proof.txt"
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
  fixture_commit "$repo" "add notes"
  sha=$(git -C "$repo" rev-parse HEAD)
  printf 'pending: %s bead-7\n' "$sha" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a pending commit is accepted: $CHECK_ERR"
  assert_equals "behind: 0
ahead: 1
path-ok: notes.txt
pending: $sha bead-7 add notes" "$CHECK_OUT" "a pending commit is printed with its bead, not as keep"
  printf 'pending: %s\n' "$sha" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 2 "$CHECK_RC" "a pending line without a bead exits 2"
  assert_contains "$CHECK_ERR" "pending line is not '<full sha> <bead>'" "a bead-less pending line is an actionable error"
  pass "a pending commit is accepted, printed with its bead on every run, and must name its bead"
}

test_accepted_merge_carries_only_proven_or_pending_commits() {
  local repo kept proven pending merge
  repo=$(fm_test_tmproot drift-carried)
  fm_git_init_commit "$repo"
  printf 'upstream\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  fixture_commit "$repo" "upstream shared"
  git -C "$repo" branch upstream
  git -C "$repo" branch side
  printf 'fork\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  fixture_commit "$repo" "fork shared"
  kept=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q side
  printf 'side\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  fixture_commit "$repo" "side shared"
  proven=$(git -C "$repo" rev-parse HEAD)
  printf 'side\n' > "$repo/side.txt"
  git -C "$repo" add side.txt
  fixture_commit "$repo" "side file"
  pending=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q main
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge -q --no-ff --no-commit side >/dev/null 2>&1 || true
  printf 'fork\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt side.txt
  fixture_commit "$repo" "merge side keeping the fork's shared"
  merge=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n%s\n%s\npending: %s bead-9\n' "$kept" "$merge" "$proven" "$pending" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 0 "$CHECK_RC" "a merge carrying proven and pending commits replays only its own patch: $CHECK_ERR"
  assert_contains "$CHECK_OUT" 'path-ok: shared.txt' "the merge's resolution is accepted without replaying the carried patch"
  assert_contains "$CHECK_OUT" 'path-ok: side.txt' "the carried pending change is accepted through the merge"
  assert_contains "$CHECK_OUT" "pending: $pending bead-9 side file" "the carried pending commit is printed with its bead"
  assert_contains "$CHECK_OUT" "keep: $proven side shared" "the carried proven commit is a keep"
  printf '%s\n%s\n%s\n' "$kept" "$merge" "$proven" > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 1 "$CHECK_RC" "a carried commit that is neither proven nor pending exits 1"
  assert_contains "$CHECK_OUT" "carried-unproven: $pending side file" "the unlisted carried commit is named"
  assert_not_contains "$CHECK_OUT" 'path-drift:' "the failure comes from the unlisted commit, not from its content"
  pass "an accepted merge carries its commits only when each is proven or pending"
}

test_unknown_proof_commit_is_an_error() {
  local repo
  repo=$(fm_test_tmproot drift-unknown-proof)
  fm_git_init_commit "$repo"
  git -C "$repo" branch upstream
  printf '0000000000000000000000000000000000000000\n' > "$repo/proof.txt"
  run_check "$repo" --fork HEAD --upstream upstream --proof "$repo/proof.txt"
  expect_code 2 "$CHECK_RC" "unknown proof commits exit 2"
  assert_contains "$CHECK_ERR" 'proof commit not found:' "unknown proof is an actionable error"
  pass "unknown proof commits cannot silently authorize changes"
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
  assert_grep '<integer>3</integer>' "$plist" "the plist hour is not 3"
  assert_grep '<integer>17</integer>' "$plist" "the plist minute is not 17"
  assert_grep "$repo" "$plist" "the plist does not name the repo"
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

test_unproven_file_is_path_drift_and_exits_1
test_proof_sha_makes_that_path_ok_and_exits_0
test_manifest_accepts_its_own_commit_without_accepting_later_edits
test_parent_proof_does_not_accept_inherited_unproven_changes
test_parent_proof_requires_one_direct_child
test_guard_files_have_no_exemptions
test_unproven_edit_to_proven_file_exits_1
test_unproven_deletion_cannot_rename_into_proven_file
test_moving_ref_keeps_one_snapshot fork refs/heads/main
test_moving_ref_keeps_one_snapshot upstream refs/heads/upstream
test_snapshot_includes_fetched_upstream
test_proven_patches_are_replayed_in_ancestry_order
test_proven_commit_does_not_accept_earlier_unproven_content
test_cut_unproven_changes_do_not_fail_after_restoration
test_proven_change_can_also_cut_unproven_changes
test_missing_proven_patch_is_drift
test_unproven_mode_change_is_drift
test_pending_commit_is_accepted_and_printed_with_its_bead
test_accepted_merge_carries_only_proven_or_pending_commits
test_unknown_proof_commit_is_an_error
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
