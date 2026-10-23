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
  fm_test_fake_sleep_noop "$fakebin"
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
  list-windows|has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  capture-pane)
    [ ! -e "$0.codex-launched" ] || printf '%s\n' '• Working (1s • esc to interrupt)'
    exit 0
    ;;
  send-keys)
    for arg in "$@"; do
      if [ "$arg" = "treehouse get" ]; then
        seq=$(cat "${FM_FAKE_SLOT_SEQ:?}")
        seq=$((seq + 1))
        printf '%s\n' "$seq" > "$FM_FAKE_SLOT_SEQ"
        slot=$(CDPATH='' cd -- "${FM_FAKE_SLOT_ROOT:?}/$seq/project" && pwd -P) || exit 1
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
  git -C "${FM_FAKE_PROJECT:?}" worktree remove --force "$target"
  exit $?
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

write_detector() { # <path>
  cat > "$1" <<'PY'
import os
import sys

mode = os.environ.get("FM_FAKE_DETECTOR_MODE", "clean")
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
  fm_git_add_origin "$project" "$origin"
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
  write_detector "$case_dir/detector.py"
  install_fakes "$case_dir" >/dev/null
  printf '%s\n' "$case_dir"
}

run_spawn() { # <case-dir> <id> <mode> [fm-spawn args...]
  local case_dir=$1 id=$2 mode=$3
  shift 3
  FM_LIVE_SESSION_CHECK="$case_dir/detector.py" \
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

test_clean_defer_returns_the_slot_and_the_retry_spawns() {
  local id="defer-$$-retry" case_dir out rc slot1 slot2
  case_dir=$(make_world clean-retry "$id")
  slot1=$(CDPATH='' cd -- "$case_dir/slots/1/project" && pwd -P)
  slot2=$(CDPATH='' cd -- "$case_dir/slots/2/project" && pwd -P)

  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  expect_code 75 "$rc" "a live-session deferral did not defer"$'\n'"$out"
  assert_contains "$out" "deferred:" "the live-session deferral did not say it deferred"
  assert_absent "$case_dir/home/state/$id.meta" "the deferred spawn left a task record"

  : > "$case_dir/pane-path"
  rc=0
  out=$(run_spawn "$case_dir" "$id" clean --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the retry after a clean live-session deferral did not spawn"$'\n'"$out"
  [ ! -e "$slot1/.git" ] || fail "the deferred spawn left its ship-branch checkout at $slot1"
  [ "$(git -C "$slot2" branch --show-current)" = "fm/$id" ] \
    || fail "the retry did not check out fm/$id in the next pool slot"
  pass "a clean live-session deferral returns its slot, and the retry spawns"
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
  pass "a slot holding uncommitted changes is kept and the spawn refuses"
}

test_slot_with_unpushed_commits_is_not_returned() {
  local id="defer-$$-commit" case_dir out rc slot1
  case_dir=$(make_world commits "$id")
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
  pass "a slot holding commits origin does not have is kept and the spawn refuses"
}

test_clean_defer_returns_the_slot_and_the_retry_spawns
test_dirty_slot_is_not_returned
test_slot_with_unpushed_commits_is_not_returned
