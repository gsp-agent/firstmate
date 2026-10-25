#!/bin/bash
# Runs selected tests from <tree>/tests/fm-bearings-snapshot.test.sh under
# stock /bin/bash with the stock-bash gate's PATH, each in its own subshell,
# and prints ok/not-ok, per-test seconds, and the load average at start.
# Usage: run-bearings-tests.sh <tree> <test-file> <test_fn>...
set -u
tree=$1 testfile=$2
shift 2
case "$BASH_VERSION" in 3.2.57*) ;; *) echo "not stock bash: $BASH_VERSION"; exit 2 ;; esac
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-only.XXXXXX") || exit 2
sed -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$tree/tests/lib.sh#" \
    -e '/^test_[A-Za-z0-9_]*$/d' "$testfile" > "$scratch/bearings-only.sh"
PATH="/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$(dirname "$(command -v tasks-axi)")"
export PATH
printf 'bash=%s resolved=%s tree=%s\n' "$BASH_VERSION" "$(command -v bash)" "$tree"
printf 'load at start: %s\n' "$(sysctl -n vm.loadavg)"
# shellcheck disable=SC1090
. "$scratch/bearings-only.sh"
rm -f "${scratch:?}/bearings-only.sh"; rmdir "${scratch:?}"
[ -n "${EXTRA_DEFS:-}" ] && . "$EXTRA_DEFS"
failed=0
for t in "$@"; do
  s=$SECONDS
  ( "$t" ) 2>&1
  rc=$?
  printf '  -> %s rc=%s %ss (load %s)\n' "$t" "$rc" "$((SECONDS - s))" "$(sysctl -n vm.loadavg)"
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
printf 'failed=%s of %s\n' "$failed" "$#"
exit "$failed"
