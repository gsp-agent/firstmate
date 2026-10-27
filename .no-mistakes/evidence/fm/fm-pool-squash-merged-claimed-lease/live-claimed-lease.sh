#!/usr/bin/env bash
# Live check of the steering skip-lease release with real Treehouse.
#
# Builds a disposable lab (bin/fm-lab-home.sh home, private tmux server,
# scratch origin/project, Treehouse pool under the lab via TREEHOUSE_ROOT,
# HOME inside the lab), then runs the real bin/fm-spawn.sh with
# --base-branch release, where origin's main is not an ancestor of release.
# Pool slot 1 is clean at origin/main and claimed by another task
# (.fm-slot-owner). A process sits in slot 1 so the spawn's exposed-claims
# read sees it in use; a logging wrapper in front of the real treehouse ends
# that process right before the spawn's first `get --lease` - the race the
# reachability note names (the claimed slot's worker ends after the
# exposed-claims read). Real Treehouse then hands slot 1 to the steering
# lease, and fm's reuse test refuses it under release.
#
# The crew worker launched at the end is a stub `codex` that prints codex's
# in-turn footer and sleeps (no model is called); the product under test is
# fm-spawn's lease handling, which runs before the worker launch.
#
# usage: live-claimed-lease.sh <worktree> <variant: clean|dirty|abort|rewritten> <spawn-rev>
#   rewritten: no --base-branch; origin's main is rewritten after slot 1 was
#          made, so slot 1's commit is not in the fetched main.
#   abort: the wrapper makes origin unreachable right before the pane's plain
#          `treehouse get`, so the start fails after steering skipped slot 1.
#   dirty: the wrapper modifies a tracked file in slot 1 right after real
#          Treehouse hands it to the steering lease (residue the release must
#          never reset away).
set -u
wt=$1 variant=$2 rev=$3
real_th=$(command -v treehouse) || { echo "treehouse missing"; exit 1; }
cd "$wt" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
LAB=$(CDPATH='' cd -- "$LAB" && pwd -P)
swapped=0
id="lablease$$$variant"
cleanup() {
  [ -z "${holder_pid:-}" ] || kill "$holder_pid" 2>/dev/null
  TMUX_TMPDIR="${TMUXDIR:-/nonexistent}" tmux -L fm-lab kill-server 2>/dev/null
  [ -z "${TMUXDIR:-}" ] || "$wt/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  [ "$swapped" = 0 ] || git -C "$wt" checkout --quiet HEAD -- bin/fm-spawn.sh
  chmod -R u+w "${LAB:?}"
  rm -rf "${LAB:?}"
  for d in /tmp/fm-"$id" /tmp/fm-"$id"+*; do
    [ ! -e "$d" ] || { chmod -R u+w "${d:?}"; rm -rf "${d:?}"; }
  done
}
trap cleanup EXIT
if [ "$rev" != HEAD ]; then
  git show "$rev:bin/fm-spawn.sh" > bin/fm-spawn.sh && swapped=1
fi
echo "== live run: variant=$variant fm-spawn.sh@$(git rev-parse --short "$rev") treehouse=$("$real_th" --version)"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
TMUXDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB") || exit 1
UH="$LAB/user-home"
S="$LAB/scratch"
mkdir -p "$UH" "$S" "$LAB/shim"
G=(-c user.name='FM Lab' -c user.email='lab@example.invalid' -c init.defaultBranch=main)

# origin: main and a divergent release (main's tip is not in release)
git "${G[@]}" init -q --bare "$S/origin.git"
git "${G[@]}" clone -q "$S/origin.git" "$S/seed" 2>/dev/null
printf 'base\n' > "$S/seed/README.md"
printf '*.log\n' > "$S/seed/.gitignore"
git -C "$S/seed" add README.md .gitignore
git "${G[@]}" -C "$S/seed" commit -qm base
git -C "$S/seed" push -q origin HEAD:main
git -C "$S/seed" checkout -q -b release
printf 'release only\n' > "$S/seed/RELEASE.md"
git -C "$S/seed" add RELEASE.md
git "${G[@]}" -C "$S/seed" commit -qm 'release work'
git -C "$S/seed" push -q origin release
git -C "$S/seed" checkout -q main
printf 'main moved on\n' >> "$S/seed/README.md"
git "${G[@]}" -C "$S/seed" commit -qam 'main work'
git -C "$S/seed" push -q origin main
git --git-dir="$S/origin.git" symbolic-ref HEAD refs/heads/main
git "${G[@]}" clone -q "$S/origin.git" "$S/proj" 2>/dev/null
PROJ="$S/proj"
main_tip=$(git -C "$PROJ" rev-parse origin/main)
git -C "$PROJ" merge-base --is-ancestor origin/main origin/release &&
  echo "setup error: main is an ancestor of release" && exit 1
echo "origin: main=${main_tip:0:8}, release=$(git -C "$PROJ" rev-parse --short origin/release); main is not an ancestor of release"

# real treehouse behind a logging wrapper; stub crew CLI
cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "$LAB/treehouse-calls.log"
if [ "\${1:-} \${2:-}" = "get --lease" ] && [ -f "$LAB/holder.pid" ]; then
  pid=\$(cat "$LAB/holder.pid"); rm -f "$LAB/holder.pid"
  kill "\$pid" 2>/dev/null
  while kill -0 "\$pid" 2>/dev/null; do sleep 0.1; done
  printf '  (wrapper: the claimed slot worker %s ended before this lease)\n' "\$pid" >> "$LAB/treehouse-calls.log"
  if [ "$variant" = dirty ]; then
    out=\$("$real_th" "\$@"); rc=\$?
    printf 'other task residue\n' >> "\$out/README.md"
    printf '  (wrapper: wrote uncommitted residue into %s)\n' "\$out" >> "$LAB/treehouse-calls.log"
    printf '%s\n' "\$out"
    exit \$rc
  fi
fi
if [ "$variant" = abort ] && [ "\$#" = 1 ] && [ "\$1" = get ]; then
  mv "$S/origin.git" "$S/origin.git.unreachable"
  printf '  (wrapper: origin made unreachable before this get)\n' >> "$LAB/treehouse-calls.log"
fi
exec "$real_th" "\$@"
SH
cat > "$LAB/shim/codex" <<'SH'
#!/usr/bin/env bash
echo "lab stub crew worker started (no model call)"
echo "stub turn running (esc to interrupt)"
exec sleep 300
SH
chmod +x "$LAB/shim/treehouse" "$LAB/shim/codex"
LABPATH="$LAB/shim:$PATH"
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE \
    HOME="$UH" CODEX_HOME= TREEHOUSE_ROOT="$LAB/pool" TMUX_TMPDIR="$TMUXDIR" \
    PATH="$LABPATH" SHELL=/bin/bash "$@"
}

# the claimed clean slot: made through real Treehouse, released, then claimed
slot=$(cd "$PROJ" && labenv treehouse get --lease --lease-holder lab-setup --no-fetch 2>/dev/null) || exit 1
(cd "$PROJ" && labenv treehouse return --if-lease-holder lab-setup "$slot" >/dev/null 2>&1) || exit 1
slot=$(CDPATH='' cd -- "$slot" && pwd -P)
printf 'task=some-other-task\nhome=%s\n' "$LAB" > "$(dirname "$slot")/.fm-slot-owner"
printf 'ignored build output\n' > "$slot/build.log"
echo "claimed slot: ${slot#"$LAB"/} at $(git -C "$slot" rev-parse --short HEAD) (origin/main), claim: task=some-other-task, ignored file build.log"
( cd "$slot" || exit 1; nohup sleep 600 >/dev/null 2>&1 & echo $! > "$LAB/holder.pid" )
holder_pid=$(cat "$LAB/holder.pid")
baseflag=(--base-branch release)
setup_block=$'# Setup\nYou are in a disposable git worktree of proj, at a detached HEAD on a clean copy of its base branch.\nBase branch: release\n'
if [ "$variant" = rewritten ]; then
  # origin's main is rewritten after the slot was made: the project's local
  # origin/main still names the slot's commit (steering passes --no-fetch),
  # but the fetched main no longer contains it. No --base-branch. The lab's
  # bare origin moves main with update-ref.
  git -C "$S/seed" reset -q --hard HEAD~1
  printf 'rewritten main\n' >> "$S/seed/README.md"
  git "${G[@]}" -C "$S/seed" commit -qam 'rewritten main'
  git -C "$S/seed" push -q origin HEAD:refs/heads/lab-rewrite
  git --git-dir="$S/origin.git" update-ref refs/heads/main "$(git -C "$S/seed" rev-parse HEAD)"
  git --git-dir="$S/origin.git" update-ref -d refs/heads/lab-rewrite
  echo "origin main rewritten to $(git -C "$S/seed" rev-parse --short HEAD); the slot's ${main_tip:0:7} is no longer in origin/main"
  baseflag=()
  setup_block=
fi
sleep 1
echo "-- treehouse status before the spawn (claimed slot has a live process in it):"
(cd "$PROJ" && labenv "$real_th" status --json 2>/dev/null) | jq -c '.[] | {name, status, path: (.path | sub(".*/pool/"; "pool/"))}'

# lab home config, brief, private tmux server
printf 'codex\n' > "$LAB/config/crew-harness"
mkdir -p "$LAB/data/$id"
cat > "$LAB/data/$id/brief.md" <<EOF
Decision owner: ep-sample

${setup_block}
# Task
## Captain's intent
Lab check of the steering skip-lease release for $id.

## Firstmate spec
Nothing to build; the worker is a stub.
EOF
touch "$LAB/state/.last-watcher-beat"
labenv tmux -L fm-lab -f /dev/null new-session -d -s primary -x 200 -y 50 -c "$PROJ" || exit 1
tmuxval=$(TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab display -p -t primary '#{socket_path},#{pid},0')

echo "-- fm-spawn.sh $id <project> --mode no-mistakes --yolo off ${baseflag[*]:-} --backend tmux"
rc=0
out=$(cd "$PROJ" && labenv FM_HOME="$LAB" TMUX="$tmuxval" FM_SPAWN_NO_GUARD=1 \
  "$wt/bin/fm-spawn.sh" "$id" "$PROJ" --mode no-mistakes --yolo off ${baseflag[@]+"${baseflag[@]}"} --backend tmux 2>&1) || rc=$?
printf '%s\n' "$out" | sed "s#$LAB/#<lab>/#g" | tail -15
echo "spawn exit: $rc"
echo "-- treehouse calls (wrapper log):"
sed "s#$LAB/#<lab>/#g" "$LAB/treehouse-calls.log"
echo "-- after the spawn (holder process gone: $(kill -0 "$holder_pid" 2>/dev/null && echo no || echo yes)):"
(cd "$PROJ" && labenv "$real_th" status --json 2>/dev/null) | jq -c '.[] | {name, status, path: (.path | sub(".*/pool/"; "pool/"))}'
state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
holder=$(jq -r --arg p "$slot" '.worktrees[] | select(.path == $p) | .lease_holder // ""' "$state")
leased=$(jq -r --arg p "$slot" '.worktrees[] | select(.path == $p) | .leased // false' "$state")
echo "claimed slot lease in treehouse-state.json: leased=$leased holder='${holder}'"
echo "claimed slot claim file: $(tr '\n' ' ' < "$(dirname "$slot")/.fm-slot-owner" | sed "s#$LAB#<lab>#g")"
echo "claimed slot HEAD: $(git -C "$slot" rev-parse --short HEAD) (origin/main ${main_tip:0:8}); status: '$(git -C "$slot" status --porcelain | tr '\n' ' ')'"
[ -e "$slot/build.log" ] && echo "ignored build.log: present" || echo "ignored build.log: gone"
if [ -f "$LAB/state/$id.meta" ]; then
  echo "task record: $(grep -E '^(worktree|base_branch)=' "$LAB/state/$id.meta" | sed "s#$LAB/#<lab>/#g" | tr '\n' ' ')"
fi
if [ "$rev" != HEAD ] && [ "$holder" = "fm-spawn-$id" ]; then
  echo "-- adversarial: real treehouse return with the wrong lease holder"
  (cd "$PROJ" && labenv "$real_th" return --if-lease-holder "fm-spawn-someone-else" "$slot" 2>&1 | sed "s#$LAB/#<lab>/#g" | tail -2); echo "exit: ${PIPESTATUS[0]}"
  echo "holder now: '$(jq -r --arg p "$slot" '.worktrees[] | select(.path == $p) | .lease_holder // ""' "$state")'"
fi
win=$(TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab list-windows -t primary -F '#{window_name}' | grep -F "fm-$id" | head -1)
if [ -n "$win" ]; then
  echo "-- worker window $win (last lines):"
  TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab capture-pane -p -t "primary:$win" | grep -v '^$' | sed "s#$LAB/#<lab>/#g" | tail -6
fi
