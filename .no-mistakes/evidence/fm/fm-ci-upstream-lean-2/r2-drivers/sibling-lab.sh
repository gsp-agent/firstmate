#!/usr/bin/env bash
# Real fm-spawn ship spawn whose branch is held by a sibling worktree, in a
# disposable lab home on a private tmux socket. Prints LAB; caller tears down.
set -u
WT=$1 OUT=$2
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "LAB=$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/treehouse"
P="$LAB/projects/proj"
git init -q -b main "$P"; printf 'lab project\n' > "$P/README.md"
git -C "$P" add README.md; git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial
git clone -q --bare "$P" "$LAB/origin.git"; git -C "$P" remote add origin "file://$LAB/origin.git"; git -C "$P" fetch -q origin
printf '%s\n' '- proj [no-mistakes] - lab fixture (added 2026-10-16)' > "$LAB/data/projects.md"
TAG=lab$(printf '%s' "$LAB" | shasum | cut -c1-5); SIB=$TAG-sib CTL=$TAG-ctl
for id in "$SIB" "$CTL"; do
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLab check of ship branch preparation.\n\n## Firstmate spec\nLab-only verification.\n' > "$LAB/data/$id/brief.md"
done
S="$LAB/sibling"
git -C "$P" worktree add -q -b "fm/$SIB" "$S"
printf 'uncommitted sibling work\n' > "$S/uncommitted.txt"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 220 -y 50 -c "$WT" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$LAB/treehouse" bash --noprofile --norc || exit 1
waitfile() { local f=$1 i=0; while [ ! -s "$f" ] && [ "$i" -lt 180 ]; do sleep 1; i=$((i+1)); done; }
snap() { echo "branch=$(git -C "$S" branch --show-current) HEAD=$(git -C "$S" rev-parse --short=12 HEAD) fm/$SIB=$(git -C "$P" rev-parse --short=12 "fm/$SIB") status=[$(git -C "$S" status --porcelain | tr '\n' ' ')]"; }
{
echo "lab home: $LAB (marked: $([ -f "$LAB/.fm-lab-home" ] && echo yes || echo no))"
echo "lab tmux socket: $(T display -p '#{socket_path}')"
echo
echo "=== 1. ship spawn whose branch fm/$SIB is checked out in a sibling worktree"
echo "before: $(snap)"
T send-keys -t primary "FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $SIB $P \"sh -c 'while :; do sleep 60; done'\" --mode local-only --yolo off > $LAB/sib.out 2>&1; echo \$? > $LAB/sib.rc" Enter
waitfile "$LAB/sib.rc"
echo "\$ bin/fm-spawn.sh $SIB <project> \"sh -c 'while :; do sleep 60; done'\" --mode local-only --yolo off  -> exit $(cat "$LAB/sib.rc")"
sed 's/^/  | /' "$LAB/sib.out"
echo "after:  $(snap)"
echo "sibling dirty file: $(cat "$S/uncommitted.txt")"
echo "state/$SIB.meta present: $([ -e "$LAB/state/$SIB.meta" ] && echo yes || echo no)"
echo "worker windows: $(T list-windows -a -F '#{window_name}' | tr '\n' ' ')"
echo "git worktree list:"; git -C "$P" worktree list | sed 's/^/  /'
echo
echo "=== 2. control: ship spawn $CTL with no branch held elsewhere"
T send-keys -t primary "FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $CTL $P \"sh -c 'while :; do sleep 60; done'\" --mode local-only --yolo off > $LAB/ctl.out 2>&1; echo \$? > $LAB/ctl.rc" Enter
waitfile "$LAB/ctl.rc"
echo "exit: $(cat "$LAB/ctl.rc")"
sed 's/^/  | /' "$LAB/ctl.out"
C=$(sed -n 's/^worktree=//p' "$LAB/state/$CTL.meta" 2>/dev/null)
echo "control slot branch: $(git -C "${C:-/nonexistent}" branch --show-current 2>/dev/null)"
} > "$OUT" 2>&1
T kill-server 2>/dev/null
echo "TAG=$TAG"
