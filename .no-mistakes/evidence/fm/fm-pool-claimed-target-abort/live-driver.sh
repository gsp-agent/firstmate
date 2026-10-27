#!/usr/bin/env bash
# live-driver.sh <fm-root> <scenario> <label>
#
# Drives the real bin/fm-spawn.sh from <fm-root> against a disposable lab:
# a marked lab FM_HOME (bin/fm-lab-home.sh), a private tmux server on its own
# socket (TMUX_TMPDIR=$LAB/tmux, -L fm-lab), a local bare origin, a project
# whose treehouse.toml points real Treehouse (v2.3.0) at a pool inside the lab,
# and one own-clone pool slot that an earlier, finished task still claims
# (.fm-slot-owner task=old-finished-task).
#
# Real Treehouse never hands out a slot while a process runs in it, and
# fm-spawn defers when a claimed slot reads `available` before it asks the
# allocator, so the claimed slot reaches the lease steering only when its last
# process ends between that pool read and `treehouse get --lease`. The lab
# models that ending exactly: a stand-in process for the finished task's worker
# sits in the slot, and a pass-through wrapper in front of the real treehouse
# ends that process just before the first `get --lease`, then execs the real
# treehouse with the same arguments. Every Treehouse call (status, get --lease,
# enter, return) is the real binary.
#
# Scenarios:
#   abort    the task pane's Treehouse resolves a different pool
#            (TREEHOUSE_ROOT in the lab tmux global environment only), so the
#            real `treehouse enter '<n>'` fails with "no worktree named", the
#            pane never settles, and fm-spawn aborts at its 60s deadline.
#   refusal  the pane really enters the slot; a lab live-session detector
#            (FM_LIVE_SESSION_CHECK, the documented hook) reports a live
#            session and writes an uncommitted file into the slot, so the ship
#            spawn refuses with the slot checked out and dirty. Treehouse leases
#            the slot as /var/folders/... while tmux reports the pane as
#            /private/var/folders/..., the two spellings of one path on macOS.
#
# Prints the lab path on its last line as LAB=<path>; the caller removes it.
set -u
FMROOT=$1
SCEN=$2
LABEL=$3
GATE_WT=/Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5YWVH77WQNW75CCNAXKV33B
REAL_TH=/Users/dalecarman/.local/bin/treehouse
ID="lab-claimed-$LABEL"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
LAB=${LAB//\/\//\/}
"$GATE_WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/shim" "$LAB/data/$ID"
printf 'codex\n' >"$LAB/config/crew-harness"
touch "$LAB/state/.last-watcher-beat"
export HOME="$LAB/user-home" GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=fm-lab -c user.email=fm-lab@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false)
P="$LAB/projects/demo"

section() { printf '\n===== %s =====\n' "$*"; }

section "lab: $LABEL (scenario=$SCEN, fm-root=$FMROOT)"
echo "fm-root HEAD: $(git -C "$FMROOT" rev-parse --short HEAD 2>/dev/null || echo "archive of base commit")"
echo "treehouse: $("$REAL_TH" --version 2>/dev/null | tail -n 1)"

"${G[@]}" init -q --bare "$LAB/origin.git"
"${G[@]}" init -q "$P"
"${G[@]}" -C "$P" remote add origin "$LAB/origin.git"
printf 'max_trees = 4\nroot = "%s/poolroot"\n' "$LAB" >"$P/treehouse.toml"
printf '# demo\n' >"$P/README.md"
"${G[@]}" -C "$P" add README.md treehouse.toml
"${G[@]}" -C "$P" commit -qm init
"${G[@]}" -C "$P" push -q origin main
"${G[@]}" -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

# The earlier task's slot: leased and returned once so Treehouse made it, then
# claimed by that task and occupied by a stand-in for its worker.
SLOT=$(cd "$P" && "$REAL_TH" get --lease --lease-holder fm-spawn-old-finished-task --no-fetch 2>/dev/null </dev/null)
(cd "$P" && "$REAL_TH" return "$SLOT" >/dev/null 2>&1 </dev/null)
SLOT_NAME=$(basename "$(dirname "$SLOT")")
printf 'task=old-finished-task\nhome=%s\n' "$LAB" >"$(dirname "$SLOT")/.fm-slot-owner"
( (cd "$SLOT" && exec sleep 900) </dev/null >/dev/null 2>&1 & echo $! >"$LAB/holder.pid" )
for _ in 1 2 3 4 5 6 7 8 9 10; do
  st=$(cd "$P" && "$REAL_TH" status --json 2>/dev/null | jq -r --arg n "$SLOT_NAME" '.[] | select(.name == $n) | .status')
  [ "$st" = in-use ] && break
  sleep 0.5
done

cat >"$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LAB/treehouse-calls.log"
if [ "\${1:-}" = get ] && [ "\${2:-}" = --lease ] && [ -f "$LAB/holder.pid" ]; then
  pid=\$(cat "$LAB/holder.pid")
  rm -f "$LAB/holder.pid"
  kill "\$pid" 2>/dev/null
  while kill -0 "\$pid" 2>/dev/null; do sleep 0.05; done
  printf '%s\n' "(lab) stand-in worker \$pid in the claimed slot ended just before this get --lease" >>"$LAB/treehouse-calls.log"
fi
exec "$REAL_TH" "\$@"
SH
chmod +x "$LAB/shim/treehouse"

DETECTOR=
if [ "$SCEN" = refusal ]; then
  DETECTOR="$LAB/live-session.py"
  cat >"$DETECTOR" <<PY
with open("$SLOT/keep-me.txt", "w") as handle:
    handle.write("keep\n")
print("live signal=person source=lab")
raise SystemExit(75)
PY
fi

cat >"$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise a spawn that steers into a claimed own-clone pool slot.

## Firstmate spec
Exercise the spawn behavior under test.
EOF

section "before spawn: real treehouse status --json (project dir)"
(cd "$P" && "$REAL_TH" status --json 2>/dev/null | jq -c '.[] | {name, status, lease_holder, processes: [.processes[]?.name]}')
section "before spawn: claim beside slot $SLOT_NAME"
cat "$(dirname "$SLOT")/.fm-slot-owner"
echo "slot path as Treehouse leases it: $SLOT"
echo "same slot, physical spelling:      $(cd "$SLOT" && pwd -P)"

T=(env TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab)
env -i HOME="$LAB/user-home" USER="$USER" LOGNAME="$USER" \
  PATH="$LAB/shim:$(dirname "$REAL_TH"):/Users/dalecarman/.agent-config/tools-bin/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  TERM=xterm-256color SHELL=/bin/bash LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" TMUX_TMPDIR="$LAB/tmux" \
  tmux -L fm-lab -f /dev/null new-session -d -s primary -x 200 -y 50 -c "$FMROOT" -e FM_HOME="$LAB" \
  "bash --noprofile --norc" || { echo "could not start the lab tmux server"; echo "LAB=$LAB"; exit 1; }
if [ "$SCEN" = abort ]; then
  # Only panes created from now on - the task window - see the other pool.
  "${T[@]}" set-environment -g TREEHOUSE_ROOT "$LAB/pane-pool"
fi

q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
cmd="FM_LIVE_SESSION_CHECK=$(q "$DETECTOR") CODEX_HOME= $(q "$FMROOT/bin/fm-spawn.sh") $(q "$ID") $(q "$P") --mode no-mistakes --yolo off >$(q "$LAB/spawn.out") 2>&1; echo \$? >$(q "$LAB/spawn.rc")"
"${T[@]}" send-keys -t primary "$cmd" Enter
start=$(date +%s)
while [ ! -s "$LAB/spawn.rc" ] && [ $(( $(date +%s) - start )) -lt 300 ]; do sleep 2; done

section "fm-spawn.sh exit status (after $(( $(date +%s) - start ))s)"
cat "$LAB/spawn.rc" 2>/dev/null || echo "(no exit status within 300s)"
section "fm-spawn.sh output"
cat "$LAB/spawn.out" 2>/dev/null
section "lab tmux windows"
"${T[@]}" list-windows -a -F '#{session_name}:#{window_name} cwd=#{pane_current_path}' 2>/dev/null
for w in $("${T[@]}" list-windows -a -F '#{window_id}:#{window_name}' 2>/dev/null | grep ":fm-$ID\$" | cut -d: -f1); do
  section "task window $w pane (tmux capture-pane)"
  "${T[@]}" capture-pane -p -t "$w" 2>/dev/null | sed -e '/^[[:space:]]*$/d'
done
section "treehouse calls made by fm-spawn and its pane (lab wrapper log)"
cat "$LAB/treehouse-calls.log" 2>/dev/null
section "after spawn: real treehouse status --json (project dir)"
(cd "$P" && "$REAL_TH" status --json 2>/dev/null | jq -c '.[] | {name, status, lease_holder, processes: [.processes[]?.name]}')
section "after spawn: claim beside slot $SLOT_NAME"
if [ -e "$(dirname "$SLOT")/.fm-slot-owner" ]; then cat "$(dirname "$SLOT")/.fm-slot-owner"; else echo "(no .fm-slot-owner claim)"; fi
section "after spawn: slot $SLOT_NAME checkout"
git -C "$SLOT" status --short --branch --untracked-files=all
[ ! -f "$SLOT/keep-me.txt" ] || echo "keep-me.txt: $(cat "$SLOT/keep-me.txt")"
section "after spawn: task record"
if [ -e "$LAB/state/$ID.meta" ]; then echo "state/$ID.meta present"; else echo "state/$ID.meta absent"; fi
if [ "$SCEN" = abort ]; then
  section "pool hands the slot out again at once (real treehouse get --lease)"
  again=$(cd "$P" && "$REAL_TH" get --lease --lease-holder lab-recheck --no-fetch 2>/dev/null </dev/null)
  echo "leased: $again"
  if [ "$again" = "$SLOT" ]; then echo "same slot $SLOT_NAME handed out again"; else echo "a different slot was handed out (the claimed slot was not free)"; fi
  [ -z "$again" ] || (cd "$P" && "$REAL_TH" return "$again" >/dev/null 2>&1 </dev/null)
fi

"${T[@]}" kill-server 2>/dev/null || true
[ ! -f "$LAB/holder.pid" ] || kill "$(cat "$LAB/holder.pid")" 2>/dev/null || true
section "lab teardown"
"${T[@]}" list-sessions >/dev/null 2>&1 && echo "lab tmux server still running" || echo "lab tmux server stopped"
echo "LAB=$LAB"
