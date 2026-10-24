#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
#
# The loop also has to notice a `treehouse get` that returns without entering a
# worktree, such as a full pool: the pane never moves, so only treehouse's own
# exit says the wait is over. The fake pane below runs the line fm-spawn sends
# it in a real shell, so a fake treehouse that prints the pool-full line and
# exits is seen exactly as a pane would show it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
# Its pane echoes every line it is sent into FM_FAKE_PANE_LOG and runs a
# `treehouse get` line in a real shell from FM_FAKE_PANE_PROJECT, appending
# what that prints there too, and capture-pane shows that log above a working
# row; its session keeps a window list in FM_FAKE_WINDOWS so a closed window is
# really gone. The fake treehouse follows FM_FAKE_TREEHOUSE: `pool-full` prints
# Treehouse's pool-full line and exits, and anything else opens a worktree
# subshell that, like the real one, holds the foreground for the worker's whole
# life, so the line that ran it never resumes.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
windows=${FM_FAKE_WINDOWS:?FM_FAKE_WINDOWS unset}
case "${1:-}" in
  display-message)
    if [ "${5:-}" = '#{pane_id}' ]; then
      [ "${FM_FAKE_TMUX_PRESENCE:-}" != unreadable ] || exit 1
      grep -qxF -- "${4#*:}" "$windows" || exit 1
      printf '%%1\n'
    else
      printf 'firstmate\n'
    fi
    ;;
  list-windows) cat "$windows" 2>/dev/null ;;
  new-window)
    while [ "$#" -gt 0 ]; do
      [ "$1" != -n ] || printf '%s\n' "$2" >>"$windows"
      shift
    done
    printf '@1\n'
    ;;
  kill-window)
    [ "${FM_FAKE_TMUX_CLOSE:-}" != noop ] || exit 0
    grep -vxF -- "${3##*:=}" "$windows" >"$windows.next"
    mv "$windows.next" "$windows"
    ;;
  capture-pane)
    cat "${FM_FAKE_PANE_LOG:?}" 2>/dev/null
    printf '%s\n' '• Working (1s • esc to interrupt)'
    ;;
  send-keys)
    printf '%s\n' "$*" >>"${FM_FAKE_PANE_LOG:?}"
    case "${4:-}" in
      *"treehouse get"*)
        (cd "${FM_FAKE_PANE_PROJECT:?}" &&
          bash -c 'export FM_FAKE_PANE_SHELL=$$; eval "$1"' fake-pane "$4") >>"$FM_FAKE_PANE_LOG" 2>&1
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '🌳 Setting up worktree...' >&2
if [ "${FM_FAKE_TREEHOUSE:-}" = pool-full ]; then
  printf '%s\n' "all 16 worktrees are in use or dirty (max_trees = 16). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
  exit 1
fi
kill -KILL "${FM_FAKE_PANE_SHELL:?}"
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
Decision owner: ep-sample

# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  # A codex spawn records folder trust under HOME (bin/fm-codex-trust.sh), so
  # HOME is a throwaway and CODEX_HOME is cleared, never the developer's store.
  mkdir -p "$HOME_DIR/user-home"
  HOME="$HOME_DIR/user-home" CODEX_HOME='' \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_PROJECT="$PROJ_DIR" FM_FAKE_PANE_LOG="$CASE_DIR/pane.log" \
    FM_FAKE_WINDOWS="$CASE_DIR/windows" FM_FAKE_TREEHOUSE="${FM_FAKE_TREEHOUSE:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

make_settle_herdr_fake() {
  cat > "$FAKEBIN_DIR/herdr" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
root = Path(os.environ["FM_FAKE_HERDR_DIR"])
state_path = root / "herdr.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {
    "workspaces": [{"workspace_id": "w1", "label": "firstmate", "focused": True, "active_tab_id": "w1:t0"}],
    "tabs": [{"workspace_id": "w1", "tab_id": "w1:t0", "label": "captain", "focused": True}],
    "panes": [{"workspace_id": "w1", "tab_id": "w1:t0", "pane_id": "w1:p0"}],
}
action = tuple(args[:2])
close_mode = os.environ.get("FM_FAKE_HERDR_CLOSE", "closed")
viewport_rows = int(os.environ.get("FM_FAKE_HERDR_VIEWPORT_ROWS") or 0)
returned = (root / "treehouse-returned").exists()
client_on_task = returned and os.environ.get("FM_FAKE_HERDR_FOREGROUND") == "task-tab"

def emit(result):
    print(json.dumps({"result": result}))

def option(name):
    return args[args.index(name) + 1]

def remove_pane(pane_id):
    tabs = {p["tab_id"] for p in state["panes"] if p["pane_id"] == pane_id}
    state["panes"] = [p for p in state["panes"] if p["pane_id"] != pane_id]
    state["tabs"] = [t for t in state["tabs"] if t["tab_id"] not in tabs]
    spaces = {t["workspace_id"] for t in state["tabs"]}
    state["workspaces"] = [w for w in state["workspaces"] if w["workspace_id"] in spaces]

if action == ("status", "--json"):
    print(json.dumps({"client": {"version": "0.8.0", "protocol": 19}, "server": {"running": True, "version": "0.8.0", "protocol": 19}}))
elif action == ("session", "list"):
    print(json.dumps({"sessions": [{"name": os.environ["HERDR_SESSION"], "running": True, "socket_path": str(root / "herdr.sock")}]}))
elif action == ("workspace", "list"):
    spaces = state["workspaces"]
    if returned and os.environ.get("FM_FAKE_HERDR_FOCUS_UNREADABLE") == "1":
        spaces = [dict(w, focused=False) for w in spaces]
    elif client_on_task:
        spaces = [dict(w, focused=w["workspace_id"] == "w2", active_tab_id="w2:t1" if w["workspace_id"] == "w2" else w["active_tab_id"]) for w in spaces]
    emit({"type": "workspace_list", "workspaces": spaces})
elif action == ("workspace", "create"):
    workspace = {"workspace_id": "w2", "label": option("--label"), "focused": False, "active_tab_id": "w2:t0"}
    tab = {"workspace_id": "w2", "tab_id": "w2:t0", "label": "1", "focused": True}
    pane = {"workspace_id": "w2", "tab_id": "w2:t0", "pane_id": "w2:p0"}
    state["workspaces"].append(workspace)
    state["tabs"].append(tab)
    state["panes"].append(pane)
    emit({"workspace": workspace, "tab": tab, "root_pane": pane})
elif action == ("tab", "create"):
    workspace = option("--workspace")
    tab = {"workspace_id": workspace, "tab_id": workspace + ":t1", "label": option("--label"), "focused": False}
    pane = {"workspace_id": workspace, "tab_id": tab["tab_id"], "pane_id": workspace + ":p1", "foreground_cwd": os.environ["FM_FAKE_PANE_PROJECT"]}
    state["tabs"].append(tab)
    state["panes"].append(pane)
    emit({"tab": tab, "root_pane": pane})
elif action in (("tab", "list"), ("pane", "list")):
    kind = "tabs" if args[0] == "tab" else "panes"
    items = [item for item in state[kind] if item["workspace_id"] == option("--workspace")]
    if kind == "tabs" and client_on_task and option("--workspace") == "w2":
        items = [dict(t, focused=t["tab_id"] == "w2:t1") for t in items]
    emit({kind: items})
elif action in (("tab", "get"), ("pane", "get")):
    kind = args[0]
    item = next((item for item in state[kind + "s"] if item[kind + "_id"] == args[2]), None)
    if item:
        if kind == "pane" and viewport_rows and os.environ.get("FM_FAKE_HERDR_NO_SCROLL") != "1":
            item = dict(item, scroll={"offset_from_bottom": 0, "viewport_rows": viewport_rows})
        emit({kind: item})
    else:
        code = "unavailable" if close_mode == "unknown" and (root / "treehouse-returned").exists() else kind + "_not_found"
        print(json.dumps({"error": {"code": code}}))
        sys.exit(1)
elif action == ("pane", "run"):
    if "treehouse get" in args[3]:
        script = root / "treehouse-line.sh"
        script.write_text('export FM_FAKE_PANE_SHELL=$$\n' + args[3] + "\n")
        with Path(os.environ["FM_FAKE_PANE_LOG"]).open("a") as log:
            subprocess.run(["bash", str(script)], cwd=os.environ["FM_FAKE_PANE_PROJECT"], stdout=log, stderr=log, check=False)
        (root / "treehouse-returned").touch()
elif action == ("pane", "read"):
    log = Path(os.environ["FM_FAKE_PANE_LOG"])
    if "--lines" in args and option("--source") == "recent" and int(option("--lines")) < viewport_rows:
        sys.exit(0)
    print(log.read_text() if log.exists() else "", end="")
elif action == ("pane", "close"):
    if (root / "treehouse-returned").exists() and close_mode == "refused":
        print(json.dumps({"error": {"code": "close_refused"}}))
        sys.exit(1)
    if not (root / "treehouse-returned").exists() or close_mode != "noop":
        remove_pane(args[2])
elif action == ("terminal", "title"):
    emit({"reason": "cleared" if client_on_task else "no_foreground_client"})
elif args[0] in ("agent", "api") or action == ("pane", "process-info"):
    sys.exit(1)
else:
    print("unexpected fake herdr call: " + repr(args), file=sys.stderr)
    sys.exit(2)
state_path.write_text(json.dumps(state))
PY
  chmod +x "$FAKEBIN_DIR/herdr"
}

# A pool-full Herdr refusal in each layout, on a pane of the default height or,
# with `tall`, one 300 rows high, where Herdr returns an empty recent read for
# any line count below the viewport height; `tall-noscroll` is that pane on a
# Herdr whose `pane get` reports no viewport height. `flat` turns presentation off, so
# the ordinary locked close runs; `contended` keeps it on while another holder
# keeps the session's presentation lock past the bounded retry, so the spawn
# falls back flat and its cleanup may not close the pane at all. The projected
# layouts close the projection the spawn holds the lock for, through Herdr's
# focus-preserving cleanup: `projected-clear` with focus readable and no live
# client, `projected` with focus unreadable, and `projected-focused` with a live
# client on the task tab. The last two refuse, so the pane must stay and be named.
# shellcheck disable=SC2030 # This test intentionally isolates its environment in a subshell.
test_pool_full_herdr_cleanup_is_confirmed() (
  local layout=$1 close_mode=$2 pane_shape=${3:-} rec id out status lock_path focus_unreadable left
  id="settle-herdr-$layout-$close_mode${pane_shape:+-$pane_shape}"
  rec=$(make_settle_case "$id" "$id" 100000)
  read_settle_record "$rec"
  make_settle_herdr_fake
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  if [ "$layout" = flat ]; then
    printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  else
    printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  fi
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_BACKEND=herdr
  export HERDR_SESSION="$id" FM_FAKE_HERDR_DIR="$CASE_DIR" PATH="$FAKEBIN_DIR:$PATH"
  focus_unreadable=1
  case "$layout" in
  projected-focused) focus_unreadable=0; export FM_FAKE_HERDR_FOREGROUND=task-tab ;;
  projected-clear) focus_unreadable=0 ;;
  esac
  export FM_FAKE_HERDR_CLOSE="$close_mode" FM_FAKE_HERDR_FOCUS_UNREADABLE=$focus_unreadable
  case "$pane_shape" in
  tall) export FM_FAKE_HERDR_VIEWPORT_ROWS=300 ;;
  tall-noscroll) export FM_FAKE_HERDR_VIEWPORT_ROWS=300 FM_FAKE_HERDR_NO_SCROLL=1 ;;
  esac
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr || fail "could not load the Herdr adapter"
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_SESSION") || fail "could not resolve the fake session's presentation lock"
  if [ "$layout" = contended ]; then
    fm_lock_try_acquire "$lock_path" || fail "could not hold the presentation lock"
  fi

  out=$(FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
  status=$?
  case "$layout" in
  contended)
    [ -e "$lock_path" ] || fail "spawn removed another process's presentation lock"
    fm_lock_release "$lock_path" || fail "could not release the presentation lock"
    assert_contains "$out" "presentation focus lock unavailable" "the spawn did not contend with the held lock"
    ;;
  projected*)
    [ -f "$HOME_DIR/state/$id.herdr-presentation" ] || fail "the spawn did not create a projection"
    ;;
  esac
  [ "$status" -ne 0 ] || fail "Herdr spawn launched on a full pool"$'\n'"$out"
  assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" "Herdr refusal lost treehouse's reason"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "Herdr refusal published task metadata"
  case "$layout" in
  contended) left=w1:p1 ;;
  projected | projected-focused) left=w2:p1 ;;
  *) left= ;;
  esac
  if [ -n "$left" ]; then
    jq -e --arg label "fm-$id" 'any(.tabs[]; .label == $label)' "$CASE_DIR/herdr.json" >/dev/null || fail "the refusal closed a tab its cleanup refused to close"$'\n'"$out"
    assert_not_contains "$out" "was closed" "the refusal reported a close it was not allowed to make"$'\n'"$out"
    assert_contains "$out" "could not confirm closure of its endpoint; inspect window $HERDR_SESSION:$left" "the refusal did not name the exact endpoint it left"$'\n'"$out"
  elif [ "$close_mode" = closed ]; then
    jq -e --arg label "fm-$id" 'all(.tabs[]; .label != $label) and (.workspaces | length) == 1 and (.panes | length) == 1 and .panes[0].pane_id == "w1:p0"' "$CASE_DIR/herdr.json" >/dev/null || fail "Herdr refusal left its tab, pane, or workspace behind"$'\n'"$out"
    assert_contains "$out" "was closed" "the refusal did not confirm the closed endpoint"
  else
    if [ "$close_mode" != unknown ]; then
      jq -e --arg label "fm-$id" 'any(.tabs[]; .label == $label)' "$CASE_DIR/herdr.json" >/dev/null || fail "the refused close did not leave a pane to report"
    fi
    assert_not_contains "$out" "was closed" "the refusal falsely reported a confirmed close"$'\n'"$out"
    assert_contains "$out" "could not confirm closure" "the refusal did not report the unconfirmed endpoint"$'\n'"$out"
    assert_contains "$out" "inspect window $HERDR_SESSION:" "the refusal did not identify the endpoint to inspect"
  fi
  pass "a pool-full $layout${pane_shape:+ $pane_shape} Herdr refusal after a $close_mode close reports its endpoint truthfully"
)

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  assert_grep 'decision_owner=ep-sample' "$HOME_DIR/state/$id.meta" 'dispatch lost the declared decision owner'
  assert_grep 'Decision owner for this dispatch: ep-sample' "$HOME_DIR/data/$id/launch-brief.md" 'worker did not receive its decision owner'
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# A pane that settles in a worktree of a DIFFERENT clone of the project -
# the mixed Treehouse pool shape, where one pool holds slots from two clones
# of one origin - must never be adopted: its git common dir is the other
# clone's, so a Claude worker there is refused by trust and a worker that
# skips trust works in the wrong clone. The spawn fails at the deadline
# naming the mismatch, and records nothing.
make_foreign_clone_case() {
  local name=$1 id=$2 case_dir home proj wt foreign_clone foreign_wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  foreign_clone="$case_dir/foreign-clone"
  foreign_wt="$case_dir/foreign-slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git clone --quiet "$proj" "$foreign_clone"
  git -C "$foreign_clone" worktree add --quiet -b "slot-$name" "$foreign_wt"
  fm_test_spawn_brief "$home" "$id" "Exercise foreign-clone slot rejection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$foreign_wt|$foreign_wt|$fakebin|$countfile|0"
}

test_foreign_clone_slot_is_never_accepted() {
  local rec id out status
  id=settle-foreign-clone-z5
  rec=$(make_foreign_clone_case settle-foreign-clone "$id")
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree of a different clone"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "different clone" \
    "the refusal did not name the foreign-clone mismatch"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "foreign-clone spawn published task metadata"
  pass "a pane settled in a different clone's worktree is never accepted as the worktree"
}

# make_pool_case <name> <id> builds the mixed-pool shape: one Treehouse pool
# holds slot 1 as a worktree of a foreign clone of the project and slot 2 as
# a worktree of the project itself, both free in Treehouse's state. The pane
# is told whichever path the case's record carries.
make_pool_case() {
  local name=$1 id=$2 case_dir home proj wt pool foreign fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  pool="$case_dir/pool"
  foreign="$case_dir/foreign-clone"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$pool/1" "$pool/2"
  git -C "$proj" worktree add --quiet -b "ownslot-$name" "$pool/2/repo"
  git clone --quiet "$proj" "$foreign"
  git -C "$foreign" worktree add --quiet -b "foreignslot-$name" "$pool/1/repo"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}' \
    "$pool/1/repo" "$pool/2/repo" > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise mixed-pool slot steering for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$wt|$fakebin|$countfile|0"
}

# With a free slot of the project's own clone already in a mixed pool, the
# spawn enters that exact slot by name instead of taking the pool's first
# free slot from `treehouse get`, which belongs to the foreign clone.
test_mixed_pool_enters_free_own_slot() {
  local rec id out status pool own_slot pane_log
  id=settle-pool-own-slot-z6
  rec=$(make_pool_case settle-pool-own "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-own/pool"
  own_slot="$pool/2/repo"
  pane_log="$TMP_ROOT/settle-pool-own/pane.log"
  WT_DIR="$own_slot"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed in the pool's own-clone slot"$'\n'"$out"
  assert_grep "worktree=$own_slot" "$HOME_DIR/state/$id.meta" \
    "meta did not record the pool's own-clone slot"
  assert_grep 'treehouse enter' "$pane_log" \
    "spawn did not enter the free own-clone slot by name"
  assert_no_grep 'treehouse get' "$pane_log" \
    "spawn used treehouse get despite a free own-clone slot"
  pass "a mixed pool with a free own-clone slot is entered by exact slot name"
}

# When the pool's own-clone slot is already claimed by another task, the
# spawn keeps the plain `treehouse get` path and lands where the pane settles.
test_mixed_pool_claimed_own_slot_uses_treehouse_get() {
  local rec id out status pool pane_log
  id=settle-pool-claimed-z7
  rec=$(make_pool_case settle-pool-claimed "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-claimed/pool"
  pane_log="$TMP_ROOT/settle-pool-claimed/pane.log"
  printf 'task=some-other-task\nhome=%s\n' "$HOME_DIR" > "$pool/2/.fm-slot-owner"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is claimed"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was claimed"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered a slot another task has claimed"
  pass "a claimed own-clone slot is left alone and treehouse get is used instead"
}

# make_pool_grow_case <name> <id>: the pool's only own-clone slot (2) is
# claimed by another task and slot 1 is a free foreign slot. The fake
# Treehouse allocator hands out slot 1 on the first `get --lease`, then
# creates a new own-clone slot 3 on the second (a real worktree add, the
# same thing Treehouse's own create does), and logs every call.
make_pool_grow_case() {
  local name=$1 id=$2 case_dir home proj wt pool foreign fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  pool="$case_dir/pool"
  foreign="$case_dir/foreign-clone"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
case "$*" in
  *"get --lease"*)
    if [ ! -e "$FM_TREEHOUSE_GROW_MARKER" ]; then
      : > "$FM_TREEHOUSE_GROW_MARKER"
      printf '%s\n' "$FM_TREEHOUSE_FOREIGN_SLOT"
    else
      git -C "$FM_TREEHOUSE_PROJ" worktree add --quiet -b "grown-$FM_TREEHOUSE_ID" "$FM_TREEHOUSE_GROWN_SLOT" 2>/dev/null || true
      printf '%s\n' "$FM_TREEHOUSE_GROWN_SLOT"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$pool/1" "$pool/2"
  git -C "$proj" worktree add --quiet -b "ownslot-$name" "$pool/2/repo"
  git clone --quiet "$proj" "$foreign"
  git -C "$foreign" worktree add --quiet -b "foreignslot-$name" "$pool/1/repo"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}' \
    "$pool/1/repo" "$pool/2/repo" > "$pool/treehouse-state.json"
  printf 'task=some-other-task\nhome=%s\n' "$home" > "$pool/2/.fm-slot-owner"
  fm_test_spawn_brief "$home" "$id" "Exercise mixed-pool slot creation for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$wt|$fakebin|$countfile|0"
}

# With no free own-clone slot, the spawn leases the free foreign slot to
# advance Treehouse's allocator until it creates a new own-clone slot,
# enters that slot, and releases the foreign lease.
test_mixed_pool_makes_new_own_slot_when_none_free() {
  local rec id out status pool grown_slot pane_log th_log
  id=settle-pool-grow-z8
  rec=$(make_pool_grow_case settle-pool-grow "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-grow/pool"
  grown_slot="$pool/3/repo"
  pane_log="$TMP_ROOT/settle-pool-grow/pane.log"
  th_log="$TMP_ROOT/settle-pool-grow/treehouse.log"
  WT_DIR="$grown_slot"

  out=$(FM_FAKE_PANE_LOG="$pane_log" \
    FM_TREEHOUSE_LOG="$th_log" \
    FM_TREEHOUSE_GROW_MARKER="$TMP_ROOT/settle-pool-grow/.grown-marker" \
    FM_TREEHOUSE_FOREIGN_SLOT="$pool/1/repo" \
    FM_TREEHOUSE_GROWN_SLOT="$grown_slot" \
    FM_TREEHOUSE_PROJ="$PROJ_DIR" \
    FM_TREEHOUSE_ID="$id" \
    run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed in a newly made own-clone slot"$'\n'"$out"
  assert_grep "worktree=$grown_slot" "$HOME_DIR/state/$id.meta" \
    "meta did not record the newly made own-clone slot"
  assert_grep 'get --lease' "$th_log" \
    "spawn did not lease through the allocator to make an own-clone slot"
  assert_grep "return $pool/1/repo" "$th_log" \
    "spawn did not release the foreign slot it leased while steering"
  assert_grep 'treehouse enter' "$pane_log" \
    "spawn did not enter the newly made own-clone slot by name"
  pass "no free own-clone slot: the allocator is leased forward until Treehouse makes one"
}

# When the allocator hands the spawn a slot another task has claimed,
# the spawn must never hand it back: `treehouse return` terminates the
# processes inside its worktree, and the claiming task's worker may be
# starting there. The lease is left for that task's own teardown return.
test_allocator_claimed_slot_is_never_returned() {
  local rec id out status pool pane_log th_log
  id=settle-pool-claimed-lease-z9
  rec=$(make_pool_case settle-pool-claimed-lease "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-claimed-lease/pool"
  pane_log="$TMP_ROOT/settle-pool-claimed-lease/pane.log"
  th_log="$TMP_ROOT/settle-pool-claimed-lease/treehouse.log"
  printf 'task=some-other-task\nhome=%s\n' "$HOME_DIR" > "$pool/2/.fm-slot-owner"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
case "$*" in
  *"get --lease"*) printf '%s\n' "$FM_TREEHOUSE_CLAIMED_SLOT"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(FM_FAKE_PANE_LOG="$pane_log" \
    FM_TREEHOUSE_LOG="$th_log" \
    FM_TREEHOUSE_CLAIMED_SLOT="$pool/2/repo" \
    run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should still succeed through treehouse get"$'\n'"$out"
  assert_grep 'get --lease' "$th_log" \
    "spawn did not consult the allocator before falling back"
  assert_no_grep 'return ' "$th_log" \
    "spawn returned a slot another task has claimed (treehouse return kills its processes)"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get after the claimed slot"
  pass "a claimed slot handed over by the allocator is never returned"
}

# A free own-clone slot with residue is not entered: Treehouse's allocator
# would refuse to reuse it, and the spawn's base freshen would refuse to
# discard the work. The spawn keeps the plain `treehouse get` path, which
# can hand out or create a clean slot instead.
test_dirty_own_slot_is_not_entered() {
  local rec id out status pool pane_log
  id=settle-pool-dirty-z10
  rec=$(make_pool_case settle-pool-dirty "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-dirty/pool"
  pane_log="$TMP_ROOT/settle-pool-dirty/pane.log"
  printf 'residue\n' > "$pool/2/repo/untracked-residue"

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is dirty"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled clean worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was dirty"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered a dirty own-clone slot the allocator would refuse"
  pass "a dirty own-clone slot is not entered"
}

# A clean own-clone slot whose HEAD carries commits outside the reset
# target is not entered either: entering it would let the base freshen
# reset those commits away. Again the plain `treehouse get` path owns it.
test_unmerged_own_slot_is_not_entered() {
  local rec id out status pool pane_log
  id=settle-pool-unmerged-z11
  rec=$(make_pool_case settle-pool-unmerged "$id")
  read_settle_record "$rec"
  pool="$TMP_ROOT/settle-pool-unmerged/pool"
  pane_log="$TMP_ROOT/settle-pool-unmerged/pane.log"
  printf 'unmerged work\n' >> "$pool/2/repo/README.md"
  git -C "$pool/2/repo" add README.md
  git -C "$pool/2/repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'unmerged slot work'

  out=$(FM_FAKE_PANE_LOG="$pane_log" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed through treehouse get when the own slot is unmerged"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled clean worktree"
  assert_grep 'treehouse get' "$pane_log" \
    "spawn did not fall back to treehouse get when the own slot was unmerged"
  assert_no_grep 'treehouse enter' "$pane_log" \
    "spawn entered an unmerged own-clone slot the allocator would refuse"
  pass "an unmerged own-clone slot is not entered"
}

# The 10-19 incident: `treehouse get` finds the pool full, says so, and exits at
# once, so the pane never leaves the project. The spawn must refuse on the first
# read after treehouse returned, quote treehouse's own line, and close the window
# it opened, so a retry is refused for the full pool again rather than for a
# leftover window.
test_pool_full_treehouse_get_refuses_at_once() {
  local rec id out status reads
  id=settle-pool-full-z12
  rec=$(make_settle_case settle-pool-full "$id" 100000)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although treehouse get found the pool full"$'\n'"$out"
  assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" \
    "the refusal did not quote treehouse's own reason"
  assert_contains "$out" "$PROJ_DIR" "the refusal did not name the project whose pool is full"
  assert_not_contains "$out" "was closed" "a non-Herdr refusal claimed a proven close"
  assert_contains "$out" "could not confirm closure" "the refusal omitted the unconfirmed-window warning"
  assert_contains "$out" "inspect window firstmate:fm-$id" "the refusal did not name its unconfirmed window"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 1 ] || fail "spawn read the pane $reads times after treehouse get had already exited - expected to refuse on the first read"$'\n'"$out"
  assert_no_grep "fm-$id" "$CASE_DIR/windows" "the refused spawn left its window behind"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"

  out=$(FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
  assert_not_contains "$out" "already exists" "a retry was refused for the first attempt's leftover window"
  assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" \
    "a retry did not reach treehouse get again"
  pass "a treehouse get that exits on a full pool refuses at once with treehouse's reason and leaves no window"
}

# shellcheck disable=SC2031 # Independent test subshells do not share their environment or lookup state.
test_pool_full_surviving_window_is_reported() {
  local presence rec id out status lookup_status
  for presence in present unreadable; do
    id="settle-pool-full-close-$presence"
    rec=$(make_settle_case "$id" "$id" 100000)
    read_settle_record "$rec"
    STALE_DIR=$PROJ_DIR
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"

    out=$(FM_FAKE_TMUX_CLOSE=noop FM_FAKE_TMUX_PRESENCE="$presence" \
      FM_FAKE_TREEHOUSE=pool-full run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn launched after treehouse returned on a full pool"$'\n'"$out"
    grep -qxF -- "fm-$id" "$CASE_DIR/windows" || fail "the fake close did not leave its window in place"
    lookup_status=0
    (
      . "$ROOT/bin/fm-backend.sh"
      FM_FAKE_WINDOWS="$CASE_DIR/windows" FM_FAKE_TMUX_PRESENCE="$presence" \
        PATH="$FAKEBIN_DIR:$PATH" fm_backend_target_exists tmux "firstmate:fm-$id"
    ) || lookup_status=$?
    if [ "$presence" = unreadable ]; then
      expect_code 1 "$lookup_status" "the unreadable backend lookup must reproduce status 1"
    else
      expect_code 0 "$lookup_status" "the surviving window must still be queryable"
    fi
    assert_not_contains "$out" "was closed" "a pool-full spawn reported its surviving window closed"$'\n'"$out"
    assert_contains "$out" "could not confirm closure" "the refusal omitted the leftover warning"$'\n'"$out"
    assert_contains "$out" "inspect window firstmate:fm-$id" "the refusal did not name its surviving window"$'\n'"$out"
    assert_contains "$out" "all 16 worktrees are in use or dirty (max_trees = 16)" "the refusal lost treehouse's reason"$'\n'"$out"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
    pass "a pool-full spawn reports its $presence window after a silent close failure"
  done
}

# A slow but working `treehouse get` prints while it fetches and sets up the
# slot, and the pane stays on the project the whole time. Treehouse output is not
# an exit, so the spawn keeps waiting and launches once the pane reaches the
# worktree.
test_slow_treehouse_get_still_launches() {
  local rec id out status
  id=settle-slow-z13
  rec=$(make_settle_case settle-slow "$id" 40)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should launch once a slow treehouse get reaches the worktree"$'\n'"$out"
  assert_grep "Setting up worktree" "$CASE_DIR/pane.log" "the fake pane never ran treehouse get"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the slow treehouse get entered"
  grep -qxF -- "fm-$id" "$CASE_DIR/windows" || fail "the launched worker's window is missing"
  pass "a slow but working treehouse get still launches"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_foreign_clone_slot_is_never_accepted
test_mixed_pool_enters_free_own_slot
test_mixed_pool_claimed_own_slot_uses_treehouse_get
test_mixed_pool_makes_new_own_slot_when_none_free
test_allocator_claimed_slot_is_never_returned
test_dirty_own_slot_is_not_entered
test_unmerged_own_slot_is_not_entered
test_pool_full_treehouse_get_refuses_at_once
test_pool_full_surviving_window_is_reported
test_slow_treehouse_get_still_launches
test_pool_full_herdr_cleanup_is_confirmed flat closed || exit 1
test_pool_full_herdr_cleanup_is_confirmed flat refused || exit 1
test_pool_full_herdr_cleanup_is_confirmed flat noop || exit 1
test_pool_full_herdr_cleanup_is_confirmed flat unknown || exit 1
test_pool_full_herdr_cleanup_is_confirmed contended closed || exit 1
test_pool_full_herdr_cleanup_is_confirmed flat closed tall || exit 1
test_pool_full_herdr_cleanup_is_confirmed flat closed tall-noscroll || exit 1
test_pool_full_herdr_cleanup_is_confirmed projected closed || exit 1
test_pool_full_herdr_cleanup_is_confirmed projected noop || exit 1
test_pool_full_herdr_cleanup_is_confirmed projected-focused closed || exit 1
test_pool_full_herdr_cleanup_is_confirmed projected-clear closed || exit 1

echo "# all fm-spawn-worktree-settle tests passed"
