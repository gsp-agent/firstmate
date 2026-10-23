#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh --queue-start: a queued ship whose whole
# note is the standard PM intake template is started from ONE read of its
# backlog item, taken under the task's spawn lock, and its brief is created
# through bin/fm-brief.sh's exclusive create, the claim a hand start meets too.
#
# Each case drives the real fm-spawn.sh, fm-brief.sh, fm-dispatch-resolve.sh
# and tasks-axi against a real markdown backlog, with a fake tmux, treehouse
# and quota-axi. The races are made deterministic by running the competing
# action from inside one of those fakes at the moment the race needs:
#   - quota-axi runs while fm-dispatch-resolve answers, after the locked read
#     and before the brief claim;
#   - tmux new-window runs after the brief claim, while the spawn lock is held.
# Assertions read record state (backlog row, task record, brief bytes, the
# fleet of launched windows), never message wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_SCAFFOLD="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-queue-start)
cd "$TMP_ROOT" || exit 1

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; a queue start reads the backlog through it)\n'
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  printf 'ok - skipped (python3 is not installed; a queue start decides the note with it)\n'
  exit 0
}

TEMPLATE_NOTE="pm-demo inbox 1792550000-AbCd12; done on the bead. no-mistakes, yolo off; merge on the PM's word. Default route."

# --- fixture ----------------------------------------------------------------

# A home with a real markdown backlog and dispatch rules, a project clone with
# an origin and a pooled worktree, and fakes for every tool the spawn path
# shells out to. QS_ON_RESOLVE and QS_ON_NEW_WINDOW name scripts the fake
# quota-axi and tmux run once, at their moment in the start.
make_home() {  # <name>
  local case_dir="$TMP_ROOT/$1" home fakebin
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$case_dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "label_routes": {"docs-only": {"harness": "codex", "model": "label-route-model", "effort": "high"}, "ep-opus": {"harness": "claude", "model": "claude-opus-5-5[1m]", "effort": "xhigh"}},
  "default": [{"harness": "claude", "model": "default-route-model", "effort": "xhigh"}]
}
EOF
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    printf '%s\n' "\$*" >> "$case_dir/windows"
    if [ -n "\${QS_ON_NEW_WINDOW:-}" ] && [ ! -e "$case_dir/on-new-window.done" ]; then
      : > "$case_dir/on-new-window.done"
      "\$QS_ON_NEW_WINDOW" || exit 1
    fi
    ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
if [ -n "\${QS_ON_RESOLVE:-}" ] && [ ! -e "$case_dir/on-resolve.done" ]; then
  : > "$case_dir/on-resolve.done"
  "\$QS_ON_RESOLVE" >/dev/null 2>&1
fi
exit 1
SH
  chmod +x "$fakebin/tmux" "$fakebin/quota-axi"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

# assert_line <line> <file> <msg>: <file> holds <line> as a whole line.
assert_line() {
  grep -x -F -- "$1" "$2" >/dev/null || fail "$3"
}

home_of() { printf '%s/home\n' "$1"; }
backlog_of() { printf '%s/home/data/backlog.md\n' "$1"; }
brief_of() { printf '%s/home/data/%s/brief.md\n' "$1" "$2"; }

add_item() {  # <case-dir> <id> <note> [kind]
  tasks-axi add "$2" "Title of $2" --kind "${4:-ship}" --repo project --body "$3" \
    --file "$(backlog_of "$1")" >/dev/null
}

show_field() {  # <case-dir> <id> <field>
  tasks-axi show "$2" --file "$(backlog_of "$1")" 2>/dev/null |
    sed -n "s/^  $3: *//p" | head -1
}

windows_for() {  # <case-dir> <id>
  grep -c -- "fm-$2" "$1/windows" 2>/dev/null || printf '0\n'
}

spawn_env() {  # <case-dir> <command...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' PATH="$case_dir/fakebin:$PATH" "$@"
}

queue_start() {  # <case-dir> <id> [extra args...]
  local case_dir=$1 id=$2
  shift 2
  spawn_env "$case_dir" "$SPAWN" "$id" "$case_dir/project" --queue-start "$@" 2>&1
}

hand_scaffold() {  # <case-dir> <id>
  spawn_env "$1" "$BRIEF_SCAFFOLD" "$2" project --mode no-mistakes 2>&1
}

hand_spawn() {  # <case-dir> <id>
  spawn_env "$1" "$SPAWN" "$2" "$1/project" --mode no-mistakes --yolo off --harness claude --model default-route-model --effort xhigh 2>&1
}

# A hand start's brief, written the way Firstmate writes one: scaffolded by
# fm-brief.sh, then both task subsections filled by hand.
hand_brief() {  # <case-dir> <id>
  local brief
  hand_scaffold "$1" "$2" >/dev/null || return 1
  brief=$(brief_of "$1" "$2")
  python3 -I - "$brief" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("{TASK}", "The captain's own words for this hand start.", 1)
text = text.replace("{FIRSTMATE_SPEC}", "- The hand start's own spec.", 1)
open(path, "w").write(text)
PY
}

# --- the start --------------------------------------------------------------

test_queue_start_starts_a_template_ship_from_its_note() {
  local case_dir id out rc=0 brief meta
  id=qs-template-a1
  case_dir=$(make_home template)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"

  out=$(queue_start "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "a template note did not start: $out"
  [ "$(show_field "$case_dir" "$id" state)" = in_flight ] \
    || fail "a started queue item is not In flight: $(show_field "$case_dir" "$id" state)"
  meta="$(home_of "$case_dir")/state/$id.meta"
  assert_present "$meta" "a started queue item has no task record"
  assert_line 'mode=no-mistakes' "$meta" "the template's mode was not recorded"
  assert_line 'yolo=off' "$meta" "the template's yolo was not recorded"
  assert_line 'harness=claude' "$meta" "the default route's harness was not used"
  assert_line 'model=default-route-model' "$meta" "the default route's model was not used"
  assert_line "branch=fm/$id" "$meta" "the registered branch prefix was not used"
  brief=$(brief_of "$case_dir" "$id")
  assert_line "Title of $id" "$brief" "the brief's intent lacks the item's title"
  assert_line "$TEMPLATE_NOTE" "$brief" "the brief's intent lacks the item's note"
  assert_grep "with no Firstmate review" "$brief" "the brief lacks the queue-start spec"
  assert_grep "starts from and targets the project's default branch" "$brief" \
    "the brief does not name the base a queue start cannot read"
  assert_no_grep '{TASK}' "$brief" "the brief kept the {TASK} placeholder"
  assert_no_grep '{FIRSTMATE_SPEC}' "$brief" "the brief kept the {FIRSTMATE_SPEC} placeholder"
  assert_equals 1 "$(windows_for "$case_dir" "$id")" "a queue start did not open exactly one window"
  pass "a template ship starts with the note's mode, yolo and default route, its brief filled from that note"
}

test_queue_start_passes_its_base_branch() {
  local case_dir id out rc=0 brief
  id=qs-base-a2
  case_dir=$(make_home base)
  git -C "$case_dir/project" push --quiet origin HEAD:refs/heads/integration
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"

  out=$(queue_start "$case_dir" "$id" --base-branch integration) || rc=$?
  expect_code 0 "$rc" "a queue start with --base-branch did not start: $out"
  brief=$(brief_of "$case_dir" "$id")
  assert_line 'Base branch: integration' "$brief" "the scaffold does not record the base branch"
  assert_grep "starts from and targets integration." "$brief" "the spec does not name the base branch"
  assert_line 'base_branch=integration' "$(home_of "$case_dir")/state/$id.meta" \
    "the task record does not carry the base branch"
  pass "a queue start carries --base-branch into the scaffold, the spec and the task record"
}

test_queue_start_reads_recorded_labels_and_a_typographic_apostrophe() {
  local case_dir id out rc=0 apostrophe
  id=qs-labels-a5
  case_dir=$(make_home labels)
  apostrophe=$(printf '\342\200\231')
  add_item "$case_dir" "$id" "pm-demo inbox 1792550000-AbCd12; done on the bead. no-mistakes, yolo off; merge on the PM${apostrophe}s word. Default route (labels review-page, comms)."

  out=$(queue_start "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "a template note with recorded labels and a typographic apostrophe did not start: $out"
  assert_line 'harness=claude' "$(home_of "$case_dir")/state/$id.meta" \
    "labels that match no label route did not take the default route"
  pass "a queue start reads recorded labels that keep the default route, and a typographic apostrophe"
}

test_queue_start_starts_a_clear_label_route_from_its_recorded_labels() {
  local case_dir id out rc=0 meta
  id=qs-label-route-ep-opus
  case_dir=$(make_home label-route)
  add_item "$case_dir" "$id" "pm-demo inbox 1792550000-AbCd12; done on the bead. no-mistakes, yolo off; merge on the PM's word. Default route (labels ep-opus)."

  out=$(queue_start "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "a clear ep-opus label route recorded in the note did not start: $out"
  [ "$(show_field "$case_dir" "$id" state)" = in_flight ] \
    || fail "a label-routed queue item is not In flight: $(show_field "$case_dir" "$id" state)"
  meta="$(home_of "$case_dir")/state/$id.meta"
  assert_line 'harness=claude' "$meta" "the ep-opus label route's harness was not used"
  assert_line 'model=claude-opus-5-5[1m]' "$meta" "the ep-opus label route's model was not used"
  assert_line 'effort=xhigh' "$meta" "the ep-opus label route's effort was not used"
  assert_equals 1 "$(windows_for "$case_dir" "$id")" "a label-routed queue start did not open exactly one window"
  pass "a queue start starts a clear label route resolved from the labels its note records"
}

test_queue_start_leaves_a_non_clear_label_route_to_the_captain() {
  local case_dir id out rc=0
  id=qs-label-route-conflict
  case_dir=$(make_home label-route-conflict)
  add_item "$case_dir" "$id" "pm-demo inbox 1792550000-AbCd12; done on the bead. no-mistakes, yolo off; merge on the PM's word. Default route (labels docs-only, ep-opus)."

  out=$(queue_start "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a queue start started a non-clear label route: $out"
  assert_contains "$out" "queue start refused" "a non-clear label-route refusal did not say so: $out"
  [ "$(show_field "$case_dir" "$id" state)" = queued ] || fail "a refused label-routed item moved"
  assert_absent "$(brief_of "$case_dir" "$id")" "a refused label-routed queue start left a brief"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" "a refused label-routed queue start left a record"
  assert_equals 0 "$(windows_for "$case_dir" "$id")" "a refused label-routed queue start opened a window"
  pass "a queue start leaves a non-clear label route to the captain"
}

test_queue_start_leaves_every_other_note_to_the_captain() {
  local case_dir id note out rc
  case_dir=$(make_home refusals)
  for note in \
    "$TEMPLATE_NOTE Also skip the PR." \
    "pm-demo inbox 1792550000-AbCd12; done on the bead. direct-PR, yolo off; merge on the PM's word. Default route."; do
    id="qs-refuse-$RANDOM"
    add_item "$case_dir" "$id" "$note"
    rc=0
    out=$(queue_start "$case_dir" "$id") || rc=$?
    [ "$rc" -ne 0 ] || fail "a queue start started a note it must leave to the captain: $note"
    assert_contains "$out" "queue start refused" "a refusal did not say so: $out"
    [ "$(show_field "$case_dir" "$id" state)" = queued ] || fail "a refused item moved: $note"
    assert_absent "$(brief_of "$case_dir" "$id")" "a refused queue start left a brief: $note"
    assert_absent "$(home_of "$case_dir")/state/$id.meta" "a refused queue start left a record: $note"
  done
  id=qs-refuse-scout
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE" scout
  rc=0
  out=$(queue_start "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a queue start started a scout"
  assert_absent "$(brief_of "$case_dir" "$id")" "a refused scout left a brief"
  id=qs-refuse-held
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  tasks-axi hold "$id" --reason "waits on the captain" --file "$(backlog_of "$case_dir")" >/dev/null
  rc=0
  out=$(queue_start "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a queue start started a held item"
  assert_absent "$(brief_of "$case_dir" "$id")" "a refused held item left a brief"
  rc=0
  out=$(queue_start "$case_dir" qs-refuse-flags --mode no-mistakes) || rc=$?
  [ "$rc" -ne 0 ] || fail "--queue-start accepted --mode"
  assert_contains "$out" "--mode cannot be passed with it" "--queue-start did not name the refused flag: $out"
  assert_equals 0 "$(grep -c . "$case_dir/windows" 2>/dev/null || printf '0')" \
    "a refused queue start opened a window"
  pass "a queue start refuses any other note, a scout, a held item and a deciding flag, leaving nothing behind"
}

test_queue_start_defers_at_capacity_without_a_brief() {
  local case_dir id out rc=0
  id=qs-capacity-a3
  case_dir=$(make_home capacity)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  printf 'project 0\n' > "$(home_of "$case_dir")/config/project-capacity"

  out=$(queue_start "$case_dir" "$id") || rc=$?
  expect_code 75 "$rc" "a queue start in a full project did not defer: $out"
  assert_absent "$(brief_of "$case_dir" "$id")" "a deferred queue start left a brief, which would read as a hand start"
  [ "$(show_field "$case_dir" "$id" state)" = queued ] || fail "a deferred queue start moved its item"
  pass "a queue start in a full project defers before it claims the brief"
}

test_queue_start_failing_before_launch_gives_the_item_back() {
  local case_dir id out rc=0 hook
  id=qs-prelaunch-a4
  case_dir=$(make_home prelaunch)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  hook="$case_dir/fail-window.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
  chmod +x "$hook"

  out=$(QS_ON_NEW_WINDOW="$hook" queue_start "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a queue start whose window could not open reported success"
  assert_absent "$(brief_of "$case_dir" "$id")" "a queue start that failed before launch kept the brief it claimed"
  [ "$(show_field "$case_dir" "$id" state)" = queued ] || fail "a queue start that failed before launch moved its item"
  assert_equals no "$(show_field "$case_dir" "$id" held)" "a queue start that never launched held its item"

  rc=0
  out=$(queue_start "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "the item a failed queue start gave back did not start on the next pass: $out"
  pass "a queue start that fails before its launch removes its own brief, so the next pass starts the item"
}

# --- the races ----------------------------------------------------------------

# Hand start first: a brief that exists before the queue start runs.
test_queue_start_leaves_an_item_whose_brief_exists() {
  local case_dir id out rc=0 before
  id=qs-hand-first-b1
  case_dir=$(make_home hand-first)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  hand_brief "$case_dir" "$id" || fail "the hand start could not write its brief"
  before=$(cksum < "$(brief_of "$case_dir" "$id")")

  out=$(queue_start "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a queue start started an item whose brief a hand start wrote"
  assert_contains "$out" "a hand start owns it" "the queue start did not say a hand start owns the item: $out"
  assert_equals "$before" "$(cksum < "$(brief_of "$case_dir" "$id")")" "the queue start changed the hand start's brief"
  [ "$(show_field "$case_dir" "$id" state)" = queued ] || fail "the queue start moved a hand start's item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" "the queue start launched a hand start's item"
  pass "a queue start leaves an item whose brief exists to the hand start that owns it"
}

# Hand start during the queue start, after its read: its brief lands before
# the queue start's claim. The queue start must lose the claim, leave that
# brief byte for byte, and let the hand start launch the item once.
test_a_hand_start_during_the_read_wins_the_claim() {
  local case_dir id out rc=0 hook before
  id=qs-hand-during-b2
  case_dir=$(make_home hand-during)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  hook="$case_dir/hand-start.sh"
  cat > "$hook" <<SH
#!/usr/bin/env bash
FM_HOME="$(home_of "$case_dir")" "$BRIEF_SCAFFOLD" "$id" project --mode no-mistakes >/dev/null 2>&1 || exit 1
printf '%s\n' "The hand start's own brief." >> "$(brief_of "$case_dir" "$id")"
SH
  chmod +x "$hook"

  out=$(QS_ON_RESOLVE="$hook" queue_start "$case_dir" "$id") || rc=$?
  assert_present "$case_dir/on-resolve.done" "the hand start never ran inside the queue start"
  [ "$rc" -ne 0 ] || fail "the queue start launched an item a hand start claimed during it"
  assert_contains "$out" "a hand start created data/$id/brief.md during this start" \
    "the queue start did not report losing the claim: $out"
  assert_grep "The hand start's own brief." "$(brief_of "$case_dir" "$id")" \
    "the queue start overwrote or removed the hand start's brief"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" "the losing queue start left a task record"
  assert_equals 0 "$(windows_for "$case_dir" "$id")" "the losing queue start opened a window"

  # The hand start, finishing its brief, launches the item exactly once.
  before=$(brief_of "$case_dir" "$id")
  python3 -I - "$before" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read().replace("{TASK}", "The captain's words.", 1).replace("{FIRSTMATE_SPEC}", "- Its spec.", 1)
open(path, "w").write(text)
PY
  rc=0
  out=$(hand_spawn "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "the hand start could not launch after the queue start lost: $out"
  assert_equals 1 "$(windows_for "$case_dir" "$id")" "the item did not end with exactly one window"
  [ "$(show_field "$case_dir" "$id" state)" = in_flight ] || fail "the hand start's item is not In flight"
  pass "a hand start whose brief lands during a queue start wins; the queue start refuses with nothing to undo"
}

# Hand start while the queue start holds its claim and spawn lock: the hand
# start's scaffold and its spawn both refuse, and the queue start launches once.
test_a_hand_start_after_the_claim_refuses() {
  local case_dir id out rc=0 hook
  id=qs-hand-after-b3
  case_dir=$(make_home hand-after)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  hook="$case_dir/hand-start.sh"
  cat > "$hook" <<SH
#!/usr/bin/env bash
FM_HOME="$(home_of "$case_dir")" "$BRIEF_SCAFFOLD" "$id" project --mode no-mistakes > "$case_dir/hand-scaffold.out" 2>&1
printf '%s\n' "\$?" > "$case_dir/hand-scaffold.rc"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" FM_SPAWN_NO_GUARD=1 \
  "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --harness claude > "$case_dir/hand-spawn.out" 2>&1
printf '%s\n' "\$?" > "$case_dir/hand-spawn.rc"
exit 0
SH
  chmod +x "$hook"

  out=$(QS_ON_NEW_WINDOW="$hook" queue_start "$case_dir" "$id") || rc=$?
  expect_code 0 "$rc" "the queue start did not launch the item it claimed: $out"
  assert_present "$case_dir/hand-scaffold.rc" "the hand start never ran inside the queue start"
  assert_not_equals 0 "$(cat "$case_dir/hand-scaffold.rc")" "the hand start's scaffold overwrote the queue start's brief"
  assert_grep 'already exists' "$case_dir/hand-scaffold.out" "the hand start's scaffold did not refuse on the existing brief"
  assert_not_equals 0 "$(cat "$case_dir/hand-spawn.rc")" "the hand start's spawn ran beside the queue start"
  assert_grep "$TEMPLATE_NOTE" "$(brief_of "$case_dir" "$id")" "the queue start's brief did not survive the hand start"
  assert_equals 1 "$(windows_for "$case_dir" "$id")" "the item did not end with exactly one window"
  [ "$(show_field "$case_dir" "$id" state)" = in_flight ] || fail "the queue start's item is not In flight"
  pass "a hand start during a queue start's claim refuses at the brief and the spawn lock; one window results"
}

# A note edited after the locked read is a mid-task change: the start uses
# the note as read, for its decision, its route and its brief alike.
test_a_note_edited_after_the_read_does_not_change_the_start() {
  local case_dir id out rc=0 hook meta brief edited
  id=qs-note-edit-c1
  case_dir=$(make_home note-edit)
  add_item "$case_dir" "$id" "$TEMPLATE_NOTE"
  edited="pm-demo inbox 1792550000-AbCd12; done on the bead. no-mistakes, yolo off; merge on the PM's word. Default route (labels docs-only). Edited after the read."
  hook="$case_dir/edit-note.sh"
  cat > "$hook" <<SH
#!/usr/bin/env bash
tasks-axi update "$id" --body "$edited" --file "$(backlog_of "$case_dir")"
SH
  chmod +x "$hook"

  out=$(QS_ON_RESOLVE="$hook" queue_start "$case_dir" "$id") || rc=$?
  assert_present "$case_dir/on-resolve.done" "the note edit never ran inside the queue start"
  assert_contains "$(tasks-axi show "$id" --full --file "$(backlog_of "$case_dir")")" "Edited after the read." \
    "the fixture did not edit the note"
  expect_code 0 "$rc" "the queue start did not start the note it read: $out"
  meta="$(home_of "$case_dir")/state/$id.meta"
  brief=$(brief_of "$case_dir" "$id")
  assert_line 'harness=claude' "$meta" "the start's route came from the edited note, not the note it read"
  assert_line "$TEMPLATE_NOTE" "$brief" "the brief lacks the note as read"
  assert_no_grep "Edited after the read." "$brief" "the brief took the note edited after the read"
  assert_no_grep "Edited after the read." "$(home_of "$case_dir")/data/$id/launch-brief.md" \
    "the launch brief took the note edited after the read"
  assert_equals 1 "$(windows_for "$case_dir" "$id")" "the item did not end with exactly one window"
  pass "a note edited after the locked read changes neither the decision, the route nor the brief"
}

test_queue_start_starts_a_template_ship_from_its_note
test_queue_start_passes_its_base_branch
test_queue_start_reads_recorded_labels_and_a_typographic_apostrophe
test_queue_start_starts_a_clear_label_route_from_its_recorded_labels
test_queue_start_leaves_a_non_clear_label_route_to_the_captain
test_queue_start_leaves_every_other_note_to_the_captain
test_queue_start_defers_at_capacity_without_a_brief
test_queue_start_failing_before_launch_gives_the_item_back
test_queue_start_leaves_an_item_whose_brief_exists
test_a_hand_start_during_the_read_wins_the_claim
test_a_hand_start_after_the_claim_refuses
test_a_note_edited_after_the_read_does_not_change_the_start
