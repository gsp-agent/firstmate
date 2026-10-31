#!/usr/bin/env bash
# A person runs a suite at a terminal, stdin a tty of the given width, and it goes red
# with a watcher still starting. Shape "plain": output to the terminal. Shape "tail":
# `| tail`, so the suite leads its group with the reader in that group, the reader's
# parent being the interactive shell.
# usage: terminal.sh <copy> <variant> <cols> <plain|tail>
set -u
copy=$1
variant=$2
cols=$3
shape=$4
drivers=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
out=$(mktemp -d "$copy/.probe-out.XXXXXX")
pipe=
[ "$shape" = tail ] && pipe='2>&1 | tail -5'
python3 -I "$drivers/pty-run.py" "$cols" 900 \
  "cd '$copy' && PROBE_OUT='$out' PROBE_VARIANT='$variant' bash tests/zz-probe-held.test.sh $pipe; echo pty-status=\$?"
printf -- '--- suite ran with a %s-column tty on stdin, shape %s\n' "$cols" "$shape"
cat "$out/held-state" 2>/dev/null
bash "$drivers/check-survivors.sh" "$out" 0 5
printf 'survivor check exit: %s\n' "$?"
