#!/usr/bin/env bash
# A fresh ship that defers after checking out its branch in a pool slot must
# not leave that checkout behind. The next spawn would otherwise die because
# git refuses a branch another worktree already has checked out.
#
# Slots are handed out by sequence, never by "first directory that exists".
# A retry that landed back in the still-checked-out slot would succeed at
# checkout and hide the bug this file exists to catch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-defer-slot)

install_fakes() { # <case-dir>
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = 0.1 ] && [ -f "${FM_FAKE_CASE_DIR:?}/return-lock.ready" ] &&
  mkdir "$FM_FAKE_CASE_DIR/return-lock.notified" 2>/dev/null; then
  printf 'waiting\n' > "$FM_FAKE_CASE_DIR/return-lock.wait"
fi
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "${FM_FAKE_PANE_FILE:-}" ]; then
      cat "$FM_FAKE_PANE_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -f "${FM_FAKE_CASE_DIR:?}/windows" ] && cat "${FM_FAKE_CASE_DIR}/windows"
    exit 0
    ;;
  new-window)
    name=
    prev=
    for arg in "$@"; do
      [ "$prev" = -n ] && name=$arg
      prev=$arg
    done
    [ -n "$name" ] || exit 1
    printf '%s\n' "$name" >> "${FM_FAKE_CASE_DIR:?}/windows"
    printf '@1\n'
    exit 0
    ;;
  kill-window)
    target=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
    done
    window=${target#*:=}
    windows="${FM_FAKE_CASE_DIR:?}/windows"
    if [ -f "$windows" ]; then
      grep -Fxv -- "$window" "$windows" > "$windows.tmp" || true
      mv "$windows.tmp" "$windows"
    fi
    exit 0
    ;;
  has-session|new-session|set-window-option) exit 0 ;;
  capture-pane)
    [ ! -e "$0.codex-launched" ] || printf '%s\n' '• Working (1s • esc to interrupt)'
    exit 0
    ;;
  send-keys)
    for arg in "$@"; do
      if [[ "$arg" == *"treehouse get"* ]]; then
        seq=$(cat "${FM_FAKE_SLOT_SEQ:?}")
        seq=$((seq + 1))
        printf '%s\n' "$seq" > "$FM_FAKE_SLOT_SEQ"
        slot=$(CDPATH='' cd -- "${FM_FAKE_SLOT_ROOT:?}/$seq/project" && pwd -P) || exit 1
        printf '%s\n' "$slot" > "${FM_FAKE_PANE_FILE:?}"
      elif [[ "$arg" == "treehouse enter "* ]]; then
        name=${arg#treehouse enter }
        name=${name//\'/}
        slot=$(CDPATH='' cd -- "${FM_FAKE_SLOT_ROOT:?}/$name/project" && pwd -P) || exit 1
        printf '%s\n' "$slot" > "${FM_FAKE_PANE_FILE:?}"
      fi
    done
    prev=
    for arg in "$@"; do
      if [ "$prev" = "-l" ]; then
        case "$arg" in
          ". '"*"'")
            staged=${arg#". '"}
            staged=${staged%"'"}
            case "$(cat "$staged" 2>/dev/null)" in
              *"codex "*--dangerously-bypass-approvals-and-sandbox*) : >"$0.codex-launched" ;;
              *) rm -f "$0.codex-launched" ;;
            esac
            ;;
        esac
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
if [ "${1:-} ${2:-}" = "get --lease" ] && [ -n "${FM_FAKE_LEASE_SLOT:-}" ]; then
  holder=
  while [ "$#" -gt 1 ]; do
    [ "$1" != --lease-holder ] || holder=$2
    shift
  done
  slot=$(CDPATH='' cd -- "$FM_FAKE_LEASE_SLOT" && pwd -P) || exit 1
  jq -n --arg p "$slot" --arg n "$(basename "$(dirname "$slot")")" --arg h "$holder" \
    '{worktrees: [{name: $n, path: $p, leased: true, lease_holder: $h}]}' \
    > "$(dirname "$(dirname "$slot")")/treehouse-state.json"
  printf '%s\n' "$slot"
  exit 0
fi
if [ "${1:-}" = return ]; then
  shift
  target=
  for arg in "$@"; do
    case "$arg" in
      --force) ;;
      *) target=$arg ;;
    esac
  done
  [ -n "$target" ] || exit 2
  . "${FM_FAKE_CODE_ROOT:?}/bin/fm-wake-lib.sh"
  for lock in "$STATE/.spawn-${FM_FAKE_TASK_ID:?}.lock" "$STATE/.meta-$FM_FAKE_TASK_ID.lock"; do
    if fm_lock_try_acquire "$lock"; then
      fm_lock_release "$lock"
      printf 'return found an unlocked task: %s\n' "$lock" >&2
      exit 2
    fi
  done
  [ "${FM_FAKE_DETECTOR_MODE:-}" != stays ] || exit 0
  git -C "$target" checkout --quiet --ignore-other-worktrees main
  exit $?
fi
exit 0
SH
  cat > "$case_dir/hold-project-lock.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "${FM_FAKE_CODE_ROOT:?}/bin/fm-wake-lib.sh"
project_lock=$(fm_treehouse_project_lock_path "${FM_FAKE_PROJECT:?}")
fm_lock_try_acquire "$project_lock"
trap 'fm_lock_release "$project_lock"' EXIT
: > "${FM_FAKE_CASE_DIR:?}/return-lock.ready"
IFS= read -r -t 30 signal <> "$FM_FAKE_CASE_DIR/return-lock.wait"
for kind in spawn meta; do
  task_lock="$STATE/.$kind-${FM_FAKE_TASK_ID:?}.lock"
  if fm_lock_try_acquire "$task_lock"; then
    fm_lock_release "$task_lock"
    printf 'unlocked %s\n' "$kind"
    exit 1
  fi
  printf 'held %s\n' "$kind"
done
slot=$(cat "${FM_FAKE_PANE_FILE:?}")
case "$1" in
  meta) printf 'worktree=%s\nreplacement=yes\n' "$slot" > "$STATE/$FM_FAKE_TASK_ID.meta" ;;
  branch) git -C "$slot" checkout --quiet -b replacement ;;
  dirty) printf 'keep\n' > "$slot/keep-me.txt" ;;
  commits)
    printf 'keep\n' > "$slot/extra.txt"
    git -C "$slot" add extra.txt
    git -C "$slot" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm extra
    ;;
  owner) printf 'task=replacement\nhome=%s\n' "$FM_HOME" > "${slot%/*}/.fm-slot-owner" ;;
  *) exit 2 ;;
esac
: > "$FM_FAKE_CASE_DIR/return-lock.changed"
SH
  chmod +x "$fakebin/sleep" "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

write_detector() { # <path>
  cat > "$1" <<'PY'
import os
import subprocess
import sys
import time

mode = os.environ.get("FM_FAKE_DETECTOR_MODE", "clean")
if mode.startswith("lock-"):
    case_dir = os.environ["FM_FAKE_CASE_DIR"]
    with open(os.path.join(case_dir, "return-lock.log"), "w") as log:
        holder = subprocess.Popen(
            ["bash", os.path.join(case_dir, "hold-project-lock.sh"), mode[5:]],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    for _ in range(200):
        if os.path.exists(os.path.join(case_dir, "return-lock.ready")):
            break
        if holder.poll() is not None:
            sys.exit(2)
        time.sleep(0.1)
    else:
        sys.exit(2)
    print("live signal=person source=desktop")
    sys.exit(75)
if mode == "dirty":
    pane = open(os.environ["FM_FAKE_PANE_FILE"]).read().strip()
    with open(os.path.join(pane, "keep-me.txt"), "w") as handle:
        handle.write("keep\n")
    print("live signal=person source=desktop")
    sys.exit(75)
if mode == "commits":
    print("live signal=person source=desktop")
    sys.exit(75)
count_path = os.environ["FM_FAKE_DETECTOR_COUNT"]
seen = 0
if os.path.exists(count_path):
    text = open(count_path).read().strip()
    seen = int(text or "0")
seen += 1
with open(count_path, "w") as handle:
    handle.write(str(seen) + "\n")
if seen == 1:
    print("live signal=person source=desktop")
    sys.exit(75)
sys.exit(0)
PY
}

make_world() { # <name> <id>
  local name=$1 id=$2 case_dir home project origin slot_root n
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  slot_root="$case_dir/slots"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a deferred spawn for $id.

## Firstmate spec
Exercise the spawn behavior under test.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/$id
EOF
  fm_git_init_commit "$project"
  if [ "${3:-origin}" != originless ]; then
    fm_git_add_origin "$project" "$origin"
  fi
  mkdir -p "$slot_root"
  printf '{}\n' > "$slot_root/treehouse-state.json"
  for n in 1 2; do
    mkdir -p "$slot_root/$n"
    git -C "$project" worktree add --quiet --detach "$slot_root/$n/project" HEAD
  done
  printf '0\n' > "$case_dir/slot-seq"
  : > "$case_dir/pane-path"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/detector-count"
  : > "$case_dir/windows"
  mkfifo "$case_dir/return-lock.wait"
  write_detector "$case_dir/detector.py"
  install_fakes "$case_dir" >/dev/null
  printf '%s\n' "$case_dir"
}

run_spawn() { # <case-dir> <id> <mode> [fm-spawn args...]
  local case_dir=$1 id=$2 mode=$3
  shift 3
  FM_LIVE_SESSION_CHECK="$case_dir/detector.py" \
    FM_FAKE_CASE_DIR="$case_dir" \
    FM_FAKE_CODE_ROOT="$ROOT" \
    FM_FAKE_TASK_ID="$id" \
    FM_FAKE_DETECTOR_MODE="$mode" \
    FM_FAKE_DETECTOR_COUNT="$case_dir/detector-count" \
    FM_FAKE_PANE_FILE="$case_dir/pane-path" \
    FM_FAKE_SLOT_SEQ="$case_dir/slot-seq" \
    FM_FAKE_SLOT_ROOT="$case_dir/slots" \
    FM_FAKE_PROJECT="$case_dir/project" \
    FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    fm_test_run_spawn "$case_dir/home" "$case_dir/project" "$case_dir/fakebin" \
      "$id" "$case_dir/project" "$@"
}

assert_refusal_retry_is_not_blocked_by_the_old_window() { # <case-dir> <id>
  local case_dir=$1 id=$2 out rc
  : > "$case_dir/pane-path"
  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  assert_not_contains "$out" "error: window " \
    "the retry after a cleanup refusal was blocked by the leftover window"
  expect_code 1 "$rc" "the retry after a cleanup refusal launched beside the kept slot"$'\n'"$out"
  assert_contains "$out" "already used by worktree" \
    "the retry did not report that the kept slot still holds the ship branch"
}

test_clean_defer_returns_the_slot_and_the_retry_spawns() {
  local origin=${1:-origin} id="defer-$$-retry-${1:-origin}" case_dir out rc slot1 slot2
  case_dir=$(make_world "clean-retry-$origin" "$id" "$origin")
  slot1=$(CDPATH='' cd -- "$case_dir/slots/1/project" && pwd -P)
  slot2=$(CDPATH='' cd -- "$case_dir/slots/2/project" && pwd -P)

  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  expect_code 75 "$rc" "a live-session deferral did not defer"$'\n'"$out"
  assert_contains "$out" "deferred:" "the live-session deferral did not say it deferred"
  assert_absent "$case_dir/home/state/$id.meta" "the deferred spawn left a task record"
  [ -d "$slot1" ] || fail "the deferred spawn removed its returned pool slot"
  [ "$(git -C "$slot1" branch --show-current)" = main ] \
    || fail "the deferred spawn did not park its returned pool slot on main"
  assert_absent "$case_dir/slots/1/.fm-slot-owner" "the returned slot kept its owner claim"

  : > "$case_dir/pane-path"
  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the retry after a clean live-session deferral did not spawn"$'\n'"$out"
  [ -d "$slot1" ] && [ "$(git -C "$slot1" branch --show-current)" != "fm/$id" ] \
    || fail "the returned slot did not remain parked after the retry"
  [ "$(git -C "$slot2" branch --show-current)" = "fm/$id" ] \
    || fail "the retry did not check out fm/$id in the next pool slot"
  pass "a clean live-session deferral returns its slot in place, and the retry spawns ($origin)"
}

test_return_that_keeps_the_ship_branch_is_refused() {
  local id="defer-$$-stays" case_dir out rc slot1
  case_dir=$(make_world stays "$id")
  slot1="$case_dir/slots/1/project"

  rc=0
  out=$(run_spawn "$case_dir" "$id" stays --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "a return that kept the ship branch was accepted"$'\n'"$out"
  assert_contains "$out" "its ship branch was still checked out after treehouse return" \
    "the refusal did not name the unchanged ship branch"
  assert_grep 'treehouse return' "$case_dir/treehouse.log" "the return was not attempted"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the fake return did not preserve the ship branch"
  assert_grep "task=$id" "$case_dir/slots/1/.fm-slot-owner" "the refused return lost its claim"
  pass "a return that keeps the ship branch is refused with its claim intact"
}

test_slot_is_rechecked_after_retaking_the_project_lock() {
  local change id case_dir out rc slot1 expected
  for change in meta branch dirty commits owner; do
    id="defer-$$-lock-$change"
    case_dir=$(make_world "lock-$change" "$id")
    slot1="$case_dir/slots/1/project"
    rc=0
    out=$(run_spawn "$case_dir" "$id" "lock-$change" --mode no-mistakes --yolo off) || rc=$?
    expect_code 1 "$rc" "a slot changed while cleanup waited was returned ($change)"$'\n'"$out"
    assert_grep 'held spawn' "$case_dir/return-lock.log" "cleanup released its task lock while waiting"
    assert_grep 'held meta' "$case_dir/return-lock.log" "cleanup released its metadata lock while waiting"
    [ -f "$case_dir/return-lock.changed" ] || fail "the concurrent change did not happen ($change)"
    if grep -F 'treehouse return' "$case_dir/treehouse.log" >/dev/null; then
      fail "cleanup returned a changed slot ($change)"
    fi
    case "$change" in
      meta)
        expected="its task record is still present"
        assert_grep 'replacement=yes' "$case_dir/home/state/$id.meta" "cleanup removed the replacement record"
        ;;
      branch)
        expected="its ship branch is no longer checked out"
        [ "$(git -C "$slot1" branch --show-current)" = replacement ] \
          || fail "cleanup changed the replacement branch"
        ;;
      dirty)
        expected="it holds uncommitted changes"
        assert_grep 'keep' "$slot1/keep-me.txt" "cleanup lost the uncommitted file"
        ;;
      commits)
        expected="it holds commits origin does not have"
        assert_grep 'keep' "$slot1/extra.txt" "cleanup lost the task commit"
        [ "$(git -C "$slot1" log -1 --format=%s)" = extra ] || fail "cleanup reset the task commit"
        ;;
      owner)
        expected="its claim reads other"
        assert_grep 'task=replacement' "$case_dir/slots/1/.fm-slot-owner" "cleanup removed the replacement claim"
        ;;
    esac
    assert_contains "$out" "$expected" "cleanup did not explain its refusal ($change)"
    if [ "$change" != owner ]; then
      assert_grep "task=$id" "$case_dir/slots/1/.fm-slot-owner" "cleanup removed the refused slot's claim"
    fi
    pass "cleanup keeps task ownership and rechecks $change under the project lock"
  done
}

test_dirty_slot_is_not_returned() {
  local id="defer-$$-dirty" case_dir out rc slot1
  case_dir=$(make_world dirty "$id")
  slot1=$(CDPATH='' cd -- "$case_dir/slots/1/project" && pwd -P)

  rc=0
  out=$(run_spawn "$case_dir" "$id" dirty --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "a slot holding uncommitted changes was not refused"$'\n'"$out"
  assert_contains "$out" "was not returned because it holds uncommitted changes" \
    "the refusal did not say the dirty slot was kept"
  assert_not_contains "$out" "deferred:" "a dirty slot was deferred instead of refused"
  if grep -F 'treehouse return' "$case_dir/treehouse.log" >/dev/null; then
    fail "a slot holding uncommitted changes was returned"
  fi
  assert_grep 'keep' "$slot1/keep-me.txt" "the uncommitted file did not survive"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the refused spawn detached the ship branch"
  grep -Fxq -- "task=$id" "$case_dir/slots/1/.fm-slot-owner" \
    || fail "the refused spawn dropped the claim on the slot it kept"
  assert_refusal_retry_is_not_blocked_by_the_old_window "$case_dir" "$id"
  assert_grep 'keep' "$slot1/keep-me.txt" "the retry disturbed the uncommitted file"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the retry detached the ship branch the refusal kept"
  grep -Fxq -- "task=$id" "$case_dir/slots/1/.fm-slot-owner" \
    || fail "the retry dropped the claim on the slot the refusal kept"
  pass "a slot holding uncommitted changes is kept and the spawn refuses"
}

test_slot_with_unpushed_commits_is_not_returned() {
  local origin=${1:-origin} id="defer-$$-commit-${1:-origin}" case_dir out rc slot1
  case_dir=$(make_world "commits-$origin" "$id" "$origin")
  slot1="$case_dir/slots/1/project"
  git -C "$slot1" checkout --quiet -b "fm/$id"
  printf 'keep\n' > "$slot1/extra.txt"
  git -C "$slot1" add extra.txt
  git -C "$slot1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm extra
  git -C "$slot1" checkout --quiet --detach main
  slot1=$(CDPATH='' cd -- "$slot1" && pwd -P)

  rc=0
  out=$(run_spawn "$case_dir" "$id" commits --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "a slot holding unpushed commits was not refused"$'\n'"$out"
  assert_contains "$out" "was not returned because it holds commits origin does not have" \
    "the refusal did not say the unpushed commits were kept"
  assert_not_contains "$out" "deferred:" "a slot with unpushed commits was deferred instead of refused"
  if grep -F 'treehouse return' "$case_dir/treehouse.log" >/dev/null; then
    fail "a slot holding unpushed commits was returned"
  fi
  assert_grep 'keep' "$slot1/extra.txt" "the unpushed commit did not survive"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the refused spawn detached the ship branch that holds the commit"
  grep -Fxq -- "task=$id" "$case_dir/slots/1/.fm-slot-owner" \
    || fail "the refused spawn dropped the claim on the slot it kept"
  assert_refusal_retry_is_not_blocked_by_the_old_window "$case_dir" "$id"
  assert_grep 'keep' "$slot1/extra.txt" "the retry disturbed the unpushed commit"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the retry detached the ship branch that holds the commit"
  grep -Fxq -- "task=$id" "$case_dir/slots/1/.fm-slot-owner" \
    || fail "the retry dropped the claim on the slot the refusal kept"
  pass "a slot holding task commits is kept and the spawn refuses ($origin)"
}

# The same refusal on a slot the spawn adopted through the allocator: steering's
# `get --lease` hands out a clean slot another task still claims, it passes the
# reuse test, so it becomes the spawn's target lease and its claim is rewritten
# to this task. Its ship branch then holds commits origin lacks and the
# live-session gate refuses: the abort trap's target-lease return must leave
# that claimed slot alone, as the plain path does.
test_adopted_slot_with_unpushed_commits_is_not_returned() {
  local id="defer-$$-adopted" case_dir out rc slot1
  case_dir=$(make_world adopted "$id")
  slot1="$case_dir/slots/1/project"
  git -C "$slot1" checkout --quiet -b "fm/$id"
  printf 'keep\n' > "$slot1/extra.txt"
  git -C "$slot1" add extra.txt
  git -C "$slot1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm extra
  git -C "$slot1" checkout --quiet --detach main
  slot1=$(CDPATH='' cd -- "$slot1" && pwd -P)
  printf 'task=some-other-task\nhome=%s\n' "$case_dir/home" > "$case_dir/slots/1/.fm-slot-owner"

  rc=0
  out=$(FM_FAKE_LEASE_SLOT="$slot1" run_spawn "$case_dir" "$id" commits --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "an adopted slot holding unpushed commits was not refused"$'\n'"$out"
  assert_grep "get --lease --lease-holder fm-spawn-$id" "$case_dir/treehouse.log" \
    "the spawn did not lease its slot through the allocator"
  [ "$(cat "$case_dir/slot-seq")" = 0 ] || fail "the spawn fell back to the plain treehouse get"
  assert_contains "$out" "was not returned because it holds commits origin does not have" \
    "the refusal did not say the unpushed commits were kept"
  if grep -F 'treehouse return' "$case_dir/treehouse.log" >/dev/null; then
    fail "the abort returned the adopted slot it said it kept"
  fi
  assert_grep 'keep' "$slot1/extra.txt" "the unpushed commit did not survive"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the refused spawn detached the ship branch on its adopted slot"
  grep -Fxq -- "task=$id" "$case_dir/slots/1/.fm-slot-owner" \
    || fail "the refused spawn dropped the claim on the adopted slot it kept"
  pass "an adopted target slot holding task commits keeps its ship branch and claim on refusal"
}

test_originless_slot_without_other_local_branches_is_refused() {
  local id="defer-$$-no-peer" case_dir out rc slot1
  case_dir=$(make_world no-peer "$id" originless)
  slot1="$case_dir/slots/1/project"
  git -C "$case_dir/project" checkout --quiet --detach HEAD
  git -C "$case_dir/project" branch -m main "fm/$id"

  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "a slot without any comparison branch was returned"$'\n'"$out"
  assert_contains "$out" "its commits could not be compared with origin" \
    "the refusal did not name the missing comparison"
  if grep -F 'treehouse return' "$case_dir/treehouse.log" >/dev/null; then
    fail "an originless slot without another local branch was returned"
  fi
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "cleanup changed the incomparable ship branch"
  assert_grep "task=$id" "$case_dir/slots/1/.fm-slot-owner" "cleanup removed the incomparable slot's claim"
  assert_refusal_retry_is_not_blocked_by_the_old_window "$case_dir" "$id"
  [ "$(git -C "$slot1" branch --show-current)" = "fm/$id" ] \
    || fail "the retry changed the incomparable ship branch"
  assert_grep "task=$id" "$case_dir/slots/1/.fm-slot-owner" "the retry removed the incomparable slot's claim"
  pass "an originless slot without another local branch is refused"
}

test_clean_defer_returns_the_slot_and_the_retry_spawns
test_clean_defer_returns_the_slot_and_the_retry_spawns originless
test_return_that_keeps_the_ship_branch_is_refused
test_slot_is_rechecked_after_retaking_the_project_lock
test_dirty_slot_is_not_returned
test_slot_with_unpushed_commits_is_not_returned
test_slot_with_unpushed_commits_is_not_returned originless
test_adopted_slot_with_unpushed_commits_is_not_returned
test_originless_slot_without_other_local_branches_is_refused
