#!/usr/bin/env bash
# usage: teardown-hold.sh <seconds> <log-label>
# Runs a REAL bin/fm-teardown.sh on a lab task (victim) and keeps it holding
# the home's lease-command lock for <seconds>: the teardown takes the lease
# guard first, then waits with no bound on the task's meta lock, which a
# helper in the lab tmux holds for <seconds>. It runs as the main actor, as
# main's own teardown on a home that runs the host does. Both run as windows of the lab's
# private tmux server, so any tmux call the teardown makes stays in the lab.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
T=${TMPDIR%/}
LAB=$(cat "$T/fm-lab-zdz2i-current")
ROOT=$(cd -P "$(cat "$T/fm-root-zdz2i-current")" && pwd -P)
secs=$1 label=$2
tm() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
printf 'project=victim\nwindow=fm-victim\nharness=claude\nkind=ship\n' > "$LAB/state/victim.meta"
rm -f "$LAB/meta-held"
tm new-window -d -n metahold "FM_HOME='$LAB' bash -c '. \"\$1/bin/fm-wake-lib.sh\"; l=\$(fm_meta_lock_path \"\$2/state/victim.meta\"); fm_lock_acquire_wait \"\$l\"; date -u +%T > \"\$2/meta-held\"; sleep \"\$3\"; fm_lock_release \"\$l\"' _ '$ROOT' '$LAB' '$secs'"
for _ in $(seq 1 50); do [ -s "$LAB/meta-held" ] && break; sleep 0.2; done
[ -s "$LAB/meta-held" ] || { echo "meta lock holder never started" >&2; exit 1; }
tm new-window -d -n teardown "cd '$ROOT' && FM_HOME='$LAB' FM_SUPERVISION_ACTOR=main '$ROOT/bin/fm-teardown.sh' victim > '$EV/teardown-$label.log' 2>&1; echo \"teardown rc=\$? at \$(date -u +%T)\" >> '$EV/teardown-$label.log'"
for _ in $(seq 1 50); do [ -s "$LAB/state/.fm-lease-command.lock/pid" ] && break; sleep 0.2; done
holder=$(cat "$LAB/state/.fm-lease-command.lock/pid" 2>/dev/null || true)
printf '%s lease-command lock holder pid=%s: %s\n' "$(date -u +%T)" "${holder:-none}" "$(ps -o args= -p "${holder:-0}" 2>/dev/null | cut -c1-140)"
