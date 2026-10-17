#!/usr/bin/env bash
# s3d: timestamped xtrace of one `route-due human` row; prints the slowest steps.
set -u
. "$(dirname "$0")/lab-lib.sh"
LAB=$1
cd "$WT" || exit 1
trace=$(mktemp "${TMPDIR:-/tmp}/fm-trace.XXXXXX")
PS4='+ $(perl -MTime::HiRes=time -e "printf q(%.2f), time") ${BASH_SOURCE##*/}:${LINENO}: ' \
  lab_env "$LAB" 2026-10-14T02:25:00Z bash -x "$WT/bin/fm-captain-hold.sh" route-due human 2> "$trace"
echo "exit $?"
perl -ne 'if (/^\++ (\d+\.\d+) (\S+) (.*)/) { if (defined $pt) { printf "%6.2fs  %s %s\n", $1-$pt, $pl, substr($px,0,160) } ($pt,$pl,$px)=($1,$2,$3) }' "$trace" | sort -rn | head -12
cp "$trace" "$LAB/route-due-human.trace"
