#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote,
# unless meta records a still-open or unreadable pull request or merge request,
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
# An open or unreadable recorded request also refuses when that copy is already
# gone or another task owns the slot. Merged and closed requests still proceed,
# and --force still discards.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#   (q6) recorded pr= still open, branch already on origin     -> REFUSE (record stays)
#   (q7) recorded pr= merged, branch already on origin         -> ALLOW
#   (q8) recorded pr= closed, branch already on origin         -> ALLOW
#   (q9) recorded pr= forge unreadable, branch already on origin -> REFUSE
#   (q10) recorded pr= still open + --force                    -> ALLOW
#   (q11) recorded GitLab MR still open, branch on origin      -> REFUSE
#   (q12) recorded Forgejo PR still open, branch on origin     -> REFUSE
#   (q13) recorded pr= still open, recorded copy already gone   -> REFUSE
#   (q14) recorded pr= merged or closed, recorded copy gone     -> ALLOW
#   (q15) recorded pr= unreadable, recorded copy gone           -> REFUSE
#   (q16) recorded pr= still open, copy gone, --force           -> ALLOW
#   (q17) recorded pr= still open, slot reassigned              -> REFUSE, slot stays
#   (q18) recorded pr= still open, slot reassigned, --force     -> ALLOW, slot stays
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#
# Nested repositories survive Treehouse's own `git clean -fd`:
#   (z1) scout + nested clone + scratch file                 -> no untracked entries
#   (z2) ship + nested clone, no --force                     -> REFUSE, bytes unchanged
#   (z3) return leaves residue                               -> lost-slot warning, cleanup, exit 4
#   (z3b) residue, then a later step refuses                 -> lost-slot warning still printed
#   (z3c) forced secondmate + child scout nested clone       -> child copy returns clean
#   (z3d) forced secondmate + child return leaves residue    -> warning, retirement completes, exit 4
#   (z3e) return removes the copy                            -> cannot-verify warning, exit 4
#   (z4) scout + ignored file                                -> ignored file survives
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # The bare `axi` overview answers FM_FAKE_AXI_OVERVIEW verbatim (empty by
  # default, so no repository resolves and the pipeline-spend record is
  # written as unavailable).
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '')
        printf '%s\n' "${FM_FAKE_AXI_OVERVIEW:-}" ;;
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/fm-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

add_gh_axi_pr_state() {
  local case_dir=$1 state=$2
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh-axi.log"
case "\${1:-} \${2:-}" in
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: $state"
    exit 0
    ;;
esac
echo "error: unexpected gh-axi \$*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  jq -e --arg id task-x1 '
    .schema == "fm-secondmate-home-summary.v1"
    and all(.endpoints[]; .id != $id)
  ' "$case_dir/state/home-summary.json" >/dev/null \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_gh_axi_pr_state "$case_dir" merged
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note() {
  local case_dir out real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  case_dir=$(make_case tasks-axi-close-gerrit)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gerrit_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed Gerrit task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed Gerrit task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"Gerrit change $gerrit_url\"" >/dev/null \
    || fail "closed Gerrit backlog item did not record its change URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed Gerrit close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_gh_axi_pr_state "$case_dir" merged
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gerrit/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed Gerrit task with its change URL as a note and a GitHub task with --pr"
}

test_teardown_closes_a_gitlab_task_with_its_merge_request_url_as_a_note() {
  local case_dir out real_tasks_axi
  local gitlab_url=https://gitlab.example.com/group/sub/project/-/merge_requests/269
  case_dir=$(make_case tasks-axi-close-gitlab)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gitlab_url" >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "mr view" ] || exit 1
printf '%s\n' '{"state":"merged"}'
SH
  chmod +x "$case_dir/fakebin/glab"
  seed_backlog_in_flight "$case_dir"
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitLab task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed GitLab task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"GitLab merge request $gitlab_url\"" >/dev/null \
    || fail "closed GitLab backlog item did not record its merge request URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed GitLab close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-gitlab-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_gh_axi_pr_state "$case_dir" merged
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gitlab/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed GitLab task with its merge request URL as a note and a GitHub task with --pr"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_gh_axi_pr_state "$case_dir" merged
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

# Override tea to answer one login for git.example.org and a pull request
# read through "tea api" with the supplied merged flag and head.
add_tea_pull_for_head() {
  local case_dir=$1 merged=$2 head=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tea.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"closed","merged":%s,"head":{"sha":"%s"}}\n' '$merged' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
}

# A Forgejo task whose default branch moved on after the squash merge, editing
# the same lines, leaves the content check inconclusive, so only the forge's
# merged record can prove the work landed. With the record merged teardown
# proceeds; with it unmerged the same history refuses.
test_squash_merged_forgejo_pr_allows_when_main_moved_on() {
  local case_dir rc pr_head tmp merged expected
  for merged in true false; do
    case_dir=$(make_case "forgejo-merged-$merged")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
    tmp="$case_dir/_main_later"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' base main-edit feature-edit-reworded > "$tmp/shared.txt"
    git -C "$tmp" add -- shared.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main rewords shared"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    printf '%s\n' \
      'pr=https://git.example.org/team/repo/pulls/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_tea_pull_for_head "$case_dir" "$merged" "$pr_head"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$merged" = false ] || expected=0
    expect_code "$expected" "$rc" "forgejo-merged-$merged: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/7' "$case_dir/tea.log" \
      || fail "forgejo-merged-$merged: teardown did not read the Forgejo pull request through tea"
  done
  pass "teardown proves a Forgejo task landed from the merged pull request when the content check is inconclusive"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

assert_dirty_diagnostic() {
  local kind=$1 mode=$2 case_dir rc before n
  case_dir=$(make_case "dirty-$kind-$mode")
  write_meta "$case_dir" "$mode" ship
  wt_commit_file "$case_dir" feature.txt hello
  # Exercise both dirty refusal sites: remote-reachable work and local-only
  # work merged into local main but absent from every remote.
  if [ "$mode" = local-only ]; then
    git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  else
    git -C "$case_dir/wt" push -q origin fm/task-x1
  fi
  if [ "$kind" != untracked ]; then
    printf '%s\n' 'uncommitted edit' > "$case_dir/wt/feature.txt"
    # Cover index edits as well as unstaged edits.
    [ "$mode" != local-only ] || git -C "$case_dir/wt" add feature.txt
  fi
  if [ "$kind" != tracked ]; then
    mkdir "$case_dir/wt/00 proof scratch"
    printf '%s\n' 'manual server log' > "$case_dir/wt/00 proof scratch/server.log"
    for n in 01 02 03 04 05 06 07 08 09 10 11; do
      touch "$case_dir/wt/$n-scratch.txt"
    done
    # Preserve the existing exemptions without counting them as leftovers.
    mkdir "$case_dir/wt/.claude"
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.fm-grok-turnend"
  fi
  before=$(git -C "$case_dir/wt" status --porcelain)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$kind/$mode: dirty teardown must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "$kind/$mode: no refusal"
  if [ "$kind" = untracked ]; then
    grep -Fq 'uncommitted changes present (untracked-only leftovers)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing untracked-only classification"
    ! grep -q 'includes tracked edits' "$case_dir/stderr" || fail "$kind/$mode: misclassified as tracked"
  else
    grep -Fq 'uncommitted changes present (includes tracked edits)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing tracked-edit classification"
    ! grep -q 'untracked-only' "$case_dir/stderr" || fail "$kind/$mode: misclassified as untracked-only"
  fi
  if [ "$kind" != tracked ]; then
    grep -Fq '00 proof scratch/' "$case_dir/stderr" || fail "$kind/$mode: scratch folder not named"
    grep -Fxq '  09-scratch.txt' "$case_dir/stderr" || fail "$kind/$mode: tenth path missing"
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.fm-grok-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

# Treehouse's return runs `git clean -fd` (one -f). A nested repository stays.
add_treehouse_clean_fd() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Return succeeds, then plants a nested repository the pre-return scrub cannot
# have removed. The post-return check must name that residue.
add_treehouse_that_leaves_residue() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
    git init -q "$wt/left-behind-clone"
    git -C "$wt/left-behind-clone" commit -q --allow-empty -m residue
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

prepare_scout_teardown() {
  local case_dir=$1
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
}

# Clone a nested repository into the copy and add one plain scratch file.
seed_nested_clone_and_scratch() {
  local case_dir=$1 wt=$2
  git init -q "$case_dir/nested-src"
  printf 'payload\n' > "$case_dir/nested-src/payload.txt"
  git -C "$case_dir/nested-src" add payload.txt
  git -C "$case_dir/nested-src" -c user.email=t@t -c user.name=t commit -q -m payload
  git clone -q "$case_dir/nested-src" "$wt/scratch-clone"
  printf 'scratch\n' > "$wt/scratch.txt"
}

# Move the case worktree to pool/<slot>/repo so teardown sees a Treehouse slot.
move_case_to_pool_slot() {
  local case_dir=$1 slot=$2 dest
  dest="$case_dir/pool/$slot/repo"
  mkdir -p "$case_dir/pool/$slot"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$dest"
  printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$dest" \
    > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$dest"
}

test_scout_nested_clone_returns_with_no_untracked_entries() {
  local case_dir wt rc
  case_dir=$(make_case scout-nested-clean)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-nested-clean: teardown should return the scratch copy"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-nested-clean: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  assert_absent "$wt/scratch-clone" "scout-nested-clean: nested clone survived return"
  assert_absent "$wt/scratch.txt" "scout-nested-clean: scratch file survived return"
  pass "scout copy with a nested clone and a scratch file returns with no untracked entries"
}

test_ship_nested_clone_is_refused_and_bytes_stay() {
  local case_dir wt rc head before after
  case_dir=$(make_case ship-nested-refuse)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  before=$(cksum "$wt/scratch-clone/payload.txt")
  head=$(git -C "$wt" rev-parse HEAD)
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ship-nested-refuse: teardown should refuse a nested clone"
  assert_grep "REFUSED" "$case_dir/stderr" "ship-nested-refuse: no REFUSED line"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "ship-nested-refuse: refusal did not cite uncommitted changes"
  after=$(cksum "$wt/scratch-clone/payload.txt")
  [ "$before" = "$after" ] || fail "ship-nested-refuse: nested clone bytes changed"
  assert_present "$wt/scratch-clone/.git" "ship-nested-refuse: nested repository was removed"
  assert_present "$wt/scratch.txt" "ship-nested-refuse: scratch file was removed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "ship-nested-refuse: refusal returned the copy: $(cat "$case_dir/treehouse.log")"
  assert_refusal_retained_task_state "$case_dir" "ship-nested-refuse" "$head"
  pass "ship copy with a nested clone is refused and its bytes stay"
}

test_dirty_return_warns_which_slot_was_lost() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return)
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 4 "$rc" "dirty-return: a lost slot should exit 4 after cleanup"
  assert_grep "pool slot 9" "$case_dir/stderr" "dirty-return: warning did not name the slot"
  assert_grep "left-behind-clone" "$case_dir/stderr" "dirty-return: warning did not name the remaining path"
  assert_grep "lost this slot" "$case_dir/stderr" "dirty-return: warning did not say the pool lost the slot"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "dirty-return: stdout still reported a clean return"
  assert_grep "Backlog: task-x1" "$case_dir/stdout" \
    "dirty-return: the finished teardown skipped its backlog reminder"
  assert_absent "$case_dir/state/task-x1.meta" "dirty-return: task record was not removed"
  pass "a return that leaves residue names the lost slot and the remaining paths"
}

test_dirty_return_warns_even_when_a_later_step_refuses() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return-later-refusal)
  wt=$(move_case_to_pool_slot "$case_dir" 8)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-return-later-refusal: the endpoint refusal should fail teardown"
  assert_grep "could not be closed" "$case_dir/stderr" \
    "dirty-return-later-refusal: fixture did not reach the endpoint close refusal"
  assert_grep "pool slot 8" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the lost-slot warning"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the remaining paths"
  pass "a dirty return is reported even when a later teardown step refuses"
}

test_forced_secondmate_child_scout_nested_clone_returns_clean() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-nested-clean)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/child-scout-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  seed_nested_clone_and_scratch "$case_dir" "$child_wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "secondmate-child-nested-clean: forced secondmate teardown should succeed"
  [ -z "$(git -C "$child_wt" status --porcelain --untracked-files=all)" ] \
    || fail "secondmate-child-nested-clean: untracked entries remain: $(git -C "$child_wt" status --porcelain --untracked-files=all)"
  assert_absent "$child_wt/scratch-clone" "secondmate-child-nested-clean: nested clone survived return"
  assert_absent "$child_wt/scratch.txt" "secondmate-child-nested-clean: scratch file survived return"
  assert_no_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-nested-clean: a clean child return was reported as a lost slot"
  pass "a forced secondmate teardown returns a child scout copy with a nested clone clean"
}

# Return succeeds but leaves no readable worktree behind to verify.
add_treehouse_that_removes_copy() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  for a in "$@"; do wt=$a; done
  rm -f "$wt/.git"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# The remote host runs exactly this forced secondmate teardown for
# `fm-remote-secondmate-control.sh retire --force`; the local side finishes the
# route, record, and reply-source cleanup when it exits 0 or 4 (lost slot).
test_forced_secondmate_dirty_child_return_warns_and_completes() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-dirty-return)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/pool/6/repo"
  mkdir -p "$case_dir/pool/6"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  printf '{"worktrees":[{"name":"6","path":"%s"}]}\n' "$child_wt" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "secondmate-child-dirty-return: a lost child slot should exit 4 after retirement"
  assert_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-dirty-return: no lost-slot warning for the dirty child return"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "secondmate-child-dirty-return: warning did not name the remaining path"
  assert_absent "$case_dir/state/task-x1.meta" "secondmate-child-dirty-return: task record was not removed"
  assert_absent "$home" "secondmate-child-dirty-return: secondmate home was not removed"
  pass "a forced secondmate teardown warns about a dirty child return and still completes"
}

test_return_that_removes_copy_warns_cannot_verify() {
  local case_dir wt rc
  case_dir=$(make_case return-removes-copy)
  wt=$(move_case_to_pool_slot "$case_dir" 7)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_removes_copy "$case_dir"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "return-removes-copy: an unverified slot should exit 4 after cleanup"
  assert_grep "lost this slot" "$case_dir/stderr" "return-removes-copy: no lost-slot warning"
  assert_grep "cannot verify" "$case_dir/stderr" "return-removes-copy: warning did not say the slot is unverified"
  assert_grep "$wt" "$case_dir/stderr" "return-removes-copy: warning did not name the copy"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-removes-copy: stdout still reported a clean return"
  assert_absent "$case_dir/state/task-x1.meta" "return-removes-copy: task record was not removed"
  pass "a return that leaves no readable copy reports the slot as unverified, not clean"
}

test_scout_ignored_files_survive_scratch_clean() {
  local case_dir wt rc
  case_dir=$(make_case scout-ignored-survives)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' 'ignored-cache/' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "ignore cache"
  mkdir -p "$wt/ignored-cache"
  printf 'keep-me\n' > "$wt/ignored-cache/blob"
  printf 'scratch\n' > "$wt/scratch.txt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-ignored: teardown should succeed"
  [ "$(cat "$wt/ignored-cache/blob")" = "keep-me" ] \
    || fail "scout-ignored: ignored file was removed or changed"
  assert_absent "$wt/scratch.txt" "scout-ignored: scratch file survived"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-ignored: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  pass "ignored files survive the scratch clean and plain scratch does not"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}

# Override fakebin/tmux so the recovery-grade classifier reads the endpoint as
# unreadable (a session inventory failure it cannot attribute), never dead.
add_unreadable_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "error connecting to fixture: permission denied" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}

write_windowless_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3 worktree
  worktree=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

test_windowless_legacy_record_with_gone_worktree_tears_down() {
  local case_dir out
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") \
    || fail "windowless-gone: teardown refused a leftover with no window, no spawn_gen, and no worktree"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-gone: the teardown line did not log the missing-endpoint leftover: $out"
  printf '%s\n' "$out" | grep -Fq 'window none' \
    || fail "windowless-gone: the teardown line did not say there was no window: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-gone: teardown returned success with its backlog item still open"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-gone: teardown left the leftover record"
  pass "a windowless leftover with no spawn_gen and no worktree tears down without --legacy-record"
}

test_windowless_legacy_record_tears_down_with_the_legacy_flag() {
  local case_dir out
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "windowless-flag: --legacy-record refused a leftover with no window and no spawn_gen"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-flag: the teardown line did not log the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-flag: teardown left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-flag: teardown returned success with its backlog item still open"
  pass "a windowless leftover with no spawn_gen also tears down when --legacy-record is passed"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
}

assert_windowless_record_refuses() {  # <case-dir> <description> <refusal>
  local case_dir=$1 description=$2 refusal=$3 rc before
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$description: a windowless record outside the leftover class must refuse"
  grep -Fq "$refusal" "$case_dir/stderr" \
    || fail "$description: the refusal was not '$refusal': $(cat "$case_dir/stderr")"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "$description: the refusal modified the task record"
}

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-spawn-gen)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-spawn-gen "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-no-backlog)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  assert_windowless_record_refuses "$case_dir" windowless-no-backlog "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a spawn_gen, a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl"
  sed -i.bak '/^pr=/d' "$case_dir/state/task-x1.meta" && rm -f "$case_dir/state/task-x1.meta.bak"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  grep -q "rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-rollback: the refusal did not report the rolled-back stamp"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}

# Override fakebin/perl so ONLY the stamp rollback's truncate fails; every other
# perl call in the lifecycle still runs the real interpreter, so the abandoned
# attempt leaves its stamp behind for exactly the reason under test.
add_failing_truncate_perl() {
  local case_dir=$1 real
  real=$(command -v perl)
  cat > "$case_dir/fakebin/perl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *truncate*) exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/perl"
}

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# Mark the case's home as a secondmate home bound to a parent: teardown and
# fm-pr-check run with FM_HOME="$case_dir/home" so the parent-channel
# publishers resolve that binding while the task state stays in $case_dir/state.
configure_secondmate_home() {  # <case-dir> <local|remote> [<parent-home>]
  local case_dir=$1 route=$2 parent=${3:-} home="$1/home"
  mkdir -p "$home"
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route"
    [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
  } > "$home/.fm-secondmate-parent"
  if [ "$route" = local ]; then
    # A local parent registers the mate; teardown resolves that registration.
    mkdir -p "$parent/state" "$parent/data"
    fm_write_secondmate_meta "$parent/state/mate-x.meta" "$home"
    printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
      "$home" > "$parent/data/secondmates.md"
  fi
}

# Registering a PR inside a secondmate home publishes the child's ready line
# with the canonical URL on the parent channel from fm-pr-check itself, once;
# a main home publishes nothing.
test_secondmate_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: fm-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$case_dir/state/parent-replies.status" ] || fail "main-pr-ready: a main home wrote a parent reply"
  pass "fm-pr-check publishes the PR-ready line on a secondmate's parent channel once"
}

# Tearing a child down inside a secondmate home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_secondmate_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

# The Herdr presentation-lock namespace is named per OS account. These cases
# act as a fixture account uid (via an `id -u` shim) so they never touch the
# real account's namespace or the old shared /tmp/firstmate-herdr-presentation,
# and every directory the fixture account resolves is really owned by the
# running account, i.e. by another uid from the fixture account's view.
# FM_FAKE_NS_STAT names one path whose owner and mode the `stat` shim reports
# instead; the adapter reads ownership through a PATH `stat` only on its non-
# Darwin branch, so the arms that need it run only there.
herdr_lock_ns_fake_uid() {
  printf '%s' "$((3000000000 + $$ % 1000000))"
}

configure_herdr_lock_ns_shims() {  # <case-dir>
  local case_dir=$1 real_id real_stat
  real_id=$(command -v id); real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/id" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ] && [ "\$#" -eq 1 ] && [ -n "\${FM_FAKE_ACCOUNT_UID:-}" ]; then
  printf '%s\n' "\$FM_FAKE_ACCOUNT_UID"
  exit 0
fi
exec "$real_id" "\$@"
SH
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 3 ] && [ "\$1" = -c ] && [ -n "\${FM_FAKE_NS_STAT:-}" ] \\
  && [ "\$3" = "\${FM_FAKE_NS_STAT%%:*}" ]; then
  rest=\${FM_FAKE_NS_STAT#*:}
  case "\$2" in
    %u) printf '%s\n' "\${rest%%:*}"; exit 0 ;;
    %a) printf '%s\n' "\${rest#*:}"; exit 0 ;;
  esac
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/id" "$case_dir/fakebin/stat"
}

herdr_lock_ns_path_state() {  # <path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    # A fixed, known path: ls is the portable way to read mode and numeric owner.
    # shellcheck disable=SC2012
    ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $4}'
  else
    printf 'absent'
  fi
}

run_herdr_lock_ns_teardown() {  # <case-dir> <fake-uid> [stat-spec]
  local case_dir=$1 fake_uid=$2 stat_spec=${3:-} rc=0
  FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$stat_spec" \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  return "$rc"
}

new_herdr_lock_ns_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  configure_herdr_lock_ns_shims "$case_dir"
  : > "$case_dir/herdr.log"
  : > "$case_dir/state/task-x1.status"
  printf '%s' "$case_dir"
}

assert_herdr_lock_ns_refused() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  assert_grep "presentation lock could not be resolved" "$case_dir/stderr" \
    "$label: the namespace refusal was not explained visibly"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: refusal erased the durable endpoint metadata"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ ! -e "$case_dir/closed" ] || fail "$label: refusal attempted a pane close without the lock"
}

test_herdr_teardown_presentation_lock_namespace_is_per_account() {
  local fake_uid own_ns legacy legacy_before legacy_after own_before case_dir rc lock linux_arms=0
  fake_uid=$(herdr_lock_ns_fake_uid)
  [ "$fake_uid" != "$(id -u)" ] || fail "herdr-lock-ns: fixture account uid collides with the running account"
  own_ns="/tmp/firstmate-herdr-presentation-$fake_uid"
  legacy=/tmp/firstmate-herdr-presentation
  [ ! -e "$own_ns" ] && [ ! -L "$own_ns" ] \
    || fail "herdr-lock-ns: fixture namespace $own_ns already exists; refusing to reuse it"
  printf '%s\n' "$own_ns" >> "$FM_TEST_CLEANUP_REGISTRY"
  mkdir -m 700 "$own_ns" || fail "herdr-lock-ns: could not stage $own_ns"
  legacy_before=$(herdr_lock_ns_path_state "$legacy")

  # This account's own name, really owned by another uid, is still refused and
  # is left exactly as it was.
  own_before=$(herdr_lock_ns_path_state "$own_ns")
  case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-foreign-owner)
  rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-lock-ns-foreign-owner: teardown adopted a namespace another uid owns"
  assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-foreign-owner
  [ "$(herdr_lock_ns_path_state "$own_ns")" = "$own_before" ] \
    || fail "herdr-lock-ns-foreign-owner: refusal changed the foreign-owned namespace: $(herdr_lock_ns_path_state "$own_ns")"

  if [ "$(uname -s)" != Darwin ]; then
    linux_arms=1
    # The old shared name is owned by another uid whenever it exists here, as
    # on a host where a second account created it first; this account's
    # teardown no longer consults it and completes in its own namespace.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-other-account)
    run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:700" \
      || fail "herdr-lock-ns-other-account: teardown was blocked: $(cat "$case_dir/stderr")"
    [ -e "$case_dir/closed" ] || fail "herdr-lock-ns-other-account: the pane was not closed under the lock"
    [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-lock-ns-other-account: teardown left the metadata behind"
    grep -q "teardown task-x1 complete" "$case_dir/stdout" \
      || fail "herdr-lock-ns-other-account: teardown did not report completion"
    lock=$(FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$own_ns:$fake_uid:700" \
      FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
      PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
      || fail "herdr-lock-ns-other-account: could not resolve the fixture account's lock path"
    case "$lock" in
      "$own_ns"/order-*.lock) ;;
      *) fail "herdr-lock-ns-other-account: the lock is not in this account's namespace: $lock" ;;
    esac

    # This account's own name with the right owner but the wrong mode is refused.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-wrong-mode)
    rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:755" || rc=$?
    [ "$rc" -ne 0 ] || fail "herdr-lock-ns-wrong-mode: teardown adopted a namespace that is not mode 700"
    assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-wrong-mode
    [ -d "$own_ns" ] || fail "herdr-lock-ns-wrong-mode: refusal removed the namespace"
  fi

  legacy_after=$(herdr_lock_ns_path_state "$legacy")
  [ "$legacy_after" = "$legacy_before" ] \
    || fail "herdr-lock-ns: teardown changed the old shared namespace: $legacy_before -> $legacy_after"
  rm -rf "$own_ns"
  if [ "$linux_arms" = 1 ]; then
    pass "herdr teardown takes its lock in a per-account namespace another account cannot block, and still refuses a foreign-owned or wrong-mode one"
  else
    pass "herdr teardown refuses a foreign-owned per-account namespace (owner-shim arms need the non-Darwin stat branch; skipped on Darwin)"
  fi
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

configure_secondmate_with_tmux_children() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" child child_wt
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  for child in child-a child-b; do
    child_wt="$case_dir/$child-wt"
    git -C "$case_dir/project" worktree add -q -b "fm/$child" "$child_wt" main
    fm_write_meta "$home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=local-only"
    : > "$home/state/$child.status"
  done
}

test_forced_secondmate_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/kill.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export FM_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ -s "$case_dir/kill.log" ] && [ -s "$case_dir/treehouse.log" ] \
    || fail "descendant-locks: uncontended retry did not perform endpoint and worktree cleanup"
  pass "forced secondmate teardown holds every descendant lifecycle and metadata lock"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    if [ "${FM_FAKE_HERDR_RESTORE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
}

# A task's per-task watcher markers (.seen-<id>_status, .seen-<id>_turn-ended,
# .hb-surfaced-<id>) and an orphaned presentation journal - one whose pane the
# close path proved gone without retiring it - must not outlive teardown, while
# another task's markers and a journal bound to a different pane must.
seed_watcher_markers() {  # <case-dir> <task-id>
  local state="$1/state" id=$2
  printf '0:0\n' > "$state/.seen-${id}_status"
  printf '0:0\n' > "$state/.seen-${id}_turn-ended"
  printf '0\n' > "$state/.hb-surfaced-$id"
}

test_teardown_retires_task_watcher_markers_and_orphan_journal() {
  local case_dir log closed restored marker
  case_dir=$(make_case retire-watcher-markers)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # The projected workspace is already gone before teardown runs, so the close
  # path cannot match the journal to a live workspace and leaves it behind.
  : > "$closed"
  seed_watcher_markers "$case_dir" task-x1
  seed_watcher_markers "$case_dir" task-y2
  seed_watcher_markers "$case_dir" task-x1_extra
  printf '%s\n' 'version=1' 'task_id=task-y2' 'projection_id=ZyXwVuTsRqPoNmLkJiHgFe' \
    > "$case_dir/state/task-y2.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-watcher-markers: teardown failed: $(cat "$case_dir/stderr")"
  for marker in .seen-task-x1_status .seen-task-x1_turn-ended .hb-surfaced-task-x1 task-x1.herdr-presentation; do
    assert_absent "$case_dir/state/$marker" "teardown left the torn-down task's $marker behind"
  done
  for marker in .seen-task-y2_status .seen-task-y2_turn-ended .hb-surfaced-task-y2 task-y2.herdr-presentation \
    .seen-task-x1_extra_status .seen-task-x1_extra_turn-ended .hb-surfaced-task-x1_extra; do
    assert_present "$case_dir/state/$marker" "teardown removed another task's $marker"
  done
  pass "teardown retires the task's own watcher markers and orphaned presentation journal, leaving other tasks' markers alone"
}

test_teardown_retains_journal_bound_to_another_pane() {
  local case_dir log closed restored
  case_dir=$(make_case retain-drifted-journal)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  : > "$closed"
  # A version 2 binding that advanced to a replacement pane the metadata never
  # recorded may still name a live quarantined space; only the sweep may judge it.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p9' \
    'parent_workspace_id=w0' 'parent_label=firstmate' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=fm-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-drifted-journal: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "teardown retired a journal bound to a pane it never proved gone"
  assert_absent "$case_dir/state/task-x1.meta" "retain-drifted-journal: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown kept the drifted journal without saying why"
  pass "teardown retains a presentation journal bound to a pane other than the closed endpoint"
}

# A version 1 attempt journal binds no pane, so proving the recorded task pane
# gone does not prove its token-bearing projected workspace gone. When the v2
# bind never landed (RETIRE_CANDIDATE stays 0 because the metadata workspace no
# longer matches the drifted token workspace), teardown may retire the journal
# only after the session's workspace list confirms the token workspace is gone;
# while it is still present the session-start sweep alone owns it.
configure_herdr_v1_orphan_workspace_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ "${FM_FAKE_HERDR_WS_MALFORMED:-0}" = 1 ]; then
      # A non-object entry before a live token-bearing workspace: the token query
      # is ambiguous, so teardown must treat it as unknown and keep the journal.
      printf '%s\n' '{"result":{"workspaces":[42,{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false}]}}'
    elif [ "${FM_FAKE_HERDR_WS_COLLAPSED:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    fi
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_teardown_retires_v1_journal_when_projected_workspace_gone() {
  local case_dir log closed
  case_dir=$(make_case retire-v1-journal-workspace-gone)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_COLLAPSED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-v1-journal-workspace-gone: teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is confirmed gone was not retired"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retire-v1-journal-workspace-gone: teardown did not complete"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retire-v1-journal-workspace-gone: teardown must never call workspace close"
  pass "teardown retires a v1 presentation journal once its token workspace is confirmed gone"
}

test_teardown_retains_v1_journal_when_projected_workspace_present() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-present)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-present: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is still present was wrongly retired, stranding the workspace"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-present: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-present: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal while its token workspace is still present"
}

test_teardown_retains_v1_journal_when_workspace_query_ambiguous() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-ambiguous)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  # A malformed workspace-list entry makes the token query ambiguous: teardown
  # cannot prove the token workspace gone, so it must keep the journal.
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_MALFORMED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-ambiguous: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal was retired even though the workspace query was ambiguous"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-ambiguous: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-ambiguous: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal when the workspace query is ambiguous"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

# One row of the real `no-mistakes runs` ledger: plain text, newest-first,
# no run id, no quoting - "<status> <branch> <short-sha> <date> <time> [<pr-url>]"
# (the same shape tests/fm-crew-state.test.sh's runs-list fixtures pin).
ledger_row() {  # <status> <branch> <short-sha> <date> <time> [pr-url]
  printf '  %-10s %-24s %-8s  %s %s' "$1" "$2" "$3" "$4" "$5"
  [ -z "${6:-}" ] || printf '  %s' "$6"
  printf '\n'
}

# Commit <n> pipeline fix rounds on top of the task branch in a separate
# clone of origin that the task copy NEVER fetches from, mirroring how the
# no-mistakes daemon commits fix rounds in its own gate-repo clone. Echoes
# the newest short sha, which is genuinely absent from the task worktree's
# object store. Args: case_dir [rounds]
make_unfetched_pipeline_heads() {
  local case_dir=$1 rounds=${2:-1} i
  git clone -q "$case_dir/origin.git" "$case_dir/pipeline-clone"
  git -C "$case_dir/pipeline-clone" checkout -q fm/task-x1
  for i in $(seq 1 "$rounds"); do
    git -C "$case_dir/pipeline-clone" -c user.email=t@t -c user.name=t \
      commit -q --allow-empty -m "pipeline fix round $i"
  done
  git -C "$case_dir/pipeline-clone" rev-parse --short=7 HEAD
}

assert_head_absent_from_worktree() {  # <worktree> <short-sha> <label>
  [ -z "$(git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null)" ] \
    || fail "$3: fixture broke - the pipeline head resolved in the task copy"
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/fm-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" FM_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone still leaves a durable
# account: the recorder writes an unavailable-source line before the record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# An abort can race a concurrent gate response: the run finishes with a
# passing-but-not-clean outcome (an explicitly approved Test/CI exception)
# instead of landing on `cancelled`. That is still a terminal, finished run,
# so teardown must conclude cleanly rather than refuse as still-parked.
test_parked_own_run_concludes_on_passed_with_override_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-override)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-override: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-override: a passing override outcome must not be reported as still parked"
  pass "a run that lands on passed-with-override after abort is still recognized as terminal"
}

# The same race, landing on the other automatic passing-but-not-clean outcome:
# publication or CI verification was skipped instead of an explicit override.
# That is still a terminal, finished run.
test_parked_own_run_concludes_on_passed_with_skips_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-skips)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-skips: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-skips: a passing skips outcome must not be reported as still parked"
  pass "a run that lands on passed-with-skips after abort is still recognized as terminal"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# Copy the public teardown script tree, then drop or blank one required file.
# Symlinks keep the copy cheap; an unreadable case replaces one link with a
# real mode-000 file so the probe is of the file itself.
prepare_teardown_source_copy() {  # <case-dir>
  local case_dir=$1 f base dest="$1/test-root/bin" s
  mkdir -p "$dest/backends"
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    if [ -d "$f" ]; then
      mkdir -p "$dest/$base"
      for s in "$f"/*; do
        ln -s "$s" "$dest/$base/$(basename "$s")"
      done
    else
      ln -s "$f" "$dest/$base"
    fi
  done
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/state/task-x1.status"
}

run_copied_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" task-x1 "$@"
}

assert_source_refusal_preserved_state() {  # <case-dir> <label> <stderr-needle>
  local case_dir=$1 label=$2 needle=$3
  [ "$rc" -ne 0 ] || fail "$label: teardown reported success after a required source disappeared"
  assert_grep "$needle" "$case_dir/stderr" "$label: the refusal did not name the missing source"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ ! -s "$case_dir/treehouse.log" ] || fail "$label: the refusal returned the local copy: $(cat "$case_dir/treehouse.log")"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source" "required source fm-nm-run-lib.sh"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source" "required source fm-nm-run-lib.sh"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling" "required tmux source"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source" "required herdr source"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source" "required zellij source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

# A pool slot another task has claimed. The copy stays on disk. This task no
# longer owns it, and the project lock resolves inside the case home.
stage_reassigned_open_request() {  # <case-dir>
  local case_dir=$1 slot
  slot=$case_dir/pool/1/project
  mkdir -p "$case_dir/pool/1"
  git -C "$case_dir/project" worktree add -q --detach "$slot" main
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' other-task "$case_dir/other-home" \
    > "$case_dir/pool/1/.fm-slot-owner"
  printf 'kept\n' > "$slot/kept.txt"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  write_meta "$case_dir" no-mistakes ship "$slot"
  append_pr_meta_url "$case_dir"
  add_gh_axi_pr_state "$case_dir" open
}

run_teardown_in_case_home() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_HOME="$case_dir" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

assert_reassigned_slot_untouched() {  # <case-dir> <label>
  local case_dir=$1 label=$2 slot
  slot=$case_dir/pool/1/project
  assert_present "$slot/kept.txt" "$label: the other task's copy was removed"
  assert_grep "task=other-task" "$case_dir/pool/1/.fm-slot-owner" \
    "$label: the other task's slot claim was rewritten"
  if grep -q return "$case_dir/treehouse.log"; then
    fail "$label: teardown returned the other task's slot: $(cat "$case_dir/treehouse.log")"
  fi
}

test_recorded_request_refuses_when_the_copy_is_gone_or_reassigned() {
  local state case_dir rc meta_state forge_read
  for state in open merged closed; do
    case_dir=$(make_case "recorded-pr-$state-gone")
    write_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
    append_pr_meta_url "$case_dir"
    add_gh_axi_pr_state "$case_dir" "$state"
    assert_absent "$case_dir/missing-wt" \
      "recorded-pr-$state-gone: the fixture created the recorded copy"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    if [ -e "$case_dir/state/task-x1.meta" ]; then
      meta_state=present
    else
      meta_state=absent
    fi
    if [ -f "$case_dir/gh-axi.log" ]; then
      forge_read=$(cat "$case_dir/gh-axi.log")
    else
      forge_read=none
    fi
    if [ "$state" = open ]; then
      expect_code 1 "$rc" "recorded-pr-open-gone: an open pull request must refuse when the recorded copy is gone (meta=$meta_state forge=$forge_read)"$'\n'"$(cat "$case_dir/stderr")"
      assert_grep "still open" "$case_dir/stderr" \
        "recorded-pr-open-gone: refusal did not say the request is still open"
      assert_present "$case_dir/state/task-x1.meta" \
        "recorded-pr-open-gone: the refusal erased the task record"
      assert_grep "pr view 7 --repo example/repo" "$case_dir/gh-axi.log" \
        "recorded-pr-open-gone: teardown did not read the recorded pull request"
      assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
        "recorded-pr-open-gone: the refusal reported cleanup complete"
    else
      expect_code 0 "$rc" "recorded-pr-$state-gone: a $state pull request should tear down when the copy is gone (meta=$meta_state forge=$forge_read)"$'\n'"$(cat "$case_dir/stderr")"
      assert_no_grep "REFUSED" "$case_dir/stderr" \
        "recorded-pr-$state-gone: teardown printed a REFUSED line"
      assert_absent "$case_dir/state/task-x1.meta" \
        "recorded-pr-$state-gone: teardown left the task record"
      assert_grep "pr view 7 --repo example/repo" "$case_dir/gh-axi.log" \
        "recorded-pr-$state-gone: teardown did not read the recorded pull request"
    fi
  done

  case_dir=$(make_case recorded-pr-unreadable-gone)
  write_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  append_pr_meta_url "$case_dir"
  add_gh_axi_error "$case_dir"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded-pr-unreadable-gone: an unreadable forge state must refuse when the copy is gone"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "could not be read" "$case_dir/stderr" \
    "recorded-pr-unreadable-gone: refusal did not say the forge state could not be read"
  assert_present "$case_dir/state/task-x1.meta" \
    "recorded-pr-unreadable-gone: the refusal erased the task record"

  case_dir=$(make_case recorded-pr-open-gone-force)
  write_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  append_pr_meta_url "$case_dir"
  add_gh_axi_pr_state "$case_dir" open
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "recorded-pr-open-gone-force: --force should still discard an open pull request when the copy is gone"$'\n'"$(cat "$case_dir/stderr")"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "recorded-pr-open-gone-force: --force printed a REFUSED line"
  assert_absent "$case_dir/state/task-x1.meta" \
    "recorded-pr-open-gone-force: --force left the task record"

  case_dir=$(make_case recorded-pr-open-reassigned)
  stage_reassigned_open_request "$case_dir"
  set +e
  run_teardown_in_case_home "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded-pr-open-reassigned: an open pull request must refuse when another task owns the slot"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "still open" "$case_dir/stderr" \
    "recorded-pr-open-reassigned: refusal did not say the request is still open"
  assert_grep "reassigned" "$case_dir/stderr" \
    "recorded-pr-open-reassigned: teardown did not recognize the slot was reassigned"
  assert_grep "pr view 7 --repo example/repo" "$case_dir/gh-axi.log" \
    "recorded-pr-open-reassigned: teardown did not read the recorded pull request"
  assert_present "$case_dir/state/task-x1.meta" \
    "recorded-pr-open-reassigned: the refusal erased the task record"
  assert_reassigned_slot_untouched "$case_dir" recorded-pr-open-reassigned
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "recorded-pr-open-reassigned: the refusal reported cleanup complete"

  case_dir=$(make_case recorded-pr-open-reassigned-force)
  stage_reassigned_open_request "$case_dir"
  set +e
  run_teardown_in_case_home "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "recorded-pr-open-reassigned-force: --force should still discard an open pull request when the slot was reassigned"$'\n'"$(cat "$case_dir/stderr")"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "recorded-pr-open-reassigned-force: --force printed a REFUSED line"
  assert_absent "$case_dir/state/task-x1.meta" \
    "recorded-pr-open-reassigned-force: --force left the task record"
  assert_reassigned_slot_untouched "$case_dir" recorded-pr-open-reassigned-force

  pass "an open or unreadable recorded request keeps the task record when the copy is gone or reassigned"
}

test_recorded_github_request_ignores_enterprise_host() {
  local reader enterprise_state case_dir tool rc
  for reader in gh gh-axi; do
    for enterprise_state in CLOSED MERGED; do
      case_dir=$(make_case "recorded-pr-host-$reader-$enterprise_state")
      write_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
      append_pr_meta_url "$case_dir"
      for tool in gh gh-axi; do
        cat > "$case_dir/fakebin/$tool" <<'SH'
#!/usr/bin/env bash
command_pair="${1:-} ${2:-}"
if [ "$command_pair" = "api graphql" ] && [ "$FM_TEST_RECORD_READER" = gh-axi ]; then
  exit 1
fi
host=${GH_HOST:-github.com}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) shift; host=${1:-} ;;
  esac
  shift
done
state=$FM_TEST_ENTERPRISE_STATE
[ "$host" != github.com ] || state=OPEN
case "$command_pair" in
  "api graphql")
    merged=false
    [ "$state" != MERGED ] || merged=true
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    ;;
  "pr view")
    printf 'pull_request:\n  number: 7\n  state: %s\n' "$state"
    ;;
  *) exit 1 ;;
esac
SH
        chmod +x "$case_dir/fakebin/$tool"
      done

      rc=0
      GH_HOST=ghe.example FM_TEST_RECORD_READER="$reader" \
        FM_TEST_ENTERPRISE_STATE="$enterprise_state" \
        run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 1 "$rc" "$reader: an enterprise $enterprise_state PR must not allow cleanup of an open github.com PR"$'\n'"$(cat "$case_dir/stderr")"
      assert_grep "still open" "$case_dir/stderr" \
        "$reader: cleanup did not read the open github.com PR"
      assert_present "$case_dir/state/task-x1.meta" \
        "$reader: cleanup erased the open github.com PR's task record"
      assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
        "$reader: cleanup reported completing an open github.com PR"
    done
  done
  pass "both GitHub readers ignore enterprise PR state and retain an open github.com PR's record"
}

test_recorded_request_state_decides_pushed_teardown() {
  local state case_dir rc head
  for state in open merged closed; do
    case_dir=$(make_case "recorded-pr-$state")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt "$state" "ship $state"
    append_pr_meta_url "$case_dir"
    git -C "$case_dir/wt" push -q origin fm/task-x1
    git -C "$case_dir/project" fetch -q origin
    add_gh_axi_pr_state "$case_dir" "$state"
    head=$(git -C "$case_dir/wt" rev-parse HEAD)

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    if [ "$state" = open ]; then
      expect_code 1 "$rc" "recorded-pr-open: an open pull request must refuse even when the branch is on origin"$'\n'"$(cat "$case_dir/stderr")"
      grep -q 'still open' "$case_dir/stderr" || fail "recorded-pr-open: refusal did not say the request is still open"
      assert_refusal_retained_task_state "$case_dir" recorded-pr-open "$head"
    else
      expect_code 0 "$rc" "recorded-pr-$state: a $state pull request whose branch is on origin should tear down"$'\n'"$(cat "$case_dir/stderr")"
      ! grep -q REFUSED "$case_dir/stderr" || fail "recorded-pr-$state: teardown printed a REFUSED line"
      assert_absent "$case_dir/state/task-x1.meta" "recorded-pr-$state: teardown left the task record"
    fi
    grep -q 'pr view 7 --repo example/repo' "$case_dir/gh-axi.log" \
      || fail "recorded-pr-$state: teardown did not read the recorded pull request"
  done

  case_dir=$(make_case recorded-pr-unreadable)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt unread "ship unread"
  append_pr_meta_url "$case_dir"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_gh_axi_error "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded-pr-unreadable: an unreadable forge state must refuse"$'\n'"$(cat "$case_dir/stderr")"
  grep -q 'could not be read' "$case_dir/stderr" \
    || fail "recorded-pr-unreadable: refusal did not say the forge state could not be read"
  assert_refusal_retained_task_state "$case_dir" recorded-pr-unreadable "$head"

  case_dir=$(make_case recorded-pr-open-force)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt forced "ship forced"
  append_pr_meta_url "$case_dir"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_gh_axi_pr_state "$case_dir" open
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "recorded-pr-open-force: --force should still discard an open pull request"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "recorded-pr-open-force: --force printed a REFUSED line"
  assert_absent "$case_dir/state/task-x1.meta" "recorded-pr-open-force: --force left the task record"

  case_dir=$(make_case recorded-mr-open)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt mr "ship mr"
  printf '%s\n' 'pr=https://gitlab.example.com/group/repo/-/merge_requests/7' \
    >> "$case_dir/state/task-x1.meta"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"state":"opened"}'
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded-mr-open: an open merge request must refuse even when the branch is on origin"$'\n'"$(cat "$case_dir/stderr")"
  grep -q 'still open' "$case_dir/stderr" || fail "recorded-mr-open: refusal did not say the request is still open"
  assert_refusal_retained_task_state "$case_dir" recorded-mr-open "$head"

  case_dir=$(make_case recorded-forgejo-open)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt fj "ship fj"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' 'pr=https://git.example.org/team/repo/pulls/7' >> "$case_dir/state/task-x1.meta"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"open","merged":false,"head":{"sha":"%s"}}\n' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "recorded-forgejo-open: an open Forgejo pull request must refuse even when the branch is on origin"$'\n'"$(cat "$case_dir/stderr")"
  grep -q 'still open' "$case_dir/stderr" || fail "recorded-forgejo-open: refusal did not say the request is still open"
  assert_refusal_retained_task_state "$case_dir" recorded-forgejo-open "$head"

  pass "a recorded open pull request or merge request keeps the task record until it is merged or closed"
}

if [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-aliases ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-components ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-names ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-directories ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-spellings ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-retirement ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-beads ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-legacy ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-github ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-legacy-reuse ] \
  && [ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data-ordering ]; then
  test_missing_startup_source_refuses_before_cleanup
  test_unreadable_startup_source_refuses_before_cleanup
  test_missing_adapter_sibling_refuses_before_cleanup
  test_forced_child_missing_adapter_sibling_refuses_before_cleanup
  test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup
  test_retained_sources_still_reach_the_ordinary_refusal
fi
test_task_data_cleanup() {
  local case_dir task recovery rc
  case_dir=$(make_case task-data)
  task="$case_dir/data/task-x1"
  recovery="$task/.cleanup-hold"
  mkdir -p "$task/clone/.git/objects" "$task/record" "$task/proof"
  printf 'brief\n' > "$task/brief.md"
  printf 'report links [capture](proof/capture.png)\n' > "$task/report.md"
  printf 'review\n' > "$task/review.txt"
  printf 'status references status-proof.bin\n' > "$task/record/status"
  printf 'linked from status\n' > "$task/status-proof.bin"
  printf 'keep this image\n' > "$task/proof/capture.png"
  printf 'repository readme\n' > "$task/clone/README.md"
  dd if=/dev/zero of="$task/clone/.git/objects/pack" bs=1048576 count=2 2>/dev/null
  dd if=/dev/zero of="$task/oversized.log" bs=1048576 count=2 2>/dev/null
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  expect_code 0 "$rc" "task-data teardown"
  assert_absent "$task/clone" "finished task clone remains in data"
  assert_absent "$task/oversized.log" "oversized scratch log remains"
  assert_present "$recovery/clone/.git/objects/pack" "original clone is not recoverable"
  assert_present "$recovery/clone/README.md" "clone text was mistaken for evidence"
  assert_present "$task/brief.md" "brief removed"
  assert_present "$task/report.md" "report removed"
  assert_present "$task/review.txt" "review removed"
  assert_present "$task/record/status" "record removed"
  assert_present "$task/status-proof.bin" "status-linked binary removed"
  assert_present "$task/proof/capture.png" "linked binary removed"
  PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" stage \
    "$case_dir/data" "$case_dir/state" task-x1 "$case_dir/project" '' || fail "repeat stage failed"
  assert_present "$recovery/oversized.log" "same task expired its own recovery"
  mkdir -p "$case_dir/data/live-old"
  printf 'live recovery\n' > "$case_dir/data/live-old/blob"
  PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" stage \
    "$case_dir/data" "$case_dir/state" live-old "$case_dir/project" '' || fail "live fixture stage failed"
  fm_write_meta "$case_dir/state/live-old.meta" "kind=ship" "spawn_gen=live-old"
  printf 'new link [log](oversized.log)\n' >> "$task/report.md"
  fm_write_meta "$case_dir/state/task-next.meta" \
    "window=firstmate:fm-task-next" "endpoint_task_id=task-next" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=task-next"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" task-next > "$case_dir/next.out" 2> "$case_dir/next.err" \
    || fail "next teardown failed: $(cat "$case_dir/next.err")"
  assert_absent "$recovery" "next completed task did not expire recovery"
  assert_present "$case_dir/data/live-old/.cleanup-hold/blob" "next teardown expired a live task's recovery"
  assert_present "$task/oversized.log" "newly linked recovery was deleted"
  [ "$(wc -c < "$task/oversized.log" | tr -d ' ')" = 2097152 ] || fail "linked log bytes changed"
  pass "fm-teardown: completed task scratch is held for one cycle and linked evidence stays"
}

test_task_data_large_kept_evidence() {
  local case_dir task recovery rc
  case_dir=$(make_case task-data-large-report)
  task="$case_dir/data/task-x1"
  recovery="$task/.cleanup-hold"
  mkdir -p "$task/proof"
  { head -c 1400000 /dev/zero | tr '\0' 'x'; printf '\nfinal link [capture](proof/capture.png)\n'; } > "$task/report.md"
  printf 'keep this image\n' > "$task/proof/capture.png"
  printf 'scratch\n' > "$task/scratch.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  expect_code 0 "$rc" "teardown with a report over 1 MiB"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "a report over 1 MiB left the backlog item at $(backlog_row_state "$case_dir"): $(cat "$case_dir/err")"
  assert_absent "$case_dir/state/task-x1.backlog-close" "a report over 1 MiB left its pending-close record behind"
  assert_present "$recovery/scratch.bin" "a report over 1 MiB blocked staging"
  assert_present "$task/proof/capture.png" "a link at the end of a large report was not read"
  [ "$(wc -c < "$task/report.md" | tr -d ' ')" = 1400041 ] || fail "large report bytes changed"
  tasks-axi add task-next "next teardown fixture task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-next --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/task-next.meta" \
    "window=firstmate:fm-task-next" "endpoint_task_id=task-next" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=task-next"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" task-next > "$case_dir/next.out" 2> "$case_dir/next.err" \
    || fail "next teardown failed: $(cat "$case_dir/next.err")"
  assert_absent "$recovery" "next completed task did not expire the large-report recovery"
  assert_present "$task/report.md" "large report removed"
  assert_present "$task/proof/capture.png" "large-report link lost at expiry"
  pass "fm-teardown: a kept report over 1 MiB prepares, stages and expires like a small one"
}

test_task_data_oversized_kept_evidence() {
  local case_dir task
  case_dir=$(make_case task-data-oversized-evidence)
  task="$case_dir/data/task-x1"
  mkdir -p "$task/record"
  dd if=/dev/zero of="$task/record/run.log" bs=1048576 count=16 2>/dev/null
  printf 'x' >> "$task/record/run.log"
  printf 'scratch\n' > "$task/scratch.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
    || fail "teardown with kept evidence over 16 MiB failed: $(cat "$case_dir/err")"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "kept evidence over 16 MiB left the backlog item at $(backlog_row_state "$case_dir"): $(cat "$case_dir/err")"
  assert_absent "$case_dir/state/task-x1.backlog-close" "kept evidence over 16 MiB left its pending-close record behind"
  [ "$(cat "$task/scratch.bin")" = scratch ] || fail "kept evidence over 16 MiB moved scratch"
  assert_absent "$task/.cleanup-hold" "kept evidence over 16 MiB staged data"
  assert_grep "record/run.log" "$case_dir/err" "teardown output did not name the unread kept evidence"
  jq -e '.complete == false and (.sources[-1].unread | index("record/run.log") != null)' \
    "$task/record/data-cleanup.json" >/dev/null || fail "cleanup record did not name the unread kept evidence"
  printf 'short log\n' > "$task/record/run.log"
  tasks-axi add task-next "next teardown fixture task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-next --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/task-next.meta" \
    "window=firstmate:fm-task-next" "endpoint_task_id=task-next" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=task-next"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" task-next > "$case_dir/next.out" 2> "$case_dir/next.err" \
    || fail "next teardown failed: $(cat "$case_dir/next.err")"
  assert_present "$task/.cleanup-hold/scratch.bin" "the next teardown did not retry once the kept evidence shrank"
  jq -e '.sources[-1].unread == []' "$task/record/data-cleanup.json" >/dev/null \
    || fail "the retry kept the shrunk evidence as unread"
  pass "fm-teardown: kept evidence over 16 MiB is not read, keeps the folder whole, closes the backlog item and is retried"
}

test_task_data_stage_stops_at_its_limit() {
  local case_dir task record seconds python peak
  case_dir=$(make_case task-data-stage-limit)
  task="$case_dir/data/task-x1"
  record="$task/record/data-cleanup.json"
  mkdir -p "$task/clone"
  python3 - "$task" <<'PY'
import os
import sys

task = sys.argv[1]
line = "Ordinary review notes that name none of the cloned files.\n"
with open(os.path.join(task, "report.md"), "w", encoding="utf-8") as stream:
    stream.write(line * ((16 * 1024 * 1024 - 4096) // len(line)))
    stream.write("Reviewed by Jos\u00e9.\n")
for number in range(200):
    with open(os.path.join(task, "clone", f"scratch-{number:03}.bin"), "w") as stream:
        stream.write("scratch\n")
PY
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  python=$(command -v python3)
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
[ "\${2:-}" = stage ] || exec "$python" "\$@"
date +%s > "$case_dir/stage-start"
"$python" -c 'import resource, subprocess, sys
status = subprocess.call(sys.argv[2:])
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
with open(sys.argv[1], "w") as stream:
    stream.write(str(peak if sys.platform == "darwin" else peak * 1024))
sys.exit(status)' "$case_dir/stage-peak" "$python" "\$@"
status=\$?
date +%s > "$case_dir/stage-end"
exit "\$status"
SH
  chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/python3"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  FM_TEARDOWN_DATA_STAGE_TIMEOUT=2 run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
    || fail "teardown with a large report and many unmatched files failed: $(cat "$case_dir/err")"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "a stage past its limit left the backlog item at $(backlog_row_state "$case_dir")"
  assert_absent "$task/.cleanup-hold" "a stage past its limit moved data"
  [ "$(find "$task/clone" -type f | wc -l | tr -d ' ')" = 200 ] || fail "a stage past its limit moved scratch"
  assert_contains "$(cat "$case_dir/err")" "task data task-x1 retained whole for retry: reference matching passed its 2s stage limit" \
    "teardown did not name the task its stage limit kept whole"
  jq -e '.retained == "reference matching passed its 2s stage limit"' "$record" >/dev/null \
    || fail "the cleanup record did not name the stage limit"
  seconds=$(($(cat "$case_dir/stage-end") - $(cat "$case_dir/stage-start")))
  [ "$seconds" -le 10 ] || fail "the stage ran ${seconds}s with a 2s stage limit"
  peak=$(cat "$case_dir/stage-peak")
  [ "$peak" -le $((1024 * 1024 * 1024)) ] \
    || fail "the stage peaked at $((peak / 1024 / 1024)) MiB matching a 16 MiB report with one accented letter"
  printf 'short report\n' > "$task/report.md"
  run_next_teardown "$case_dir" task-next || fail "next teardown failed: $(cat "$case_dir/task-next.err")"
  assert_present "$task/.cleanup-hold/clone/scratch-000.bin" "the next teardown did not retry the folder its stage limit kept whole"
  jq -e 'has("retained") | not' "$record" >/dev/null || fail "the retry left the stage-limit note in the record"
  pass "fm-teardown: a stage past its limit moves nothing, keeps the folder whole, stays within memory on accented text, closes the backlog item and is retried"
}

test_task_data_slow_expire_releases_locks() {
  local case_dir old young held beads started send_pid teardown_pid rc i seconds
  case_dir=$(make_case task-data-slow-expire)
  old="$case_dir/data/old-done"
  young="$case_dir/data/young-done"
  mkdir -p "$case_dir/project"
  for held in old-done young-done; do
    beads='[]'
    [ "$held" = young-done ] || beads='["tst-slow1", "tst-slow2", "tst-slow3"]'
    mkdir -p "$case_dir/data/$held/record" "$case_dir/data/$held/.cleanup-hold"
    printf 'held scratch\n' > "$case_dir/data/$held/.cleanup-hold/scratch.bin"
    jq -n --arg task "$held" --arg project "$case_dir/project" --arg data "$case_dir/data" --argjson beads "$beads" \
      '{version: 1, task: $task, complete: true, expired: false,
        sources: [{project: $project, pr: "", beads: $beads, backlog: {data: $data, task: null}}]}' \
      > "$case_dir/data/$held/record/data-cleanup.json"
  done
  touch -t 202001010000 "$old/record/data-cleanup.json"
  touch -t 202101010000 "$young/record/data-cleanup.json"
  cat > "$case_dir/fakebin/br" <<SH
#!/usr/bin/env bash
: > "$case_dir/br-started"
exec sleep 12
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/br" "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  fm_write_meta "$case_dir/state/live-y.meta" "window=sess:fm-live-y" "kind=ship" "harness=claude"
  FM_SUPERVISION_ACTOR=main FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=8 run_teardown "$case_dir" \
    > "$case_dir/out" 2> "$case_dir/err" &
  teardown_pid=$!
  for ((i = 0; i < 300; i++)); do
    [ -e "$case_dir/br-started" ] && break
    sleep 0.1
  done
  [ -e "$case_dir/br-started" ] || {
    wait "$teardown_pid"
    fail "teardown never read the other task's bead: $(cat "$case_dir/err")"
  }
  started=$SECONDS
  env PATH="$case_dir/fakebin:$PATH" FM_SUPERVISION_ACTOR=main FM_HOME="$case_dir" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" live-y "steer during expiry" > "$case_dir/send.out" 2> "$case_dir/send.err" &
  send_pid=$!
  for ((i = 0; i < 30; i++)); do
    kill -0 "$send_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$send_pid" 2>/dev/null; then
    wait "$send_pid" "$teardown_pid"
    fail "a concurrent fm-send waited $((SECONDS - started))s on a teardown expiring another task's data"
  fi
  kill -0 "$teardown_pid" 2>/dev/null \
    || fail "teardown finished before the concurrent fm-send, so the send never overlapped its expiry"
  wait "$send_pid" || fail "concurrent fm-send failed: $(cat "$case_dir/send.err")"
  assert_present "$case_dir/state/live-y.inbox/001.msg" "concurrent fm-send recorded no steer"
  wait "$teardown_pid"
  rc=$?
  seconds=$((SECONDS - started))
  expect_code 0 "$rc" "teardown with a slow expiry of another task"
  [ "$seconds" -le 15 ] || fail "teardown spent ${seconds}s expiring another task's data with an 8s budget"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "a slow expiry left the backlog item at $(backlog_row_state "$case_dir")"
  assert_present "$old/.cleanup-hold/scratch.bin" "an unfinished expiry removed held data"
  assert_present "$young/.cleanup-hold/scratch.bin" "teardown kept expiring holds past its budget"
  assert_contains "$(cat "$case_dir/err")" "holds left for a later teardown: young-done" \
    "teardown did not name the hold its budget left unvisited"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/fakebin/br"
  tasks-axi add task-next "next teardown fixture task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-next --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/task-next.meta" \
    "window=firstmate:fm-task-next" "endpoint_task_id=task-next" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=task-next"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5 PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-next > "$case_dir/next.out" 2> "$case_dir/next.err" \
    || fail "next teardown failed: $(cat "$case_dir/next.err")"
  assert_absent "$young/.cleanup-hold" "a slow hold took the next teardown's whole expiry budget"
  assert_present "$old/.cleanup-hold/scratch.bin" "the slow hold expired without its references"
  pass "fm-teardown: a slow expiry of another task's data neither blocks fm-send, outlasts its budget, nor starves other holds"
}

# Write an unexpired cleanup record and one held file for a finished task.
write_pending_hold() { # <case-dir> <task>
  local case_dir=$1 task=$2
  mkdir -p "$case_dir/project" "$case_dir/data/$task/record" "$case_dir/data/$task/.cleanup-hold"
  printf 'held scratch\n' > "$case_dir/data/$task/.cleanup-hold/scratch.bin"
  jq -n --arg task "$task" --arg project "$case_dir/project" --arg data "$case_dir/data" \
    '{version: 1, task: $task, complete: true, expired: false,
      sources: [{project: $project, pr: "", beads: [], backlog: {data: $data, task: null}}]}' \
    > "$case_dir/data/$task/record/data-cleanup.json"
}

test_task_data_expire_skips_expired_receipts() {
  local case_dir
  case_dir=$(make_case task-data-expired-receipts)
  write_pending_hold "$case_dir" zz-live
  touch -t 202101010000 "$case_dir/data/zz-live/record/data-cleanup.json"
  python3 - "$case_dir/data" <<'PY'
import json
import os
import sys

for number in range(3000):
    task = f"done-{number}"
    record = os.path.join(sys.argv[1], task, "record")
    os.makedirs(record)
    path = os.path.join(record, "data-cleanup.json")
    with open(path, "w") as stream:
        json.dump({"version": 1, "task": task, "complete": True, "expired": True,
                   "sources": [{"project": "", "pr": "", "beads": []}]}, stream)
    os.utime(path, (1577836800, 1577836800))
PY
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5 run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
    || fail "teardown with many expired records failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/data/zz-live/.cleanup-hold" \
    "older expired records used up the expiry budget before the one live hold: $(cat "$case_dir/err")"
  pass "fm-teardown: records that already expired never use up the expiry budget"
}

test_task_data_expire_cut_off_hold_moves_back() {
  local case_dir real_python
  case_dir=$(make_case task-data-cut-off-hold)
  write_pending_hold "$case_dir" aa-stuck
  write_pending_hold "$case_dir" bb-fast
  touch -t 202001010000 "$case_dir/data/aa-stuck/record/data-cleanup.json"
  touch -t 202101010000 "$case_dir/data/bb-fast/record/data-cleanup.json"
  real_python=$(command -v python3)
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" expire "*" aa-stuck "*) sleep 6 ;;
esac
exec "$real_python" "\$@"
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/python3" "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
    || fail "teardown with a stuck hold failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/data/bb-fast/.cleanup-hold/scratch.bin" "the stuck hold did not use up the first budget"
  assert_present "$case_dir/data/aa-stuck/.cleanup-hold/scratch.bin" "a hold cut off by the budget lost its data"
  assert_contains "$(cat "$case_dir/err")" "task data aa-stuck expiry stopped after" \
    "teardown did not name the hold it cut off"
  assert_contains "$(cat "$case_dir/err")" "the next teardown that reaches it gives it one full 60s attempt" \
    "teardown did not say what happens to the hold it cut off"
  [ "$(jq -r '.expiry' "$case_dir/data/aa-stuck/record/data-cleanup.json")" = cut-off ] \
    || fail "the cleanup record did not say the budget cut its expiry off"
  tasks-axi add task-next "next teardown fixture task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-next --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/task-next.meta" \
    "window=firstmate:fm-task-next" "endpoint_task_id=task-next" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=task-next"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=5 PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-next > "$case_dir/next.out" 2> "$case_dir/next.err" \
    || fail "next teardown failed: $(cat "$case_dir/next.err")"
  assert_absent "$case_dir/data/bb-fast/.cleanup-hold" \
    "a hold cut off before it recorded anything kept first place and starved the next hold"
  assert_absent "$case_dir/data/aa-stuck/.cleanup-hold" \
    "a hold that needs longer than the budget never expired on a later teardown: $(cat "$case_dir/next.err")"
  jq -e '.expired == true and (has("expiry") | not)' "$case_dir/data/aa-stuck/record/data-cleanup.json" >/dev/null \
    || fail "a completed full attempt left its expiry marker behind"
  pass "fm-teardown: a hold cut off by the budget moves behind the other holds and expires on a later teardown"
}

# Start and tear down one more local-only task in the same home.
run_next_teardown() { # <case-dir> <task>
  local case_dir=$1 task=$2
  tasks-axi add "$task" "next teardown fixture task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start "$task" --file "$case_dir/data/backlog.md" >/dev/null
  fm_write_meta "$case_dir/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" \
    "worktree=$case_dir/missing" "project=$case_dir/project" \
    "kind=ship" "mode=local-only" "spawn_gen=$task"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" "$task" > "$case_dir/$task.out" 2> "$case_dir/$task.err"
}

test_task_data_expire_too_large_hold_skipped() {
  local case_dir real_python record started advertised
  local by_hand=()
  case_dir=$(make_case task-data-too-large-hold)
  write_pending_hold "$case_dir" aa-huge
  record="$case_dir/data/aa-huge/record/data-cleanup.json"
  real_python=$(command -v python3)
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" expire "*" aa-huge "*) echo attempt >> "$case_dir/attempts"; exec sleep 30 ;;
esac
exec "$real_python" "\$@"
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/python3" "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4 run_teardown "$case_dir" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "teardown with a huge hold failed: $(cat "$case_dir/err")"
  [ "$(wc -l < "$case_dir/attempts" | tr -d ' ')" = 1 ] || fail "the first teardown did not try the huge hold once"
  assert_contains "$(cat "$case_dir/err")" "the next teardown that reaches it gives it one full 4s attempt" \
    "the first cut-off did not promise one full attempt"
  [ "$(jq -r '.expiry' "$record")" = cut-off ] || fail "the first cut-off was not recorded"

  started=$SECONDS
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4 run_next_teardown "$case_dir" task-next \
    || fail "second teardown failed: $(cat "$case_dir/task-next.err")"
  [ "$(wc -l < "$case_dir/attempts" | tr -d ' ')" = 2 ] || fail "the second teardown did not try the huge hold again"
  [ $((SECONDS - started)) -ge 4 ] || fail "the full attempt stopped before its 4s cap"
  assert_contains "$(cat "$case_dir/task-next.err")" "task data aa-huge expiry stopped after its one full 4s attempt" \
    "the second cut-off did not name the full attempt"
  assert_contains "$(cat "$case_dir/task-next.err")" "too large to expire automatically, so later teardowns skip it" \
    "the second cut-off did not say later teardowns skip the hold"
  [ "$(jq -r '.expiry' "$record")" = too-large ] || fail "the record did not mark the hold too large"

  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=2 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=4 run_next_teardown "$case_dir" task-last \
    || fail "third teardown failed: $(cat "$case_dir/task-last.err")"
  [ "$(wc -l < "$case_dir/attempts" | tr -d ' ')" = 2 ] || fail "a hold marked too large was tried again"
  assert_contains "$(cat "$case_dir/task-last.err")" \
    "holds too large to expire automatically, skipped and kept for expiry by hand: aa-huge" \
    "a later teardown did not name the hold it skipped"
  assert_present "$case_dir/data/aa-huge/.cleanup-hold/scratch.bin" "a hold too large to expire lost its data"
  [ "$(jq -r '.expiry' "$record")" = too-large ] || fail "skipping the hold cleared its too-large mark"

  advertised=$(sed -n 's/.*expire it by hand with //p' "$case_dir/task-next.err")
  read -r -a by_hand <<< "$advertised"
  [ "${#by_hand[@]}" -ge 5 ] || fail "the too-large warning advertised no by-hand command: $advertised"
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" expire "*" aa-huge "*)
    if [ -d "$case_dir/state/.meta-aa-huge.lock" ]; then echo held; else echo free; fi >> "$case_dir/lock-seen" ;;
esac
exec "$real_python" "\$@"
SH
  mkdir "$case_dir/state/.meta-aa-huge.lock"
  printf '%s\n' "$$" > "$case_dir/state/.meta-aa-huge.lock/pid"
  if PATH="$case_dir/fakebin:$PATH" "${by_hand[@]}" > "$case_dir/by-hand.out" 2> "$case_dir/by-hand.err"; then
    fail "the by-hand command expired a hold whose task lock another process holds"
  fi
  assert_absent "$case_dir/lock-seen" "the by-hand command ran expiry while another process held the task lock"
  rm -f -- "$case_dir/state/.meta-aa-huge.lock/pid"
  rmdir -- "$case_dir/state/.meta-aa-huge.lock"
  PATH="$case_dir/fakebin:$PATH" "${by_hand[@]}" > "$case_dir/by-hand.out" 2> "$case_dir/by-hand.err" \
    || fail "the advertised by-hand command failed: $(cat "$case_dir/by-hand.err")"
  [ "$(cat "$case_dir/lock-seen")" = held ] || fail "the by-hand command expired the hold without its task lock"
  assert_absent "$case_dir/state/.meta-aa-huge.lock" "the by-hand command left the task lock behind"
  assert_absent "$case_dir/data/aa-huge/.cleanup-hold" "the by-hand command did not expire the hold"
  jq -e '.expired == true and (has("expiry") | not)' "$record" >/dev/null \
    || fail "the by-hand expiry left the hold marked"
  pass "fm-teardown: a hold that outlasts the budget and its one full attempt is skipped, named, and expired by hand under its lock"
}

test_task_data_full_attempt_uses_its_own_limit() {
  local case_dir real_python record started marked
  case_dir=$(make_case task-data-full-attempt-limit)
  write_pending_hold "$case_dir" aa-slow
  record="$case_dir/data/aa-slow/record/data-cleanup.json"
  jq '.expiry = "cut-off"' "$record" > "$record.next" && mv "$record.next" "$record"
  real_python=$(command -v python3)
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" expire "*" aa-slow "*) date +%s > "$case_dir/started"; exec sleep 30 ;;
  *" mark "*" aa-slow "*) date +%s > "$case_dir/marked" ;;
esac
exec "$real_python" "\$@"
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/python3" "$case_dir/fakebin/dcg"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  FM_TEARDOWN_DATA_EXPIRE_TIMEOUT=3 FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT=1 run_teardown "$case_dir" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "teardown with a short full attempt failed: $(cat "$case_dir/err")"
  started=$(cat "$case_dir/started") marked=$(cat "$case_dir/marked")
  [ $((marked - started)) -le 2 ] || fail "the 1s full attempt ran $((marked - started))s under a 3s budget"
  assert_contains "$(cat "$case_dir/err")" "task data aa-slow expiry stopped after its one full 1s attempt" \
    "the full-attempt warning did not report the configured 1s"
  [ "$(jq -r '.expiry' "$record")" = too-large ] || fail "the cut-off full attempt did not mark the hold too large"
  pass "fm-teardown: the one full attempt lasts FM_TEARDOWN_DATA_FULL_EXPIRE_TIMEOUT even under a longer budget"
}

test_task_data_refusals() {
  local case_dir task rc
  case_dir=$(make_case task-data-refusals)
  task="$case_dir/data/task-x1"
  mkdir -p "$task/scratch" "$case_dir/outside"
  printf 'original\n' > "$task/scratch/blob"
  printf 'outside\n' > "$case_dir/outside/blob"
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" work.txt unlanded
  if run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err"; then rc=0; else rc=$?; fi
  expect_code 1 "$rc" "unlanded task teardown must refuse"
  assert_present "$task/scratch/blob" "refused teardown moved task data"
  if python3 "$ROOT/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
      task-x1 "$case_dir/project" '' > "$case_dir/helper.out" 2> "$case_dir/helper.err"; then
    fail "helper accepted a live task"
  fi
  assert_present "$task/scratch/blob" "live task scratch changed"
  if python3 "$ROOT/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
      ../outside "$case_dir/project" '' > "$case_dir/helper.out" 2> "$case_dir/helper.err"; then
    fail "helper accepted path traversal"
  fi
  ln -s "$case_dir/outside" "$case_dir/data/escaped"
  if python3 "$ROOT/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
      escaped "$case_dir/project" '' > "$case_dir/helper.out" 2> "$case_dir/helper.err"; then
    fail "helper accepted a symlink outside data"
  fi
  [ "$(cat "$case_dir/outside/blob")" = outside ] || fail "outside file changed"
  mkdir -p "$case_dir/data/unsafe-record"
  ln -s "$case_dir/outside" "$case_dir/data/unsafe-record/record"
  printf 'scratch\n' > "$case_dir/data/unsafe-record/blob"
  if python3 "$ROOT/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
      unsafe-record "$case_dir/project" '' > "$case_dir/helper.out" 2> "$case_dir/helper.err"; then
    fail "helper accepted a record directory outside the task"
  fi
  assert_present "$case_dir/data/unsafe-record/blob" "unsafe record moved scratch"
  pass "fm-teardown: live data and paths outside the task directory are untouched"
}

test_task_data_references_and_guard() {
  local case_dir task helper real_tasks
  real_tasks=$(command -v tasks-axi)
  case_dir=$(make_case task-data-refs)
  task="$case_dir/data/finished"
  helper="$ROOT/bin/fm-task-data.py"
  mkdir -p "$task/scratch"
  printf 'Bead demo-123\n' > "$task/brief.md"
  printf 'PR image\n' > "$task/scratch/pr image.png"
  printf 'bead image\n' > "$task/scratch/bead.png"
  printf 'unlinked\n' > "$task/scratch/discard.bin"
  fm_test_tasks_toml "$case_dir/.tasks.toml"
  seed_backlog_in_flight "$case_dir"
  tasks-axi add finished 'finished task' --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi add pending 'pending task' --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi add demo-123 'linked evidence' --body '[image](scratch/bead.png)' \
    --file "$case_dir/data/backlog.md" >/dev/null
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: [image](scratch/pr%%20image.png)\n'
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"fixture denial"}}\n'
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/dcg"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
    finished "$case_dir/project" https://github.com/test/repo/pull/1 || fail "reference retention failed"
  assert_present "$task/scratch/pr image.png" "PR-linked file moved"
  assert_present "$task/scratch/bead.png" "bead-linked file moved"
  if PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" \
      finished > "$case_dir/out" 2> "$case_dir/err"; then
    fail "dcg denial was bypassed"
  fi
  assert_present "$task/.cleanup-hold/scratch/discard.bin" "dcg-denied file was deleted"
  assert_grep 'dcg refused' "$case_dir/err" "denial diagnostic missing"
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  if PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" \
      finished > "$case_dir/out" 2> "$case_dir/err"; then
    fail "unreadable bead allowed deletion"
  fi
  assert_present "$task/.cleanup-hold/scratch/discard.bin" "unreadable references lost recovery"
  mkdir -p "$case_dir/data/pending"
  printf 'Bead demo-123\n' > "$case_dir/data/pending/brief.md"
  printf 'scratch\n' > "$case_dir/data/pending/blob"
  if PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
      pending "$case_dir/project" '' > "$case_dir/out" 2> "$case_dir/err"; then
    fail "unreadable bead allowed initial staging"
  fi
  assert_present "$case_dir/data/pending/blob" "unreadable bead moved scratch"
  assert_present "$case_dir/data/pending/record/data-cleanup.json" "failed staging has no retry record"
  "$real_tasks" update demo-123 --body 'no linked files' --file "$case_dir/data/backlog.md" >/dev/null
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
exec '$real_tasks' "\$@"
SH
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" pending \
    || fail "pending cleanup did not resume"
  assert_present "$case_dir/data/pending/.cleanup-hold/blob" "resumed cleanup skipped its recovery cycle"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" pending \
    || fail "resumed cleanup did not expire"
  assert_absent "$case_dir/data/pending/.cleanup-hold" "resumed recovery remains"
  pass "fm-teardown: PR and bead links survive, and dcg denial or unreadable references retain recovery"
}

write_task_data_beads_fixture() {
  local case_dir=$1
  mkdir -p "$case_dir/graph/.beads" "$case_dir/project/.beads"
  cat > "$case_dir/graph/.beads/rows.json" <<'JSON'
{
  "proof-owner": {"status": "open", "description": "[capture](proof.png) [evidence directory](artifacts/)"},
  "proof-related": {"status": "open", "description": "[named capture](named.png)"}
}
JSON
  cat > "$case_dir/project/.beads/rows.json" <<'JSON'
{"proof-owner": {"status": "open", "description": "Unrelated project task without attachments"}}
JSON
  cat > "$case_dir/.tasks.toml" <<'TOML'
backend = "beads"

[beads]
path = "graph/.beads"
prefix = "proof"
TOML
  cat > "$case_dir/project/.tasks.toml" <<'TOML'
backend = "beads"

[beads]
path = ".beads"
prefix = "proof"
TOML
  cat > "$case_dir/fakebin/tasks-axi" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import tomllib

if os.environ.get("FM_TEST_BACKLOG_DOWN") == "1":
    sys.exit(1)
config = tomllib.loads(Path(".tasks.toml").read_text())
assert config["backend"] == "beads"
assert "TASKS_AXI_FILE" not in os.environ
assert "--file" not in sys.argv
graph = Path(config["beads"]["path"]) / "rows.json"
rows = json.loads(graph.read_text())
verb, task = sys.argv[1:3]
if task not in rows:
    print("code: NOT_FOUND")
    sys.exit(1)
row = rows[task]
if verb == "done":
    row["status"] = "closed"
elif verb == "update":
    row["description"] = sys.argv[sys.argv.index("--body") + 1]
else:
    assert verb == "show"
if verb != "show":
    graph.write_text(json.dumps(rows) + "\n")
state = "done" if row["status"] == "closed" else "queued"
print(f"task:\n  id: {task}\n  state: {state}\n  held: no\n  blocked: no")
if "--full" in sys.argv:
    print("body: " + json.dumps(row.get("description", "")))
PY
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/tasks-axi" "$case_dir/fakebin/dcg"
}

test_task_data_bead_backlog_sources() {
  local code_root=${1:-$ROOT} case_dir task portable_path id='proof-owner' related='proof-related'
  case_dir=$(make_case task-data-bead-backlog)
  portable_path=$(fm_test_base_path_sans "$PATH" br)
  if PATH="$portable_path" command -v br >/dev/null 2>&1; then
    fail "portable Beads fixture still exposes br"
  fi
  write_task_data_beads_fixture "$case_dir"
  task="$case_dir/data/$id"
  mkdir -p "$task/artifacts" "$task/later-artifacts" "$case_dir/outside"
  printf 'plain cleanup instructions\n' > "$task/brief.md"
  printf 'owning Bead evidence\n' > "$task/proof.png"
  printf 'later Bead evidence\n' > "$task/later.png"
  printf 'scratch\n' > "$task/discard.bin"
  printf '\000owning directory evidence\377' > "$task/artifacts/frame.bin"
  printf '\000later directory evidence\377' > "$task/later-artifacts/frame.bin"
  printf '\000owned directory backing\377' > "$task/backing.bin"
  printf '\000held directory backing\377' > "$task/later-backing.bin"
  printf 'outside directory target\n' > "$case_dir/outside/keep.bin"
  ln -s "$task/backing.bin" "$task/artifacts/member.bin"
  ln -s "$task/later-backing.bin" "$task/later-artifacts/member.bin"
  ln -s "$case_dir/outside/keep.bin" "$task/artifacts/external.bin"
  fm_write_meta "$case_dir/state/$id.meta" "project=$case_dir/project" \
    'kind=ship' 'mode=local-only' "spawn_gen=bead-$id"
  cat > "$case_dir/retire.sh" <<'SH'
#!/usr/bin/env bash
set -eu
root=$1 case_dir=$2 id=$3 action=$4
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-tasks-axi-lib.sh"
. "$root/bin/fm-backlog-transition-lib.sh"
state="$case_dir/state" data="$case_dir/data"
lock=$(fm_meta_lock_path "$state/$id.meta")
fm_lock_acquire_wait "$lock"
trap 'fm_lock_release "$lock"' EXIT
if [ "$action" = retire ]; then
  fm_backlog_close_marker_write "$state" "$id" "$data" "bead-$id" --note 'local main'
  fm_backlog_atomic_transition retire "$state/$id.meta" "$data" "$id" "$state"
else
  fm_backlog_close_marker_replay "$state" "$state/$id.backlog-close" "$data"
fi
SH
  FM_HOME="$case_dir" PATH="$case_dir/fakebin:$portable_path" \
    bash "$case_dir/retire.sh" "$code_root" "$case_dir" "$id" retire \
    > "$case_dir/retire.out" 2> "$case_dir/retire.err" || fail "Bead retirement failed: $(cat "$case_dir/retire.err")"
  assert_absent "$case_dir/state/$id.meta" "Bead retirement did not remove metadata"
  assert_present "$case_dir/state/$id.backlog-close" "interrupted Bead retirement lost replay"
  FM_HOME="$case_dir" PATH="$case_dir/fakebin:$portable_path" \
    bash "$case_dir/retire.sh" "$code_root" "$case_dir" "$id" replay \
    > "$case_dir/replay.out" 2> "$case_dir/replay.err" || fail "Bead replay failed: $(cat "$case_dir/replay.err")"
  assert_absent "$case_dir/state/$id.backlog-close" "Bead replay left pending completion"
  BEADS_DIR="$case_dir/project/.beads" \
    TASKS_AXI_FILE="$case_dir/project/backlog.md" PATH="$case_dir/fakebin:$portable_path" \
    python3 "$code_root/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
      "$id" "$case_dir/project" '' || fail "owning Bead staging failed"
  [ "$(cat "$task/proof.png")" = 'owning Bead evidence' ] || fail "owning Bead-only link was staged"
  assert_present "$task/artifacts/frame.bin" "owning Bead directory contents were staged"
  cmp "$task/artifacts/member.bin" "$task/backing.bin" || fail "owning Bead directory symlink lost its target"
  assert_present "$task/.cleanup-hold/later-artifacts/frame.bin" "unlinked Bead directory did not stage"
  assert_present "$task/.cleanup-hold/later-backing.bin" "unlinked Bead directory backing did not stage"
  assert_present "$task/.cleanup-hold/later.png" "unlinked later evidence did not stage"
  assert_present "$task/.cleanup-hold/discard.bin" "unlinked Bead scratch did not stage"
  jq -e --arg data "$case_dir/data" --arg id "$id" \
    '.sources | any(.beads == [] and .backlog.data == $data and .backlog.task == $id)' \
    "$task/record/data-cleanup.json" >/dev/null || fail "cleanup lost the owning backlog identity"
  (cd "$case_dir" && PATH="$case_dir/fakebin:$portable_path" tasks-axi update "$id" \
    --body '[capture](proof.png) [later capture](later.png) [evidence directory](artifacts/) [later directory](later-artifacts/)') > "$case_dir/update.log" 2>&1 \
    || fail "owning Bead update failed"
  if FM_TEST_BACKLOG_DOWN=1 PATH="$case_dir/fakebin:$portable_path" \
      python3 "$code_root/bin/fm-task-data.py" expire "$case_dir/data" "$case_dir/state" "$id" \
      > "$case_dir/down.out" 2> "$case_dir/down.err"; then
    fail "unavailable owning backend allowed expiry"
  fi
  assert_present "$task/.cleanup-hold/later.png" "unavailable backend lost recoverable evidence"
  assert_present "$task/.cleanup-hold/discard.bin" "unavailable backend deleted scratch"
  assert_present "$task/.cleanup-hold/later-artifacts/frame.bin" "unavailable backend deleted held directory evidence"
  BEADS_DIR="$case_dir/project/.beads" \
    TASKS_AXI_FILE="$case_dir/project/backlog.md" PATH="$case_dir/fakebin:$portable_path" \
    python3 "$code_root/bin/fm-task-data.py" expire "$case_dir/data" "$case_dir/state" "$id" \
    || fail "owning Bead expiry failed"
  [ "$(cat "$task/proof.png")" = 'owning Bead evidence' ] || fail "expiry deleted owning Bead evidence"
  [ "$(cat "$task/later.png")" = 'later Bead evidence' ] || fail "expiry did not refresh the owning Bead's links"
  assert_present "$task/artifacts/frame.bin" "expiry deleted owning Bead directory evidence"
  assert_present "$task/later-artifacts/frame.bin" "expiry did not restore newly linked owning Bead directory evidence"
  cmp "$task/later-artifacts/member.bin" "$task/later-backing.bin" || fail "held Bead directory lost its backing file"
  [ "$(cat "$task/artifacts/external.bin")" = 'outside directory target' ] || fail "owning Bead directory changed external evidence"
  assert_absent "$task/.cleanup-hold" "owning Bead recovery remains"
  printf 'Bead %s\n' "$related" >> "$task/brief.md"
  printf 'named Bead evidence\n' > "$task/named.png"
  printf 'next scratch\n' > "$task/next.bin"
  if FM_TEST_BACKLOG_DOWN=1 PATH="$case_dir/fakebin:$portable_path" \
      python3 "$code_root/bin/fm-task-data.py" stage "$case_dir/data" "$case_dir/state" \
        "$id" "$case_dir/project" '' > "$case_dir/down-stage.out" 2> "$case_dir/down-stage.err"; then
    fail "unavailable owning backend allowed staging"
  fi
  assert_present "$task/next.bin" "unavailable backend moved original scratch"
  assert_present "$task/named.png" "unavailable backend moved named evidence"
  BEADS_DIR="$case_dir/project/.beads" PATH="$case_dir/fakebin:$portable_path" \
    python3 "$code_root/bin/fm-task-data.py" expire "$case_dir/data" "$case_dir/state" "$id" \
    || fail "unavailable-backend recovery did not resume"
  [ "$(cat "$task/named.png")" = 'named Bead evidence' ] || fail "named Bead used the project default graph"
  assert_present "$task/.cleanup-hold/next.bin" "resumed Bead cleanup omitted one-cycle recovery"
  PATH="$case_dir/fakebin:$portable_path" \
    python3 "$code_root/bin/fm-task-data.py" expire "$case_dir/data" "$case_dir/state" "$id" \
    || fail "resumed Bead cleanup did not expire"
  [ "$(cat "$task/proof.png")" = 'owning Bead evidence' ] || fail "retry lost owning Bead evidence"
  [ "$(cat "$task/named.png")" = 'named Bead evidence' ] || fail "retry lost named Bead evidence"
  assert_absent "$task/.cleanup-hold" "resumed Bead recovery remains"
  pass "fm-teardown: owning and named Bead links use the configured graph across retirement, replay, staging, expiry and unavailable-backend retries"
}

test_task_data_named_bead_resolution() {
  local case_dir task bead variant expected
  for variant in agent-config gsp project fallback unread; do
    [ -z "${FM_TASK_DATA_REF_CASE:-}" ] || [ "$variant" = "$FM_TASK_DATA_REF_CASE" ] || continue
    case_dir=$(make_case "task-data-named-$variant")
    task="$case_dir/data/task-x1"
    mkdir -p "$task" "$case_dir/home/.agent-config" "$case_dir/home/dev/gsp-beads"
    case "$variant" in
      agent-config) bead=.agent-config-ojg69; expected="$case_dir/home/.agent-config" ;;
      gsp) bead=gsp-kstok; expected="$case_dir/home/dev/gsp-beads" ;;
      *) bead=proof-related; expected="$case_dir/project" ;;
    esac
    printf 'Bead %s\n' "$bead" > "$task/brief.md"
    printf 'linked evidence\n' > "$task/proof.png"
    printf 'scratch\n' > "$task/discard.bin"
    write_meta "$case_dir" local-only ship
    seed_backlog_in_flight "$case_dir"
    fm_test_tasks_toml "$case_dir/.tasks.toml"
    if [ "$variant" = fallback ]; then
      tasks-axi add "$bead" 'named evidence' --body '[capture](proof.png)' \
        --file "$case_dir/data/backlog.md" >/dev/null
    fi
    cat > "$case_dir/fakebin/br" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

assert not any(name in os.environ for name in ("BEADS_DIR", "BEADS_DB", "BR_DB"))
assert sys.argv[1] == "show"
assert sys.argv[2] == os.environ["REF_BEAD"]
assert Path.cwd() == Path(os.environ["REF_OWNER"])
if os.environ["REF_CASE"] in ("fallback", "unread") and not Path("readable").exists():
    print("not found", file=sys.stderr)
    sys.exit(1)
print(json.dumps([{"id": sys.argv[2], "description": "[capture](proof.png)"}]))
PY
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/br" "$case_dir/fakebin/dcg"
    HOME="$case_dir/home" REF_BEAD="$bead" REF_OWNER="$expected" REF_CASE="$variant" \
      BEADS_DIR=/wrong BEADS_DB=/wrong BR_DB=/wrong \
      run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
      || fail "$variant named-bead teardown failed: $(cat "$case_dir/err")"
    [ "$(backlog_row_state "$case_dir")" = 'done' ] || fail "$variant backlog close pending"
    assert_absent "$case_dir/state/task-x1.meta" "$variant metadata not retired"
    assert_absent "$case_dir/state/task-x1.backlog-close" "$variant pending close remains"
    [ "$(cat "$task/proof.png")" = 'linked evidence' ] || fail "$variant bead evidence moved"
    if [ "$variant" = unread ]; then
      [ "$(cat "$task/discard.bin")" = scratch ] || fail "unread bead moved scratch"
      assert_absent "$task/.cleanup-hold" "unread bead staged data"
      assert_grep "$bead" "$case_dir/err" "unread bead missing from teardown warning"
      jq -e --arg bead "$bead" '.complete == false and .sources[0].unread == [$bead]' \
        "$task/record/data-cleanup.json" >/dev/null || fail "unread bead missing from cleanup record"
      printf 'available\n' > "$case_dir/project/readable"
      HOME="$case_dir/home" REF_BEAD="$bead" REF_OWNER="$expected" REF_CASE="$variant" \
        PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" expire \
        "$case_dir/data" "$case_dir/state" task-x1 || fail "unread bead retry failed"
      jq -e '.sources[0].unread == []' "$task/record/data-cleanup.json" >/dev/null \
        || fail "readable retry kept stale unread reference"
    fi
    assert_present "$task/.cleanup-hold/discard.bin" "$variant scratch missed recovery cycle"
    assert_present "$task/proof.png" "$variant retry lost evidence"
    pass "fm-teardown: $variant named bead resolves safely and backlog closes"
  done
}

test_task_data_reused_id() {
  local case_dir task helper
  case_dir=$(make_case task-data-reuse)
  task="$case_dir/data/reused"
  helper="$ROOT/bin/fm-task-data.py"
  mkdir -p "$task"
  printf 'old scratch\n' > "$task/old.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: no linked files\n'
SH
  chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
    reused "$case_dir/project" https://github.com/test/repo/pull/1 || fail "initial staging failed"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$3" in
  1) printf 'body: [original](old.bin)\n' ;;
  *) printf 'body: no linked files\n' ;;
esac
SH
  printf 'new scratch\n' > "$task/new.bin"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
    reused "$case_dir/project" https://github.com/test/repo/pull/2 || fail "reused staging failed"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" \
    reused || fail "reused expiry failed"
  [ "$(cat "$task/old.bin")" = 'old scratch' ] || fail "reuse lost the earlier PR's linked file"
  assert_absent "$task/new.bin" "unlinked new scratch remains"
  assert_absent "$task/.cleanup-hold" "reused recovery did not expire"
  pass "fm-teardown: reusing a completed id keeps its earlier recovery's reference sources"
}

test_task_data_expired_sources() {
  local case_dir task helper variant
  helper="$ROOT/bin/fm-task-data.py"
  for variant in held empty; do
    case_dir=$(make_case "task-data-expired-$variant")
    task="$case_dir/data/reused"
    mkdir -p "$task"
    printf 'Bead original-123\n' > "$task/brief.md"
    printf 'PR proof\n' > "$task/proof.png"
    printf 'bead proof\n' > "$task/bead-proof.png"
    fm_test_tasks_toml "$case_dir/.tasks.toml"
    seed_backlog_in_flight "$case_dir"
    tasks-axi add reused 'reused task' --file "$case_dir/data/backlog.md" >/dev/null
    tasks-axi add original-123 'original evidence' --body '[proof](bead-proof.png)' \
      --file "$case_dir/data/backlog.md" >/dev/null
    [ "$variant" != held ] || printf 'scratch\n' > "$task/old.bin"
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$3" in
  1) printf 'body: [proof](proof.png)\n' ;;
  *) printf 'body: no attachments\n' ;;
esac
SH
    chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
      reused "$case_dir/project" https://github.com/test/repo/pull/1 || fail "first $variant stage failed"
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" reused \
      || fail "first $variant expiry failed"
    jq -e '.expired == true' "$task/record/data-cleanup.json" >/dev/null || fail "$variant did not expire"
    printf 'replacement brief\n' > "$task/brief.md"
    printf 'new scratch\n' > "$task/new.bin"
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
      reused "$case_dir/project" https://github.com/test/repo/pull/2 || fail "second $variant stage failed"
    [ "$(cat "$task/proof.png")" = 'PR proof' ] || fail "$variant reset lost the earlier PR proof"
    [ "$(cat "$task/bead-proof.png")" = 'bead proof' ] || fail "$variant reset lost the earlier bead proof"
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" reused \
      || fail "second $variant expiry failed"
    assert_present "$task/proof.png" "later expiry deleted the earlier PR proof"
    assert_present "$task/bead-proof.png" "later expiry deleted the earlier bead proof"
    jq -e '.sources | length == 2' "$task/record/data-cleanup.json" >/dev/null || fail "reference sources were reset"
  done
  pass "fm-teardown: both expiry transitions preserve earlier PR and bead sources"
}

test_task_data_symlink_targets() {
  local case_dir task action helper=${1:-$ROOT/bin/fm-task-data.py} args=()
  case_dir=$(make_case task-data-symlinks)
  task="$case_dir/data/finished"
  mkdir -p "$task/backing/next" "$task/held-backing/next" "$task/frames" "$task/late-frames" \
    "$task/captures/subdir" "$task/saved-captures/subdir" "$case_dir/outside/subdir"
  printf 'capture\n' > "$task/captures/capture.bin"
  printf 'frame\n' > "$task/frames/frame.bin"
  printf 'later capture\n' > "$task/later.bin"
  printf 'scratch\n' > "$task/discard.bin"
  printf 'ordered capture\n' > "$task/captures/proof.bin"
  printf 'saved ordered capture\n' > "$task/saved-captures/proof.bin"
  printf 'unrelated capture\n' > "$task/captures/discard.bin"
  printf 'outside\n' > "$case_dir/outside/outside.bin"
  printf 'directory member capture\n' > "$task/backing/capture.bin"
  printf 'nested directory capture\n' > "$task/deep.bin"
  printf 'held directory capture\n' > "$task/held-backing/capture.bin"
  printf 'held nested capture\n' > "$task/held-deep.bin"
  printf 'unrelated backing scratch\n' > "$task/backing/discard.bin"
  ln -s captures/capture.bin "$task/alias.bin"
  ln -s alias.bin "$task/latest.png"
  ln -s frames "$task/frames.png"
  ln -s later.bin "$task/saved.png"
  ln -s captures/subdir "$task/component-alias.bin"
  ln -s component-alias.bin/../proof.bin "$task/component.png"
  ln -s saved-captures/subdir "$task/saved-alias.bin"
  ln -s saved-alias.bin/../proof.bin "$task/saved-component.png"
  ln -s "$case_dir/outside/subdir" "$task/outside-alias.bin"
  ln -s outside-alias.bin/../outside.bin "$task/escape.png"
  ln -s "$task/backing/capture.bin" "$task/frames/member.bin"
  ln -s "$task/backing/next" "$task/frames/directory.bin"
  ln -s "$task/deep.bin" "$task/backing/next/nested.bin"
  ln -s "$case_dir/outside/outside.bin" "$task/frames/external.bin"
  ln -s "$task/frames" "$task/frames/recursive.bin"
  ln -s late-frames "$task/saved-frames.png"
  ln -s "$task/held-backing/capture.bin" "$task/late-frames/member.bin"
  ln -s "$task/held-backing/next" "$task/late-frames/directory.bin"
  ln -s "$task/held-deep.bin" "$task/held-backing/next/nested.bin"
  ln -s "$case_dir/outside/outside.bin" "$task/late-frames/external.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: [latest](latest.png) [frames](frames.png) [components](component.png) [outside](escape.png)\n'
SH
  chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage "$case_dir/data" "$case_dir/state" \
    finished "$case_dir/project" https://github.com/test/repo/pull/1 || fail "symlink stage failed"
  [ "$(cat "$task/latest.png")" = capture ] || fail "linked image symlink lost its target"
  [ -L "$task/alias.bin" ] || fail "intermediate symlink was staged"
  [ "$(cat "$task/frames.png/frame.bin")" = frame ] || fail "linked directory symlink lost its contents"
  [ "$(cat "$task/frames.png/member.bin")" = 'directory member capture' ] \
    || fail "retained directory member lost its backing file during staging"
  [ "$(cat "$task/frames.png/directory.bin/nested.bin")" = 'nested directory capture' ] \
    || fail "transitive directory member lost its backing file during staging"
  [ "$(cat "$task/frames.png/recursive.bin/member.bin")" = 'directory member capture' ] \
    || fail "recursive directory alias did not retain its backing file"
  [ "$(cat "$task/frames.png/external.bin")" = outside ] || fail "retained directory link changed an external target"
  assert_present "$task/.cleanup-hold/backing/discard.bin" "transitive retention kept unrelated backing scratch"
  assert_present "$task/.cleanup-hold/held-backing/capture.bin" "unlinked directory backing did not stage"
  [ -L "$task/.cleanup-hold/late-frames/member.bin" ] || fail "unlinked directory member did not stage"
  [ "$(cat "$task/component.png")" = 'ordered capture' ] || fail "symlink followed by .. lost its target during staging"
  [ -d "$task/captures/subdir" ] || fail "staging removed an empty traversal directory"
  assert_present "$task/.cleanup-hold/captures/discard.bin" "traversal retained unrelated directory contents"
  assert_present "$task/.cleanup-hold/saved-captures/proof.bin" "unlinked ordered target did not stage"
  [ -L "$task/.cleanup-hold/saved-alias.bin" ] || fail "unlinked ordered alias did not stage"
  assert_absent "$task/saved-captures" "unlinked empty traversal directory did not stage"
  [ "$(cat "$task/escape.png")" = outside ] || fail "staging changed an escaped link target"
  assert_present "$task/.cleanup-hold/later.bin" "unlinked target did not stage"
  [ -L "$task/.cleanup-hold/saved.png" ] || fail "unlinked symlink did not stage"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: [latest](latest.png) [frames](frames.png) [components](component.png) [outside](escape.png) [saved](saved.png) [saved components](saved-component.png) [saved frames](saved-frames.png)\n'
SH
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire "$case_dir/data" "$case_dir/state" finished \
    || fail "symlink expiry failed"
  [ "$(cat "$task/saved.png")" = 'later capture' ] || fail "newly linked held symlink lost its held target"
  [ "$(cat "$task/latest.png")" = capture ] || fail "expiry broke retained symlink chain"
  [ "$(cat "$task/frames.png/member.bin")" = 'directory member capture' ] || fail "expiry deleted a retained directory's backing file"
  [ "$(cat "$task/frames.png/directory.bin/nested.bin")" = 'nested directory capture' ] || fail "expiry deleted a transitive directory target"
  [ "$(cat "$task/saved-frames.png/member.bin")" = 'held directory capture' ] || fail "expiry did not restore a held directory's backing file"
  [ "$(cat "$task/saved-frames.png/directory.bin/nested.bin")" = 'held nested capture' ] || fail "expiry did not restore transitive held directory targets"
  [ "$(cat "$task/saved-frames.png/external.bin")" = outside ] || fail "held directory recovery changed an external target"
  [ "$(cat "$case_dir/outside/outside.bin")" = outside ] || fail "transitive cleanup escaped the task directory"
  [ "$(cat "$task/component.png")" = 'ordered capture' ] || fail "expiry broke symlink followed by .."
  [ "$(cat "$task/saved-component.png")" = 'saved ordered capture' ] || fail "expiry did not restore ordered held targets and traversal directories"
  [ -L "$task/saved-alias.bin" ] || fail "expiry did not restore a required intermediate alias"
  [ -d "$task/saved-captures/subdir" ] || fail "expiry did not restore an empty traversal directory"
  [ "$(cat "$task/escape.png")" = outside ] || fail "expiry changed an escaped link target"
  assert_absent "$task/captures/discard.bin" "ordered lookup retained unrelated scratch"
  assert_absent "$task/.cleanup-hold" "symlink recovery did not expire"
  ln -s "$task/cycle.bin" "$task/frames/cycle.bin"
  ln -s "$task/frames/cycle.bin" "$task/cycle.bin"
  printf 'cycle scratch\n' > "$task/cycle-scratch.bin"
  for action in stage expire; do
    args=()
    [ "$action" != stage ] || args=("$case_dir/project" https://github.com/test/repo/pull/1)
    if PATH="$case_dir/fakebin:$PATH" python3 "$helper" "$action" "$case_dir/data" "$case_dir/state" \
        finished "${args[@]+"${args[@]}"}" > "$case_dir/cycle.out" 2> "$case_dir/cycle.err"; then
      fail "$action accepted a cycle below a retained directory"
    fi
    assert_grep 'cyclic evidence symlink' "$case_dir/cycle.err" "$action lost cycle protection"
    [ "$(cat "$task/cycle-scratch.bin")" = 'cycle scratch' ] || fail "$action moved scratch despite a retained cycle"
    [ "$(cat "$task/frames.png/member.bin")" = 'directory member capture' ] || fail "$action changed evidence despite a retained cycle"
  done
  pass "fm-teardown: retained directory links preserve transitive and held targets, component order, escapes and cycle safety"
}

test_task_data_linked_directories() {
  local helper=${1:-$ROOT/bin/fm-task-data.py} case_dir
  case_dir=$(make_case task-data-linked-directories)
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_REFERENCE_FILE"
SH
  chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
  FM_TEST_REFERENCE_FILE="$case_dir/references" PATH="$case_dir/fakebin:$PATH" \
    python3 - "$case_dir" "$helper" <<'PY' || fail "linked directory regression failed"
from pathlib import Path
import subprocess
import sys

case, helper = Path(sys.argv[1]), sys.argv[2]
external = case / "outside" / "keep.bin"
external.parent.mkdir()
external.write_bytes(b"outside\x00\xff")
for variant in ("local", "pr"):
    task = case / "data" / variant
    expected = {
        "artifacts/frame.bin": b"frame\x00\xff",
        "artifacts/nested/fragment.bin": b"fragment\x00\xff",
        "backing.bin": b"directory backing\x00\xff",
        "pieces/deep.bin": b"nested backing\x00\xff",
        "scratch-only/evidence.bin": b"single linked file\x00\xff",
        "saved-artifacts/frame.bin": b"held frame\x00\xff",
        "saved-backing.bin": b"held backing\x00\xff",
    }
    for rel, content in expected.items():
        path = task / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    (task / "discard.bin").write_bytes(b"unlinked scratch")
    (task / "scratch-only/discard.bin").write_bytes(b"unlinked sibling")
    (task / "artifacts/empty").mkdir()
    (task / "artifacts/member.bin").symlink_to(task / "backing.bin")
    (task / "artifacts/directory.bin").symlink_to(task / "pieces")
    (task / "artifacts/external.bin").symlink_to(external)
    (task / "saved-artifacts/member.bin").symlink_to(task / "saved-backing.bin")
    (task / "saved-artifacts/external.bin").symlink_to(external)
    report = task / "report.md"
    references = case / "references"
    body = ("[evidence directory](artifacts" + ("/" if variant == "local" else "")
            + ") [single file](scratch-only/evidence.bin)")
    (report if variant == "local" else references).write_text(body)
    pr = "https://github.com/test/repo/pull/1" if variant == "pr" else ""
    command = [sys.executable, helper]
    subprocess.run(command + ["stage", str(case / "data"), str(case / "state"), variant,
                              str(case / "project"), pr], check=True)
    present_at_stage = {rel: (task / rel).is_file() for rel in expected
                        if not rel.startswith("saved-")}
    assert (task / ".cleanup-hold/saved-artifacts/frame.bin").is_file(), "unlinked directory did not stage"
    assert (task / ".cleanup-hold/discard.bin").is_file(), "unrelated scratch did not stage"
    assert (task / ".cleanup-hold/scratch-only/discard.bin").is_file(), "file link retained its parent's unrelated contents"
    assert external.read_bytes() == b"outside\x00\xff", "staging changed an external target"
    body += " [later directory](saved-artifacts)"
    (report if variant == "local" else references).write_text(body)
    subprocess.run(command + ["expire", str(case / "data"), str(case / "state"), variant], check=True)
    for rel, content in expected.items():
        path = task / rel
        assert path.is_file(), f"{variant} linked directory evidence deleted during expiry: {rel}"
        assert path.read_bytes() == content, f"{variant} directory evidence changed: {rel}"
    assert all(present_at_stage.values()), f"{variant} linked directory contents moved during staging"
    assert (task / "artifacts/empty").is_dir(), "linked empty directory was removed"
    for link, target in (("artifacts/member.bin", "backing.bin"),
                         ("artifacts/directory.bin/deep.bin", "pieces/deep.bin"),
                         ("saved-artifacts/member.bin", "saved-backing.bin")):
        assert (task / link).read_bytes() == expected[target], f"{variant} directory link broke: {link}"
    assert (task / "saved-artifacts/external.bin").read_bytes() == external.read_bytes(), "held external link broke"
    assert external.read_bytes() == b"outside\x00\xff", "expiry changed an external target"
    assert not (task / ".cleanup-hold").exists(), "directory recovery did not expire"
    assert not (task / "discard.bin").exists(), "unrelated scratch survived expiry"
    assert not (task / "scratch-only/discard.bin").exists(), "file link retained an unrelated sibling during expiry"
PY
  pass "fm-teardown: local and PR directory links retain binary descendants, nested symlink targets and newly linked held contents"
}

test_task_data_reference_spellings() {
  local helper=${1:-$ROOT/bin/fm-task-data.py} case_dir reference_source
  for reference_source in local pr bead; do
    case_dir=$(make_case "task-data-spellings-$reference_source")
    if [ "$reference_source" = bead ]; then
      write_task_data_beads_fixture "$case_dir"
    else
      cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
      chmod +x "$case_dir/fakebin/dcg"
    fi
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_REFERENCE_FILE"
SH
    chmod +x "$case_dir/fakebin/gh-axi"
    FM_TEST_REFERENCE_FILE="$case_dir/references" PATH="$case_dir/fakebin:$PATH" \
      python3 - "$case_dir" "$helper" "$reference_source" <<'PY' || fail "reference spelling regression failed"
import json
import os
from pathlib import Path
import subprocess
import sys
import unicodedata

case, helper, source = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
probe = case / "caf\u00e9"
probe.write_bytes(b"probe")
alias = case / "cafe\u0301"
sensitive = not alias.exists() or not os.path.samefile(probe, alias)
print(f"ok - fm-teardown: {source} ordinary-path Unicode checks; normalization-sensitive filesystem: {sensitive}", flush=True)
task = case / "data" / "proof-owner"
external = case / "outside" / "keep.bin"
external.parent.mkdir()
external.write_bytes(b"outside\x00\xff")
names = {"nfc": unicodedata.normalize("NFC", "caf\u00e9"),
         "nfd": unicodedata.normalize("NFD", "r\u00e9sum\u00e9")}
initial = {"proof(1).png": b"escaped capture\x00\xff",
           "escaped-backing.bin": b"escaped alias backing\x00\xff",
           "folder(1)/frame.bin": b"escaped directory capture\x00\xff",
           "single/capture.png": b"single linked file\x00\xff",
           "raw.bin": b"raw capture\x00\xff",
           "url image.png": b"URL capture\x00\xff",
           "html&proof.png": b"HTML capture\x00\xff"}
later = {"later(1).png": b"held escaped capture\x00\xff",
         "later-escaped-backing.bin": b"held escaped alias backing\x00\xff"}
links = {"link(1).png": task / "escaped-backing.bin",
         "later-link(1).png": task / "later-escaped-backing.bin"}
body = (r"[capture](proof\(1\).png) [alias](link\(1\).png) [directory](folder\(1\)/) "
        "[single file](single/capture.png) [raw](raw.bin) [URL](url%20image.png) "
        "[HTML](html&amp;proof.png)\nScratch: " + str(external.parent))
added = r" [later capture](later\(1\).png) [later alias](later-link\(1\).png)"
for form, name in names.items():
    initial[f"{name}/frame.bin"] = f"{form} capture".encode() + b"\x00\xff"
    initial[f"{form}-backing.bin"] = f"{form} backing".encode() + b"\x00\xff"
    later[f"later-{name}/frame.bin"] = f"held {form} capture".encode() + b"\x00\xff"
    later[f"later-{form}-backing.bin"] = f"held {form} backing".encode() + b"\x00\xff"
    links[f"{name}/member.bin"] = task / f"{form}-backing.bin"
    links[f"later-{name}/member.bin"] = task / f"later-{form}-backing.bin"
    links[f"{name}/external.bin"] = external
    links[f"later-{name}/external.bin"] = external
    body += f" [{form} directory]({name}/)"
    added += f" [later {form} directory](later-{name}/)"
for rel, content in (initial | later).items():
    path = task / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
for rel, target in links.items():
    (task / rel).symlink_to(target)
for rel in ("discard.bin", "single/discard.bin", "scratch/blob"):
    path = task / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"unrelated scratch")
(task / "brief.md").write_text("plain cleanup instructions\n")

def publish(text):
    if source == "local":
        (task / "report.md").write_text(text)
    elif source == "pr":
        (case / "references").write_text(json.dumps({"body": text}))
    else:
        subprocess.run(["tasks-axi", "update", "proof-owner", "--body", text], cwd=case,
                       check=True, stdout=subprocess.DEVNULL)

publish(body)
pr = "https://github.com/test/repo/pull/1" if source == "pr" else ""
command = [sys.executable, helper]
subprocess.run(command + ["stage", str(case / "data"), str(case / "state"), "proof-owner",
                          str(case / "project"), pr], check=True)
assert (task / names["nfc"] / "frame.bin").is_file(), "NFC Unicode directory evidence was staged"
assert (task / names["nfd"] / "frame.bin").is_file(), "NFD Unicode directory evidence was staged"
assert (task / "proof(1).png").is_file(), "Markdown-escaped filename was staged"
for rel, content in initial.items():
    assert (task / rel).read_bytes() == content, f"{source} initial spelling lost: {rel}"
for rel, content in later.items():
    assert (task / ".cleanup-hold" / rel).read_bytes() == content, f"unlinked held spelling retained early: {rel}"
for rel in ("discard.bin", "single/discard.bin", "scratch/blob"):
    assert (task / ".cleanup-hold" / rel).is_file(), f"{source} unrelated scratch did not stage: {rel}"
for form, name in names.items():
    assert (task / name / "member.bin").read_bytes() == initial[f"{form}-backing.bin"], "Unicode directory symlink broke"
assert (task / "link(1).png").read_bytes() == initial["escaped-backing.bin"], "escaped symlink backing was staged"
publish(body + added)
subprocess.run(command + ["expire", str(case / "data"), str(case / "state"), "proof-owner"], check=True)
for rel, content in (initial | later).items():
    assert (task / rel).read_bytes() == content, f"{source} spelling lost during expiry: {rel}"
for form, name in names.items():
    assert (task / name / "member.bin").read_bytes() == initial[f"{form}-backing.bin"], "expiry broke an initial Unicode link"
    assert (task / f"later-{name}/member.bin").read_bytes() == later[f"later-{form}-backing.bin"], "expiry broke a held Unicode link"
    assert (task / f"later-{name}/external.bin").read_bytes() == b"outside\x00\xff", "expiry changed an external target"
assert (task / "later-link(1).png").read_bytes() == later["later-escaped-backing.bin"], "expiry broke a held escaped link"
assert external.read_bytes() == b"outside\x00\xff", "cleanup escaped its owned root"
assert not (task / ".cleanup-hold").exists(), "spelling recovery did not expire"
for rel in ("discard.bin", "single/discard.bin", "scratch/blob"):
    assert not (task / rel).exists(), f"{source} unrelated scratch was retained: {rel}"
PY
  done
  pass "fm-teardown: local, PR and owning-bead links preserve NFC/NFD directories and escaped Markdown through staging, held recovery and expiry"
}

test_task_data_filesystem_name_aliases() {
  local helper=${1:-$ROOT/bin/fm-task-data.py} case_dir
  case_dir=$(make_case task-data-name-aliases)
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_REFERENCE_FILE"
SH
  chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
  FM_TEST_REFERENCE_FILE="$case_dir/references" PATH="$case_dir/fakebin:$PATH" \
    python3 - "$case_dir" "$helper" <<'PY' || fail "filesystem name alias regression failed"
import json
import os
from pathlib import Path
import subprocess
import sys

case, helper = Path(sys.argv[1]), sys.argv[2]
probe = case / "CaseProbe"
probe.write_bytes(b"probe")
if not (case / "caseprobe").exists() or not os.path.samefile(probe, case / "caseprobe"):
    print("ok - fm-teardown: filesystem name aliases skipped on a case-sensitive filesystem")
    sys.exit(0)
task = case / "data" / "finished"
external = case / "outside" / "keep.bin"
external.parent.mkdir()
external.write_bytes(b"external\x00\xff")
expected = {
    "captures/frame.bin": b"capture\x00\xff",
    "rawcapture.bin": b"direct file\x00\xff",
    "rawdir/pixel.bin": b"direct directory\x00\xff",
    "frames/piece.bin": b"directory alias\x00\xff",
    "walk/proof.bin": b"ordered prefix\x00\xff",
    "rootcapture.bin": b"owned root\x00\xff",
    "caf\u00e9/frame.bin": b"unicode target\x00\xff",
    "r\u00e9sum\u00e9.bin": b"unicode reference\x00\xff",
    "linked-original.bin": b"hardlinked capture\x00\xff",
    "held-captures/frame.bin": b"held capture\x00\xff",
    "held-direct.bin": b"held direct file\x00\xff",
    "held-dir/pixel.bin": b"held direct directory\x00\xff",
    "held-frames/piece.bin": b"held directory alias\x00\xff",
    "held-walk/proof.bin": b"held ordered prefix\x00\xff",
    "held-root.bin": b"held owned root\x00\xff",
}
for rel, content in expected.items():
    path = task / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
(task / "walk/subdir").mkdir()
(task / "held-walk/subdir").mkdir()
(task / "discard.bin").write_bytes(b"unlinked scratch")
(task / "captures/discard.bin").write_bytes(b"unlinked sibling")
os.link(task / "linked-original.bin", task / "hardlink-other.bin")
links = {
    "latest.png": "Captures/FRAME.BIN",
    "sequence.png": "FRAMES",
    "walk-alias.bin": "WALK/SUBDIR",
    "component.png": "WALK-ALIAS.BIN/../PROOF.BIN",
    "root.png": str(task.parent / "FINISHED" / "ROOTCAPTURE.BIN"),
    "unicode.png": "CAFE\u0301/FRAME.BIN",
    "hardlink.png": "LINKED-ORIGINAL.BIN",
    "escape.png": str(case / "OUTSIDE" / "KEEP.BIN"),
    "saved.png": "HELD-CAPTURES/FRAME.BIN",
    "saved-frames.png": "HELD-FRAMES",
    "held-alias.bin": "HELD-WALK/SUBDIR",
    "saved-component.png": "HELD-ALIAS.BIN/../PROOF.BIN",
    "saved-root.png": str(task.parent / "FINISHED" / "HELD-ROOT.BIN"),
}
for rel, target in links.items():
    (task / rel).symlink_to(target)
references = case / "references"
body = ("[capture](latest.png) [sequence](sequence.png) [prefix](component.png) [root](root.png) "
        "[unicode](unicode.png) [outside](escape.png) [direct](RAWCAPTURE.BIN) "
        "[directory](RAWDIR/) [unicode direct](R\u00c9SUM\u00c9.BIN) [hardlinked](hardlink.png)")
references.write_text(json.dumps({"body": body}))
command = [sys.executable, helper]
subprocess.run(command + ["stage", str(case / "data"), str(case / "state"), "finished",
                          str(case / "project"), "https://github.com/test/repo/pull/1"], check=True)
assert (task / "latest.png").is_file(), "filesystem alias lost its backing file during staging"
for rel, content in expected.items():
    if rel.startswith("held-"):
        assert (task / ".cleanup-hold" / rel).read_bytes() == content, f"unlinked alias target did not stage: {rel}"
    else:
        assert (task / rel).read_bytes() == content, f"filesystem identity lost during staging: {rel}"
assert (task / "walk/subdir").is_dir(), "aliased traversal prefix was removed"
assert (task / ".cleanup-hold/captures/discard.bin").is_file(), "alias retention kept an unrelated sibling"
assert (task / ".cleanup-hold/hardlink-other.bin").is_file(), "alias retention confused distinct hardlink names"
references.write_text(json.dumps({"body": body + " [saved](saved.png) [saved frames](saved-frames.png) "
                                 "[saved prefix](saved-component.png) [saved root](saved-root.png) "
                                 "[held direct](HELD-DIRECT.BIN) [held directory](HELD-DIR/)"}))
subprocess.run(command + ["expire", str(case / "data"), str(case / "state"), "finished"], check=True)
for rel, content in expected.items():
    assert (task / rel).read_bytes() == content, f"filesystem identity lost during expiry: {rel}"
for rel in ("latest.png", "sequence.png/piece.bin", "component.png", "root.png", "unicode.png", "hardlink.png",
            "saved.png", "saved-frames.png/piece.bin", "saved-component.png", "saved-root.png"):
    assert (task / rel).is_file(), f"filesystem alias broke during expiry: {rel}"
assert (task / "held-walk/subdir").is_dir(), "held traversal prefix was not restored"
assert (task / "escape.png").read_bytes() == b"external\x00\xff", "external alias changed"
assert external.read_bytes() == b"external\x00\xff", "filesystem alias cleanup escaped its root"
assert not (task / ".cleanup-hold").exists(), "aliased recovery did not expire"
assert not (task / "discard.bin").exists(), "unrelated scratch survived aliased expiry"
assert not (task / "captures/discard.bin").exists(), "unrelated sibling survived aliased expiry"
print("ok - fm-teardown: real filesystem name aliases retain direct, directory, prefix, owned-root and held evidence")
PY
}

test_task_data_symlink_ancestor_aliases() {
  local helper=$1 case_dir task physical alias_root captures variant data
  for variant in fixture macos; do
    if [ "$variant" = macos ] && [ "$(cd -P /tmp && pwd -P)" != /private/tmp ]; then
      pass "skip: macOS /tmp ancestor alias is not present on this host"
      continue
    fi
    case_dir=$(make_case "task-data-ancestor-alias-$variant")
    if [ "$variant" = macos ]; then
      physical=$(TMPDIR=/tmp fm_test_tmproot fm-task-data-alias)
      alias_root="/tmp/${physical##*/}"
    else
      physical="$case_dir/physical"
      alias_root="$case_dir/ancestor-alias"
      mkdir -p "$physical/anchor/subdir"
      ln -s "$physical/anchor/subdir" "$case_dir/alias-bridge"
      ln -s "$case_dir/alias-bridge/../.." "$alias_root"
    fi
    data="$physical/data"
    task="$data/finished"
    captures="$task/captures"
    mkdir -p "$captures/frames" "$captures/later-frames" "$captures/subdir" "$case_dir/outside"
    printf 'capture\n' > "$captures/capture.bin"
    printf 'frame\n' > "$captures/frames/frame.bin"
    printf 'chain\n' > "$captures/chain.bin"
    printf 'later capture\n' > "$captures/later.bin"
    printf 'later frame\n' > "$captures/later-frames/later-frame.bin"
    printf 'discard\n' > "$captures/discard.bin"
    printf 'ordered capture\n' > "$captures/proof.bin"
    printf 'data capture\n' > "$task/data.bin"
    printf 'data discard\n' > "$task/discard-data.bin"
    printf 'outside\n' > "$case_dir/outside/outside.bin"
    ln -s chain.bin "$captures/bridge.bin"
    ln -s "$alias_root/data/finished/captures/capture.bin" "$task/latest.png"
    ln -s "$alias_root/data/finished/captures/frames" "$task/frames.png"
    ln -s "$alias_root/data/finished/captures/bridge.bin" "$task/chained.png"
    ln -s "$alias_root/data/finished/captures/later.bin" "$task/saved.png"
    ln -s "$alias_root/data/finished/captures/later-frames" "$task/saved-frames.png"
    ln -s captures/subdir "$task/component-alias.bin"
    ln -s "$alias_root/data/finished/component-alias.bin/../proof.bin" "$task/component.png"
    ln -s "$data" "$case_dir/data-alias"
    ln -s "$case_dir/data-alias/finished/data.bin" "$task/latest-data.png"
    ln -s "$case_dir/outside" "$case_dir/outside-alias"
    ln -s "$case_dir/outside-alias/outside.bin" "$task/escape.png"
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: [image](latest.png) [frames](frames.png) [chain](chained.png) [data](latest-data.png) [external](escape.png) [components](component.png)\n'
SH
    chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
      "$data" "$case_dir/state" finished "$case_dir/project" https://github.com/test/repo/pull/1 \
      || fail "$variant alias staging failed"
    [ "$(cat "$task/latest.png")" = capture ] || fail "$variant aliased data link lost its target during staging"
    [ "$(cat "$task/frames.png/frame.bin")" = frame ] || fail "$variant aliased directory lost its contents during staging"
    [ "$(cat "$task/chained.png")" = chain ] || fail "$variant aliased target lost an intermediate symlink"
    [ -L "$captures/bridge.bin" ] || fail "$variant owned intermediate symlink was staged"
    [ "$(cat "$task/latest-data.png")" = 'data capture' ] || fail "$variant aliased data link lost its target"
    [ "$(cat "$task/component.png")" = 'ordered capture' ] || fail "$variant ancestor alias collapsed .. before an owned symlink"
    assert_present "$task/.cleanup-hold/captures/later.bin" "$variant unlinked data target did not stage"
    assert_present "$task/.cleanup-hold/captures/later-frames/later-frame.bin" "$variant unlinked directory did not stage"
    [ -L "$task/.cleanup-hold/saved.png" ] || fail "$variant unlinked image did not stage"
    [ -L "$task/.cleanup-hold/saved-frames.png" ] || fail "$variant unlinked directory link did not stage"
    assert_present "$task/.cleanup-hold/captures/discard.bin" "$variant unrelated scratch did not stage"
    [ "$(cat "$case_dir/outside/outside.bin")" = outside ] || fail "$variant alias cleanup escaped its owned roots"
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: [image](latest.png) [frames](frames.png) [chain](chained.png) [data](latest-data.png) [external](escape.png) [components](component.png) [saved](saved.png) [saved frames](saved-frames.png)\n'
SH
    PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
      "$data" "$case_dir/state" finished || fail "$variant alias expiry failed"
    [ "$(cat "$task/latest.png")" = capture ] || fail "$variant alias expiry deleted the linked capture"
    [ "$(cat "$task/frames.png/frame.bin")" = frame ] || fail "$variant alias expiry deleted linked directory contents"
    [ "$(cat "$task/chained.png")" = chain ] || fail "$variant alias expiry broke the symlink chain"
    [ "$(cat "$task/latest-data.png")" = 'data capture' ] || fail "$variant alias expiry deleted linked data"
    [ "$(cat "$task/component.png")" = 'ordered capture' ] || fail "$variant ancestor alias expiry broke ordered traversal"
    [ "$(cat "$task/saved.png")" = 'later capture' ] || fail "$variant alias expiry did not restore the held target"
    [ "$(cat "$task/saved-frames.png/later-frame.bin")" = 'later frame' ] || fail "$variant alias expiry did not restore held directory contents"
    [ "$(cat "$case_dir/outside/outside.bin")" = outside ] || fail "$variant alias expiry escaped its owned roots"
    assert_absent "$task/.cleanup-hold" "$variant alias data recovery remains"
    assert_absent "$captures/discard.bin" "$variant alias lookup retained unlinked scratch"
    assert_absent "$task/discard-data.bin" "$variant alias lookup retained unlinked data"
    pass "fm-teardown: $variant ancestor aliases preserve owned targets and recovery paths through staging and expiry"
  done
}

test_task_data_collision_progress() {
  local case_dir task helper scratch
  helper="$ROOT/bin/fm-task-data.py"
  case_dir=$(make_case task-data-collision)
  task="$case_dir/data/reused"
  scratch="$task/scratch"
  mkdir -p "$scratch"
  printf 'first generation\n' > "$scratch/build.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
    "$case_dir/data" "$case_dir/state" reused "$case_dir/project" '' || fail "initial stage failed"
  mkdir -p "$scratch"
  printf 'second generation\n' > "$scratch/build.bin"
  if PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
      "$case_dir/data" "$case_dir/state" reused "$case_dir/project" '' > "$case_dir/out" 2> "$case_dir/err"; then
    fail "collision overwrote a generation"
  fi
  jq -e '.complete == true and .expired != true' "$task/record/data-cleanup.json" >/dev/null \
    || fail "collision disabled completed recovery"
  [ "$(cat "$scratch/build.bin")" = 'second generation' ] || fail "replacement changed"
  [ "$(cat "$task/.cleanup-hold/scratch/build.bin")" = 'first generation' ] || fail "first data generation changed"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
    "$case_dir/data" "$case_dir/state" reused || fail "old recovery could not expire"
  [ "$(cat "$task/.cleanup-hold/scratch/build.bin")" = 'second generation' ] || fail "replacement data is not recoverable"
  jq -e '.complete == true and .expired == false' "$task/record/data-cleanup.json" >/dev/null \
    || fail "replacement missed its new recovery cycle"
  PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
    "$case_dir/data" "$case_dir/state" reused || fail "replacement recovery could not expire"
  assert_absent "$task/.cleanup-hold" "data collision recovery remains"
  pass "fm-teardown: reused data scratch paths progress without overwriting either generation"
}

test_task_data_retirement_obligation() {
  local case_dir task real_python mode
  real_python=$(command -v python3)
  case_dir=$(make_case task-data-record-failure)
  task="$case_dir/data/task-x1"
  mkdir -p "$task/scratch"
  printf 'scratch\n' > "$task/scratch/blob"
  write_meta "$case_dir" local-only ship
  cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = prepare ]; then exit 1; fi
exec '$real_python' "\$@"
SH
  chmod +x "$case_dir/fakebin/python3"
  if run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err"; then
    fail "retirement accepted an unwritable cleanup obligation"
  fi
  assert_present "$case_dir/state/task-x1.meta" "record failure retired the task metadata"
  [ "$(cat "$task/scratch/blob")" = scratch ] || fail "record failure changed original scratch"

  for mode in close retain; do
    case_dir=$(make_case "task-data-replay-$mode")
    task="$case_dir/data/task-x1"
    mkdir -p "$task/scratch"
    printf 'Bead replay-123\n' > "$task/brief.md"
    printf 'scratch\n' > "$task/scratch/blob"
    write_meta "$case_dir" local-only ship
    printf 'pr=https://github.com/test/repo/pull/1\n' >> "$case_dir/state/task-x1.meta"
    seed_backlog_in_flight "$case_dir"
    fm_test_tasks_toml "$case_dir/.tasks.toml"
    tasks-axi add replay-123 'replay evidence' --body 'no attachments' \
      --file "$case_dir/data/backlog.md" >/dev/null
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'body: no attachments\n'
SH
    chmod +x "$case_dir/fakebin/dcg" "$case_dir/fakebin/gh-axi"
    cat > "$case_dir/replay.sh" <<'SH'
#!/usr/bin/env bash
set -eu
root=$1 case_dir=$2 mode=$3
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-tasks-axi-lib.sh"
. "$root/bin/fm-backlog-transition-lib.sh"
state="$case_dir/state" data="$case_dir/data"
lock=$(fm_meta_lock_path "$state/task-x1.meta")
fm_lock_acquire_wait "$lock"
flags=()
[ "$mode" = close ] || flags=(--retain)
gen=$(sed -n 's/^spawn_gen=//p' "$state/task-x1.meta")
fm_backlog_close_marker_write "$state" task-x1 "$data" "$gen" "${flags[@]+"${flags[@]}"}" --note 'local main'
fm_backlog_close_marker_replay "$state" "$state/task-x1.backlog-close" "$data"
fm_lock_release "$lock"
SH
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
      PATH="$case_dir/fakebin:$PATH" bash "$case_dir/replay.sh" "$ROOT" "$case_dir" "$mode" \
      > "$case_dir/out" 2> "$case_dir/err" || fail "$mode retirement replay failed: $(cat "$case_dir/err")"
    assert_absent "$case_dir/state/task-x1.meta" "$mode replay left metadata"
    jq -e '.complete == false and .sources[0].pr == "https://github.com/test/repo/pull/1" and .sources[0].beads == ["replay-123"]' \
      "$task/record/data-cleanup.json" >/dev/null || fail "$mode replay lost the cleanup obligation or sources"
    PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$mode replay cleanup could not resume"
    assert_present "$task/.cleanup-hold/scratch/blob" "$mode replay did not give recovery a full cycle"
    PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$mode replay cleanup could not expire"
    assert_absent "$task/.cleanup-hold" "$mode replay recovery remains"
  done
  pass "fm-teardown: failed receipt writes preserve metadata and close/retain replay records retryable cleanup"
}

test_task_data_discovered_pr_retirement() {
  local code_root=${1:-$ROOT} case_dir task mode real_tasks real_python rc expected
  real_tasks=$(command -v tasks-axi)
  real_python=$(command -v python3)
  for mode in close retain replay-close replay-retain replay-absent replay-absent-retain direct; do
    case_dir=$(make_case "task-data-discovered-$mode")
    task="$case_dir/data/task-x1"
    mkdir -p "$task/scratch"
    printf 'PR-only evidence\n' > "$task/proof.png"
    printf 'scratch\n' > "$task/scratch/blob"
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
    [ "$mode" = direct ] || seed_backlog_in_flight "$case_dir"
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' 'count: 1 (showing first 1)' 'pull_requests[1]{number,state}:' '  7,merged' ;;
  "pr view") printf '%s\n' 'pull_request:' '  number: 7' '  state: merged' '  merged: "2026-06-26T00:00:00Z"' '  body: [proof](proof.png)' ;;
esac
SH
    cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${FM_TEST_FAIL_COMPLETION:-0}" = 1 ]; then
  case "\${1:-}" in done|reopen) exit 1 ;; esac
fi
exec '$real_tasks' "\$@"
SH
    cat > "$case_dir/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${FM_TEST_SKIP_STAGE:-0}" = 1 ] && [ "\${2:-}" = stage ]; then exit 1; fi
exec '$real_python' "\$@"
SH
    chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/tasks-axi" "$case_dir/fakebin/python3"
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/dcg"
    cat > "$case_dir/transition.sh" <<'SH'
#!/usr/bin/env bash
set -eu
root=$1 case_dir=$2 mode=$3
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-tasks-axi-lib.sh"
. "$root/bin/fm-backlog-transition-lib.sh"
state="$case_dir/state" data="$case_dir/data"
lock=$(fm_meta_lock_path "$state/task-x1.meta")
fm_lock_acquire_wait "$lock"
trap 'fm_lock_release "$lock"' EXIT
pr=https://github.com/example/repo/pull/7
if [ "$mode" != replay ]; then
  flags=()
  case "$mode" in *retain) flags=(--retain) ;; esac
  gen=$(sed -n 's/^spawn_gen=//p' "$state/task-x1.meta")
  fm_backlog_close_marker_write "$state" task-x1 "$data" "$gen" "${flags[@]+"${flags[@]}"}" --pr "$pr"
fi
case "$mode" in
  replay-absent*)
    python3 "$root/bin/fm-task-data.py" prepare "$data" "$state" task-x1
    fm_backlog_record_remove "$state/task-x1.meta" 'task record' "$state"
    ;;
esac
if [ "$mode" = retain ]; then
  fm_backlog_atomic_transition retain "$state/task-x1.meta" "$state/task-x1.backlog-close" \
    "$data" task-x1 "$state" --pr "$pr"
else
  fm_backlog_close_marker_replay "$state" "$state/task-x1.backlog-close" "$data"
fi
SH
    rc=0
    expected=0
    case "$mode" in
      close|direct)
        [ "$mode" != close ] || expected=1
        FM_TEST_FAIL_COMPLETION=1 FM_TEST_SKIP_STAGE=1 FM_HOME="$case_dir" \
          FM_ROOT_OVERRIDE="$code_root" FM_STATE_OVERRIDE="$case_dir/state" \
          FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
          PATH="$case_dir/fakebin:$PATH" "$code_root/bin/fm-teardown.sh" task-x1 \
          > "$case_dir/out" 2> "$case_dir/err" || rc=$?
        ;;
      *)
        [ "$mode" != retain ] || expected=1
        FM_TEST_FAIL_COMPLETION="$expected" FM_HOME="$case_dir" \
          FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
          PATH="$case_dir/fakebin:$PATH" bash "$case_dir/transition.sh" "$code_root" "$case_dir" "$mode" \
          > "$case_dir/out" 2> "$case_dir/err" || rc=$?
        ;;
    esac
    expect_code "$expected" "$rc" "$mode discovered-PR retirement: $(cat "$case_dir/err")"
    assert_absent "$case_dir/state/task-x1.meta" "$mode did not retire metadata"
    jq -e '.complete == false and any(.sources[]; .pr == "https://github.com/example/repo/pull/7")' \
      "$task/record/data-cleanup.json" >/dev/null || fail "$mode retirement lost the discovered PR before staging"
    [ "$(cat "$task/proof.png")" = 'PR-only evidence' ] || fail "$mode retirement changed linked evidence"
    case "$mode" in
      close|retain)
        assert_present "$case_dir/state/task-x1.backlog-close" "$mode interruption lost the replay obligation"
        FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
          PATH="$case_dir/fakebin:$PATH" bash "$case_dir/transition.sh" "$code_root" "$case_dir" replay \
          > "$case_dir/replay.out" 2> "$case_dir/replay.err" || fail "$mode replay failed: $(cat "$case_dir/replay.err")"
        ;;
    esac
    assert_absent "$case_dir/state/task-x1.backlog-close" "$mode replay left its pending completion"
    PATH="$case_dir/fakebin:$PATH" python3 "$code_root/bin/fm-task-data.py" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$mode discovered-PR cleanup could not stage"
    [ "$(cat "$task/proof.png")" = 'PR-only evidence' ] || fail "$mode replay staged PR-linked evidence"
    assert_present "$task/.cleanup-hold/scratch/blob" "$mode replay omitted one-cycle recovery"
    PATH="$case_dir/fakebin:$PATH" python3 "$code_root/bin/fm-task-data.py" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$mode discovered-PR cleanup could not expire"
    [ "$(cat "$task/proof.png")" = 'PR-only evidence' ] || fail "$mode replay deleted PR-linked evidence"
    assert_absent "$task/.cleanup-hold" "$mode recovery did not expire"
  done
  pass "fm-teardown: discovered PR references survive interrupted close, retain, replay and direct retirement"
}

test_task_data_legacy_rows() {
  local case_dir task variant helper project pr row_file note refresh original
  helper="$ROOT/bin/fm-task-data.py"
  for variant in archive current no-pr missing active gitlab-note gerrit-note ambiguous-note ambiguous-notes repeated-note; do
    case_dir=$(make_case "task-data-legacy-$variant")
    task="$case_dir/data/task-x1"
    project="$case_dir/projects/demo"
    pr=https://github.com/groovejones/groove-sight-platform/pull/4365
    row_file="$case_dir/history/completed.md"
    case "$variant" in
      current|no-pr|gerrit-note) row_file="$case_dir/data/backlog.md" ;;
    esac
    mkdir -p "$task" "$project" "$case_dir/history"
    printf 'retired task\n' > "$task/brief.md"
    printf 'row evidence\n' > "$task/row.png"
    printf 'named evidence\n' > "$task/bead.png"
    printf 'PR evidence\n' > "$task/pr.png"
    printf 'scratch\n' > "$task/discard.bin"
    cat > "$case_dir/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "history/completed.md"
TOML
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$case_dir/data/backlog.md"
    if [ "$variant" != missing ]; then
      cat > "$case_dir/history/completed.md" <<'MD'
## Archived 2026-10-10
- [x] task-x1 - old attempt https://github.com/test/old/pull/1 (repo: obsolete) (done 2026-10-10)
  Bead old-ref

## Archived 2026-10-11
- [x] task-x1 - finished https://github.com/groovejones/groove-sight-platform/pull/4365 (repo: demo) (done 2026-10-11)
  Bead proof-related; [capture](row.png)
MD
    fi
    if [ "$variant" = current ]; then
      printf '%s\n' '- [x] task-x1 - newest https://github.com/groovejones/groove-sight-platform/pull/4365 (repo: demo) (done 2026-10-12)' \
        '  Bead proof-related; [capture](row.png)' >> "$case_dir/data/backlog.md"
    elif [ "$variant" = no-pr ]; then
      pr=''
      printf '%s\n' '- [x] task-x1 - newest without a PR (repo: demo) (done 2026-10-12)' \
        '  Bead proof-related; [capture](row.png)' >> "$case_dir/data/backlog.md"
    elif [ "$variant" = active ]; then
      printf '# Backlog\n\n## In flight\n- [ ] task-x1 - reused (repo: demo)\n' > "$case_dir/data/backlog.md"
    elif [ "$variant" = gitlab-note ] || [ "$variant" = gerrit-note ] || [ "$variant" = ambiguous-notes ]; then
      if [ "$variant" = gerrit-note ]; then
        pr=https://review.internal/c/group/repo/+/7
        note="Gerrit change $pr"
      else
        pr=https://gitlab.example.com/group/repo/-/merge_requests/7
        note="GitLab merge request $pr"
      fi
      printf '%s\n' '- [x] task-x1 - newest (repo: demo) (done 2026-10-12)' \
        '  Bead proof-related; [capture](row.png)' "  $note" >> "$row_file"
      if [ "$variant" = ambiguous-notes ]; then
        printf '  Gerrit change https://review.internal/c/group/repo/+/7\n' >> "$row_file"
      fi
    elif [ "$variant" = ambiguous-note ]; then
      printf '  GitLab merge request https://gitlab.example.com/group/repo/-/merge_requests/7\n' >> "$row_file"
    elif [ "$variant" = repeated-note ]; then
      printf '  Completed %s\n' "$pr" >> "$row_file"
    fi
    cat > "$case_dir/fakebin/br" <<'SH'
#!/usr/bin/env bash
[ "$PWD" = "$REF_PROJECT" ] && [ "$1 $2" = 'show proof-related' ] || exit 1
printf '[{"id":"proof-related","description":"[capture](bead.png)"}]\n'
SH
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'pr view 4365' ] || exit 2
printf 'body: [capture](pr.png)\n'
SH
    cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'mr view') [ "$3" = 7 ] || exit 2; printf '{"iid":7,"state":"merged","description":"[capture](pr.png)"}\n' ;;
  'api --hostname') printf '[]\n' ;;
  *) exit 1 ;;
esac
SH
    cat > "$case_dir/fakebin/gerrit-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'show 7 --host review.internal --json' ] || exit 1
printf '{"ok":true,"changes":[{"change":7,"status":"MERGED","subject":"[capture](pr.png)"}]}\n'
SH
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/br" "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/glab" \
      "$case_dir/fakebin/gerrit-axi" "$case_dir/fakebin/dcg"
    REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" prepare "$case_dir/data" "$case_dir/state" task-x1 \
      > "$case_dir/out" 2> "$case_dir/err" || fail "legacy $variant prepare failed: $(cat "$case_dir/err")"
    if [ "$variant" = missing ] || [ "$variant" = active ] \
      || [ "$variant" = ambiguous-note ] || [ "$variant" = ambiguous-notes ]; then
      assert_grep task-x1 "$case_dir/err" "legacy $variant did not name retained task"
      assert_present "$task/discard.bin" "legacy $variant moved scratch"
      assert_absent "$task/record/data-cleanup.json" "legacy $variant invented cleanup sources"
      assert_absent "$task/.cleanup-hold" "legacy $variant staged without a completed row"
      case "$variant" in
        ambiguous-*) assert_grep 'multiple PRs' "$case_dir/err" "legacy $variant did not report ambiguous PRs" ;;
      esac
      continue
    fi
    jq -e --arg project "$project" --arg pr "$pr" \
      '.sources[-1] | .project == $project and .pr == $pr and .beads == ["proof-related"]' \
      "$task/record/data-cleanup.json" >/dev/null || fail "legacy $variant chose stale or incomplete sources"
    original=$(jq -r '.sources[-1].backlog.text' "$task/record/data-cleanup.json")
    REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" stage "$case_dir/data" "$case_dir/state" task-x1 "$project" "$pr" \
      || fail "legacy $variant stage failed"
    assert_present "$task/row.png" "legacy $variant lost completed-row evidence"
    assert_present "$task/bead.png" "legacy $variant lost named-bead evidence"
    if [ -n "$pr" ]; then
      assert_present "$task/pr.png" "legacy $variant lost PR evidence"
    fi
    assert_present "$task/.cleanup-hold/discard.bin" "legacy $variant did not stage scratch"
    cp "$case_dir/data/backlog.md" "$case_dir/saved-backlog.md"
    printf '# Backlog\n\n## In flight\n- [ ] task-x1 - reused (repo: demo)\n' > "$case_dir/data/backlog.md"
    REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" expire "$case_dir/data" "$case_dir/state" task-x1 \
      > "$case_dir/out" 2> "$case_dir/err" || fail "active legacy retry failed the pass"
    assert_present "$task/.cleanup-hold/discard.bin" "legacy expiry ignored the active backlog row"
    for refresh in changed ambiguous; do
      [ "$refresh" != ambiguous ] || [ -n "$pr" ] || continue
      cp "$case_dir/saved-backlog.md" "$case_dir/data/backlog.md"
      printf '%s\n' '- [x] task-x1 - changed (repo: demo) (done 2026-10-13)' \
        '  Completed https://github.com/groovejones/groove-sight-platform/pull/4366' \
        >> "$case_dir/data/backlog.md"
      if [ "$refresh" = ambiguous ]; then
        printf '  Completed %s\n' "$pr" >> "$case_dir/data/backlog.md"
      fi
      REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
        python3 "$helper" expire "$case_dir/data" "$case_dir/state" task-x1 \
        > "$case_dir/out" 2> "$case_dir/err" || fail "$refresh legacy source failed the pass"
      assert_present "$task/.cleanup-hold/discard.bin" "legacy expiry ignored the $refresh PR"
      if [ "$refresh" = changed ]; then
        assert_grep 'changed project or PR' "$case_dir/err" "legacy expiry omitted the changed source"
      else
        assert_grep 'multiple PRs' "$case_dir/err" "legacy expiry omitted the ambiguous source"
      fi
    done
    cp "$case_dir/saved-backlog.md" "$case_dir/data/backlog.md"
    printf 'later evidence\n' > "$task/.cleanup-hold/later.png"
    printf '  [later capture](later.png)\n' >> "$row_file"
    REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" expire "$case_dir/data" "$case_dir/state" task-x1 \
      || fail "legacy $variant expiry failed"
    assert_present "$task/later.png" "legacy $variant did not refresh completed-row references"
    assert_absent "$task/.cleanup-hold" "legacy $variant hold did not expire"
    if [ -n "$pr" ]; then
      [ "$(cat "$task/pr.png")" = 'PR evidence' ] || fail "legacy $variant expiry lost PR evidence"
    fi
    jq -e --arg original "$original" '.sources[0].backlog.text == $original' \
      "$task/record/data-cleanup.json" >/dev/null || fail "legacy $variant replaced the original row evidence"
    fm_write_meta "$case_dir/state/task-x1.meta" "project=$project" 'kind=ship' \
      'pr=https://github.com/groovejones/groove-sight-platform/pull/4366'
    printf '# Backlog\n\n## In flight\n- [ ] task-x1 - reused (repo: demo)\n' > "$case_dir/data/backlog.md"
    REF_PROJECT="$project" FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" prepare "$case_dir/data" "$case_dir/state" task-x1 \
      || fail "reused legacy task could not record its new retirement"
    jq -e '.sources[-1].pr == "https://github.com/groovejones/groove-sight-platform/pull/4366"' \
      "$task/record/data-cleanup.json" >/dev/null || fail "legacy source prevented the reused task retirement record"
  done
  pass "fm-teardown: legacy preparation uses the latest completed row and preserves missing or active tasks"
}

test_task_data_legacy_reused_id() {
  local case_dir task helper project variant action
  helper="$ROOT/bin/fm-task-data.py"
  for variant in expired empty unexpired legacy direct; do
    case_dir=$(make_case "task-data-legacy-reuse-$variant")
    task="$case_dir/data/task-x1"
    project="$case_dir/projects/demo"
    mkdir -p "$task" "$project" "$case_dir/history"
    cat > "$case_dir/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "history/completed.md"
TOML
    printf '# Backlog\n\n## In flight\n\n## Done\n' > "$case_dir/data/backlog.md"
    printf '%s\n' '- [x] task-x1 - previous https://github.com/test/repo/pull/1 (repo: demo) (done 2026-10-10)' \
      '  [historical row evidence](old-row.bin)' > "$case_dir/history/completed.md"
    printf 'historical row evidence\n' > "$task/old-row.bin"
    printf 'historical PR evidence\n' > "$task/old-pr.bin"
    [ "$variant" = empty ] || printf 'old scratch\n' > "$task/old-scratch.bin"
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$3" in
  1) printf 'body: [old evidence](old-pr.bin)\n' ;;
  2) printf 'body: [new evidence](new-pr.bin)\n' ;;
  *) exit 2 ;;
esac
SH
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/dcg"
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" prepare \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$variant first prepare failed"
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
      "$case_dir/data" "$case_dir/state" task-x1 "$project" https://github.com/test/repo/pull/1 \
      || fail "$variant first stage failed"
    if [ "$variant" != unexpired ]; then
      if [ "$variant" != empty ]; then
        printf 'late historical row evidence\n' > "$task/.cleanup-hold/late-row.bin"
        printf '  [late historical evidence](late-row.bin)\n' >> "$case_dir/history/completed.md"
      fi
      FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
        "$case_dir/data" "$case_dir/state" task-x1 || fail "$variant first expiry failed"
      jq -e '.expired == true' "$task/record/data-cleanup.json" >/dev/null || fail "$variant first retirement not expired"
    fi
    printf '# Backlog\n\n## In flight\n- [ ] task-x1 - reused (repo: demo)\n' > "$case_dir/data/backlog.md"
    printf 'new scratch\n' > "$task/new-scratch.bin"
    printf 'current PR evidence\n' > "$task/new-pr.bin"
    if [ "$variant" != legacy ] && [ "$variant" != direct ]; then
      fm_write_meta "$case_dir/state/task-x1.meta" "project=$project" 'kind=ship' \
        'pr=https://github.com/test/repo/pull/2'
      FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" prepare \
        "$case_dir/data" "$case_dir/state" task-x1 || fail "$variant second prepare failed"
      mv "$case_dir/state/task-x1.meta" "$case_dir/retired.meta"
    fi
    printf '# Backlog\n\n## Done\n%s\n' \
      '- [x] task-x1 - reused https://github.com/test/repo/pull/2 (repo: demo)' > "$case_dir/data/backlog.md"
    if [ "$variant" = legacy ]; then
      FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" prepare \
        "$case_dir/data" "$case_dir/state" task-x1 || fail "$variant second prepare failed"
      jq -e '.sources[-1].pr == "https://github.com/test/repo/pull/2" and .sources[-1].backlog.legacy' \
        "$task/record/data-cleanup.json" >/dev/null || fail "$variant prepare recorded closed history as the new retirement"
    fi
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
      "$case_dir/data" "$case_dir/state" task-x1 "$project" https://github.com/test/repo/pull/2 \
      > "$case_dir/out" 2> "$case_dir/err" || fail "$variant second stage failed"
    if [ "$variant" = unexpired ]; then
      for action in stage expire; do
        assert_grep 'completed row task-x1 changed project or PR' "$case_dir/err" "$action failed to warn about an unexpired conflict"
        assert_present "$task/new-scratch.bin" "$action moved scratch despite unexpired conflict"
        assert_present "$task/.cleanup-hold/old-scratch.bin" "$action lost the old recovery"
        assert_present "$task/new-pr.bin" "$action lost current PR evidence"
        FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
          "$case_dir/data" "$case_dir/state" task-x1 > "$case_dir/out" 2> "$case_dir/err" \
          || fail "unexpired conflict failed the pass"
      done
      continue
    fi
    assert_present "$task/.cleanup-hold/new-scratch.bin" "$variant expired legacy history blocked new staging"
    jq -e '.complete == true and .expired == false' "$task/record/data-cleanup.json" >/dev/null \
      || fail "$variant new retirement has no completed recovery cycle"
    [ "$(cat "$task/new-pr.bin")" = 'current PR evidence' ] || fail "$variant staged current PR evidence"
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$variant second expiry failed"
    assert_absent "$task/.cleanup-hold" "$variant reused recovery did not expire"
    assert_absent "$task/new-scratch.bin" "$variant new scratch did not expire"
    [ "$(cat "$task/new-pr.bin")" = 'current PR evidence' ] || fail "$variant deleted current PR evidence"
    assert_present "$task/old-row.bin" "$variant lost historical row evidence"
    assert_present "$task/old-pr.bin" "$variant lost historical PR evidence"
    [ "$variant" = empty ] || assert_present "$task/late-row.bin" "$variant lost refreshed historical row evidence"
    jq -e '.expired == true' "$task/record/data-cleanup.json" >/dev/null || fail "$variant second retirement not expired"
  done
  pass "fm-teardown: expired legacy history permits reused retirement while unexpired conflicts retain recovery"
}

test_task_data_legacy_ordering() {
  local case_dir task variant helper project pr row_file date first_project first_pr
  helper="$ROOT/bin/fm-task-data.py"
  for variant in current-undated current-older archive-undated archive-tie current-tie project-tie archive-invalid same-source-undated; do
    case_dir=$(make_case "task-data-ordering-$variant")
    task="$case_dir/data/task-x1"
    project="$case_dir/projects/demo"
    mkdir -p "$task" "$project" "$case_dir/projects/obsolete" "$case_dir/history"
    printf 'current PR evidence\n' > "$task/current-pr-only.bin"
    printf 'scratch\n' > "$task/discard.bin"
    cat > "$case_dir/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "history/completed.md"
TOML
    printf '# Backlog\n\n## Done\n' > "$case_dir/data/backlog.md"
    row_file="$case_dir/history/completed.md"
    date=' (done 2026-10-10)'
    first_project=demo
    first_pr=https://github.com/groovejones/groove-sight-platform/pull/4365
    [ "$variant" != archive-undated ] || date=''
    [ "$variant" != archive-invalid ] || date=' (done 2026-99-99)'
    [ "$variant" != current-older ] || first_project=obsolete
    [ "$variant" != current-tie ] || row_file="$case_dir/data/backlog.md"
    if [ "$variant" = same-source-undated ]; then
      date=''
      first_pr=https://github.com/groovejones/groove-sight-platform/pull/4364
      printf 'older row evidence\n' > "$task/old-row-only.bin"
    fi
    printf '\n- [x] task-x1 - old %s (repo: %s)%s\n' \
      "$first_pr" "$first_project" "$date" >> "$row_file"
    [ "$variant" != same-source-undated ] || printf '  [older capture](old-row-only.bin)\n' >> "$row_file"
    case "$variant" in
      current-undated) row_file="$case_dir/data/backlog.md"; date='' ;;
      current-older) row_file="$case_dir/data/backlog.md"; date=' (done 2026-10-01)' ;;
      archive-undated|archive-invalid|same-source-undated) date=' (done 2026-10-11)' ;;
    esac
    pr=https://github.com/groovejones/groove-sight-platform/pull/4364
    if [ "$variant" = project-tie ]; then
      pr=https://github.com/groovejones/groove-sight-platform/pull/4365
      first_project=obsolete
    else
      first_project=demo
    fi
    printf '\n- [x] task-x1 - current %s (repo: %s)%s\n' "$pr" "$first_project" "$date" >> "$row_file"
    cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$1 $2 $3" in
  'pr view 4364') printf 'body: [current](current-pr-only.bin)\n' ;;
  'pr view 4365') printf 'body: no linked files\n' ;;
  *) exit 2 ;;
esac
SH
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/dcg"
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" prepare "$case_dir/data" "$case_dir/state" task-x1 \
      > "$case_dir/out" 2> "$case_dir/err" || fail "ordering $variant preparation failed"
    case "$variant" in
      current-undated|current-older|same-source-undated) ;;
      *)
        assert_grep task-x1 "$case_dir/err" "ordering $variant did not name retained data"
        assert_absent "$task/record/data-cleanup.json" "ordering $variant selected unprovable sources"
        assert_absent "$task/.cleanup-hold" "ordering $variant staged ambiguous data"
        assert_present "$task/current-pr-only.bin" "ordering $variant lost evidence"
        assert_present "$task/discard.bin" "ordering $variant moved scratch"
        continue
        ;;
    esac
    project=$(jq -r '.sources[-1].project' "$task/record/data-cleanup.json")
    pr=$(jq -r '.sources[-1].pr' "$task/record/data-cleanup.json")
    cp "$case_dir/data/backlog.md" "$case_dir/ordering-backlog.md"
    if [ "$variant" = current-undated ]; then
      printf '\n- [x] task-x1 - conflict https://github.com/groovejones/groove-sight-platform/pull/4365 (repo: demo)\n' \
        >> "$case_dir/data/backlog.md"
      FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
        python3 "$helper" stage "$case_dir/data" "$case_dir/state" task-x1 "$project" "$pr" \
        > "$case_dir/out" 2> "$case_dir/err" || fail "ambiguous row refresh failed staging pass"
      assert_grep task-x1 "$case_dir/err" "ambiguous staging did not name retained data"
      assert_absent "$task/.cleanup-hold" "ambiguous row refresh staged data"
      assert_present "$task/discard.bin" "ambiguous row refresh moved scratch"
      cp "$case_dir/ordering-backlog.md" "$case_dir/data/backlog.md"
    fi
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" stage "$case_dir/data" "$case_dir/state" task-x1 "$project" "$pr" \
      > "$case_dir/out" 2> "$case_dir/err" || fail "ordering $variant stage failed"
    assert_present "$task/current-pr-only.bin" "ordering $variant staged current PR-only evidence"
    if [ "$variant" = current-undated ]; then
      printf '\n- [x] task-x1 - conflict https://github.com/groovejones/groove-sight-platform/pull/4365 (repo: demo)\n' \
        >> "$case_dir/data/backlog.md"
      FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
        python3 "$helper" expire "$case_dir/data" "$case_dir/state" task-x1 \
        > "$case_dir/out" 2> "$case_dir/err" || fail "ambiguous row refresh failed expiry pass"
      assert_grep task-x1 "$case_dir/err" "ambiguous expiry did not name retained data"
      assert_present "$task/.cleanup-hold/discard.bin" "ambiguous row refresh expired recovery"
      cp "$case_dir/ordering-backlog.md" "$case_dir/data/backlog.md"
    fi
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
      python3 "$helper" expire "$case_dir/data" "$case_dir/state" task-x1 \
      > "$case_dir/out" 2> "$case_dir/err" || fail "ordering $variant expiry failed"
    assert_present "$task/current-pr-only.bin" "ordering $variant deleted current PR-only evidence"
    [ "$(cat "$task/current-pr-only.bin")" = 'current PR evidence' ] || fail "ordering $variant changed evidence"
    [ "$project" = "$case_dir/projects/demo" ] || fail "ordering $variant selected archived project"
    [ "$pr" = https://github.com/groovejones/groove-sight-platform/pull/4364 ] || fail "ordering $variant selected archived PR"
    assert_absent "$task/.cleanup-hold" "ordering $variant did not expire unlinked scratch"
    [ "$variant" != same-source-undated ] || assert_present "$task/old-row-only.bin" "unordered same-source rows lost earlier evidence"
  done
  pass "fm-teardown: current completed rows beat archives and unprovable conflicting sources stay whole"
}

test_task_data_github_reader() {
  local case_dir task helper pr
  helper="$ROOT/bin/fm-task-data.py"
  case_dir=$(make_case task-data-github-reader)
  task="$case_dir/data/task-x1"
  pr=https://github.com/groovejones/groove-sight-platform/pull/4364
  mkdir -p "$task"
  printf 'PR evidence\n' > "$task/proof.png"
  printf 'scratch\n' > "$task/discard.bin"
  cat > "$case_dir/fakebin/gh-axi" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path
args = sys.argv[1:]
assert args[:3] == ["pr", "view", "4364"], args
assert args[args.index("--repo") + 1] == "groovejones/groove-sight-platform", args
assert args[args.index("--hostname") + 1] == "github.com", args
assert all(flag in args for flag in ("--full", "--comments", "--reviews")), args
if not Path(os.environ["REF_READY"]).exists():
    sys.exit(2)
print("body: [capture](proof.png)")
PY
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/dcg"
  REF_READY="$case_dir/ready" PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
    "$case_dir/data" "$case_dir/state" task-x1 "$case_dir/project" "$pr" \
    > "$case_dir/out" 2> "$case_dir/err" || fail "unread PR failed the cleanup pass"
  assert_present "$task/discard.bin" "unread PR moved original scratch"
  assert_absent "$task/.cleanup-hold" "unread PR created a hold"
  assert_grep "$pr" "$case_dir/err" "unread PR diagnostic omitted the URL"
  jq -e --arg pr "$pr" '.sources[-1].unread | index($pr) != null' \
    "$task/record/data-cleanup.json" >/dev/null || fail "unread PR was not recorded"
  touch "$case_dir/ready"
  REF_READY="$case_dir/ready" PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
    "$case_dir/data" "$case_dir/state" task-x1 || fail "readable PR did not retry"
  assert_present "$task/proof.png" "readable PR evidence was staged"
  assert_present "$task/.cleanup-hold/discard.bin" "PR retry omitted the recovery cycle"
  jq -e '.sources[-1].unread == []' "$task/record/data-cleanup.json" >/dev/null \
    || fail "readable PR retained stale unread state"
  pass "fm-teardown: GitHub reads use explicit PR identity and unread PRs preserve data without failing the pass"
}

test_task_data_forge_references() {
  local case_dir task provider pr
  for provider in gitlab forgejo gerrit; do
    case_dir=$(make_case "task-data-$provider")
    task="$case_dir/data/task-x1"
    mkdir -p "$task"
    printf 'description image\n' > "$task/body.png"
    printf 'discussion image\n' > "$task/comment.png"
    printf 'review image\n' > "$task/review.png"
    printf 'inline image\n' > "$task/inline.png"
    printf 'scratch\n' > "$task/discard.bin"
    cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
    chmod +x "$case_dir/fakebin/dcg"
    case "$provider" in
      gitlab)
        pr=https://gitlab.example.com/group/repo/-/merge_requests/7
        cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'mr view') printf '{"iid":7,"state":"merged","description":"[body](body.png)"}\n' ;;
  'api --hostname') printf '[{"body":"[note](comment.png) [review](review.png) [inline](inline.png)"}]\n' ;;
  *) exit 1 ;;
esac
SH
        chmod +x "$case_dir/fakebin/glab"
        ;;
      forgejo)
        pr=https://git.example.org/team/repo/pulls/7
        cat > "$case_dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'login list --output json') printf '[{"name":"fixture","url":"https://git.example.org"}]\n' ;;
  *'/pulls/7') printf '{"number":7,"state":"closed","body":"[body](body.png)"}\n' ;;
  *'/issues/7/comments?'*) printf '[{"body":"[comment](comment.png)"}]\n' ;;
  *'/pulls/7/reviews/10/comments?'*) printf '[{"body":"[inline](inline.png)"}]\n' ;;
  *'/pulls/7/reviews?'*) printf '[{"id":10,"body":"[review](review.png)"}]\n' ;;
  *) exit 1 ;;
esac
SH
        chmod +x "$case_dir/fakebin/tea"
        ;;
      gerrit)
        pr=https://review.internal/c/group/repo/+/7
        cat > "$case_dir/fakebin/gerrit-axi" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'show 7 --host review.internal --json' ] || exit 1
printf '{"ok":true,"changes":[{"change":7,"status":"MERGED","subject":"[body](body.png)","comments":[{"message":"[comment](comment.png) [review](review.png) [inline](inline.png)"}]}]}\n'
SH
        chmod +x "$case_dir/fakebin/gerrit-axi"
        ;;
    esac
    if [ "$provider" = gitlab ]; then
      write_meta "$case_dir" local-only ship
      printf 'pr=%s\n' "$pr" >> "$case_dir/state/task-x1.meta"
      run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" \
        || fail "GitLab task teardown failed: $(cat "$case_dir/err")"
    else
      PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" stage \
        "$case_dir/data" "$case_dir/state" task-x1 "$case_dir/project" "$pr" \
        || fail "$provider references refused staging"
    fi
    assert_present "$task/.cleanup-hold/discard.bin" "$provider scratch did not stage"
    if [ "$provider" = gitlab ]; then
      cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'mr view') printf '{"iid":7,"state":"merged","description":"[body](body.png)"}\n' ;;
  *) printf '{"message":"unavailable"}\n' ;;
esac
SH
      PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" expire \
        "$case_dir/data" "$case_dir/state" task-x1 > "$case_dir/out" 2> "$case_dir/err" \
        || fail "unreadable GitLab notes failed the pass"
      assert_present "$task/.cleanup-hold/discard.bin" "unreadable GitLab notes lost recovery"
      assert_grep "$pr" "$case_dir/err" "unreadable GitLab diagnostic omitted its URL"
      cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'mr view') printf '{"iid":7,"state":"merged","description":"[body](body.png)"}\n' ;;
  'api --hostname') printf '[{"body":"[note](comment.png) [review](review.png) [inline](inline.png)"}]\n' ;;
  *) exit 1 ;;
esac
SH
    fi
    PATH="$case_dir/fakebin:$PATH" python3 "$ROOT/bin/fm-task-data.py" expire \
      "$case_dir/data" "$case_dir/state" task-x1 || fail "$provider references refused expiry"
    assert_present "$task/body.png" "$provider lost description-linked evidence"
    assert_present "$task/comment.png" "$provider lost comment-linked evidence"
    assert_present "$task/review.png" "$provider lost review-linked evidence"
    assert_present "$task/inline.png" "$provider lost inline evidence"
    assert_absent "$task/.cleanup-hold" "$provider recovery did not expire"
  done
  pass "fm-teardown: GitLab, Forgejo and Gerrit references protect evidence during staging and expiry"
}

test_task_data_leaves_temporary_scratch() {
  local helper=$1 case_dir task temporary
  case_dir=$(make_case task-data-scope)
  task="$case_dir/data/finished"
  temporary="$case_dir/tmp/finished-proof"
  mkdir -p "$task/scratch" "$temporary"
  printf 'Scratch: %s\n' "$temporary" > "$task/report.md"
  printf 'data bytes\n' > "$task/scratch/blob"
  printf 'temporary bytes\n' > "$temporary/build.bin"
  cat > "$case_dir/fakebin/dcg" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
SH
  chmod +x "$case_dir/fakebin/dcg"
  TMPDIR="$case_dir/tmp" PATH="$case_dir/fakebin:$PATH" python3 "$helper" stage \
    "$case_dir/data" "$case_dir/state" finished "$case_dir/project" '' || fail "data-only staging failed"
  assert_present "$task/.cleanup-hold/scratch/blob" "data scratch was not staged"
  [ "$(cat "$temporary/build.bin")" = 'temporary bytes' ] || fail "staging changed temporary scratch"
  assert_absent "$temporary/.cleanup-hold" "staging created external recovery"
  TMPDIR="$case_dir/tmp" PATH="$case_dir/fakebin:$PATH" python3 "$helper" expire \
    "$case_dir/data" "$case_dir/state" finished || fail "data-only expiry failed"
  assert_absent "$task/.cleanup-hold" "data recovery did not expire"
  [ "$(cat "$temporary/build.bin")" = 'temporary bytes' ] || fail "expiry changed temporary scratch"
  assert_absent "$temporary/.cleanup-hold" "expiry created external recovery"
  pass "fm-teardown: data cleanup leaves named and referenced TMPDIR scratch untouched"
}

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-scope ]; then
  test_task_data_leaves_temporary_scratch "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-aliases ]; then
  test_task_data_symlink_ancestor_aliases "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-components ]; then
  test_task_data_symlink_targets "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-names ]; then
  test_task_data_filesystem_name_aliases "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-directories ]; then
  test_task_data_linked_directories "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-spellings ]; then
  test_task_data_reference_spellings "${1:-$ROOT/bin/fm-task-data.py}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-retirement ]; then
  test_task_data_discovered_pr_retirement "${1:-$ROOT}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-beads ]; then
  test_task_data_bead_backlog_sources "${1:-$ROOT}"
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-named-beads ]; then
  test_task_data_named_bead_resolution
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-legacy ]; then
  test_task_data_legacy_rows
  test_task_data_legacy_ordering
  test_task_data_legacy_reused_id
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-legacy-reuse ]; then
  test_task_data_legacy_reused_id
  test_task_data_reused_id
  test_task_data_expired_sources
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-ordering ]; then
  test_task_data_legacy_ordering
  exit 0
fi

if [ "${FM_TEARDOWN_TEST_GROUP:-}" = task-data-github ]; then
  test_task_data_github_reader
  exit 0
fi

test_task_data_legacy_rows
test_task_data_legacy_ordering
test_task_data_legacy_reused_id
test_task_data_github_reader
test_task_data_cleanup
test_task_data_large_kept_evidence
test_task_data_oversized_kept_evidence
test_task_data_stage_stops_at_its_limit
test_task_data_slow_expire_releases_locks
test_task_data_expire_skips_expired_receipts
test_task_data_expire_cut_off_hold_moves_back
test_task_data_expire_too_large_hold_skipped
test_task_data_full_attempt_uses_its_own_limit
test_task_data_refusals
test_task_data_references_and_guard
test_task_data_bead_backlog_sources
test_task_data_named_bead_resolution
test_task_data_reused_id
test_task_data_expired_sources
test_task_data_symlink_targets
test_task_data_linked_directories
test_task_data_reference_spellings
test_task_data_filesystem_name_aliases
test_task_data_symlink_ancestor_aliases "$ROOT/bin/fm-task-data.py"
test_task_data_collision_progress
test_task_data_retirement_obligation
test_task_data_discovered_pr_retirement
test_task_data_forge_references
test_task_data_leaves_temporary_scratch "$ROOT/bin/fm-task-data.py"
[ "${FM_TEARDOWN_TEST_GROUP:-}" != task-data ] || exit 0
test_local_only_fork_remote_allows
test_teardown_closes_the_backlog_item_itself
test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note
test_teardown_closes_a_gitlab_task_with_its_merge_request_url_as_a_note
test_teardown_manual_backend_leaves_the_backlog_to_the_operator
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_secondmate_pr_registration_publishes_ready_line
test_secondmate_home_teardown_delivers_final_line_or_refuses
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_herdr_teardown_presentation_lock_namespace_is_per_account
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_teardown_holds_descendant_lifecycle_locks
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_teardown_retires_task_watcher_markers_and_orphan_journal
test_teardown_retains_journal_bound_to_another_pane
test_teardown_retires_v1_journal_when_projected_workspace_gone
test_teardown_retains_v1_journal_when_projected_workspace_present
test_teardown_retains_v1_journal_when_workspace_query_ambiguous
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_forgejo_pr_allows_when_main_moved_on
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_uses_recorded_base_branch
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_untracked_only_refusal_diagnostic
test_tracked_edit_refusal_diagnostic
test_mixed_refusal_diagnostic
test_scout_nested_clone_returns_with_no_untracked_entries
test_ship_nested_clone_is_refused_and_bytes_stay
test_dirty_return_warns_which_slot_was_lost
test_dirty_return_warns_even_when_a_later_step_refuses
test_forced_secondmate_child_scout_nested_clone_returns_clean
test_forced_secondmate_dirty_child_return_warns_and_completes
test_return_that_removes_copy_warns_cannot_verify
test_scout_ignored_files_survive_scratch_clean
test_gh_error_and_content_absent_refuses
test_recorded_github_request_ignores_enterprise_host
test_recorded_request_state_decides_pushed_teardown
test_recorded_request_refuses_when_the_copy_is_gone_or_reassigned
test_legacy_record_without_the_flag_refuses
test_windowless_legacy_record_with_gone_worktree_tears_down
test_windowless_legacy_record_tears_down_with_the_legacy_flag
test_windowless_legacy_record_still_refuses_unlanded_work
test_windowless_record_outside_the_leftover_class_still_refuses
test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_teardown_records_the_task_pipeline_spend
test_teardown_skips_pipeline_spend_when_disabled
test_teardown_records_unavailable_spend_for_a_gone_worktree
test_parked_own_run_is_aborted_before_teardown
test_parked_own_run_concludes_on_passed_with_override_after_abort
test_parked_own_run_concludes_on_passed_with_skips_after_abort
test_parked_run_advanced_past_unfetched_head_is_still_aborted
test_parked_run_with_mismatched_ledger_head_is_never_aborted
test_parked_run_with_malformed_ledger_row_is_never_aborted
test_parked_run_with_impossible_ledger_date_is_never_aborted
test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback
test_parked_run_advanced_head_locally_fetched_is_still_aborted
test_parked_advanced_run_without_anchor_is_never_aborted
test_parked_advanced_run_ancestor_anchor_is_never_aborted
test_parked_terminal_unfetched_row_is_never_aborted
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted
test_parked_run_behind_diverged_newer_row_is_never_aborted
test_parked_advanced_run_ambiguous_rows_are_never_aborted
test_ledger_proven_continuation_never_aborts_active_run
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_reaps_tmux_process_group
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
