#!/usr/bin/env bash
# Smoke: one fresh spawn under its project's share launches a real worker.
ROOT=$1
. "$(dirname "$0")/lab-lib.sh"
printf '%s\n' 'alpha 1' 'beta 1' > "$LAB/config/project-capacity"
make_task "a1-$NONCE" alpha
show "spawn a1-$NONCE alpha   (alpha 1, 0 holders)"
spawn "a1-$NONCE" alpha; echo "exit=$?"
show windows; windows
show "row a1"; row_state "a1-$NONCE"
show "meta"; cat "$LAB/state/a1-$NONCE.meta"
