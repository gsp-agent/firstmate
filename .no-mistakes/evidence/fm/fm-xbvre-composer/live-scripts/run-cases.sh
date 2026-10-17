#!/usr/bin/env bash
# run-cases.sh <root> <test-function>...: run named committed cases from
# <root>/tests/fm-backend-herdr.test.sh, one process per case, with the
# composer block's FM_HERDR_VIEWPORT_ROWS=58 as the file sets it.
set -u
root=$1; shift
runner="$(dirname "$0")/runner-$$.sh"
sed -E '/^test_[a-z0-9_]+$/d' "$root/tests/fm-backend-herdr.test.sh" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$root/tests#g" > "$runner"
for t in "$@"; do
  out=$(cd "$root" && env -u HERDR_PANE_ID -u HERDR_SESSION -u NO_MISTAKES_GATE FM_HERDR_VIEWPORT_ROWS=58 bash -c '. "$1"; export FM_HERDR_VIEWPORT_ROWS=58; "$2"' _ "$runner" "$t" 2>&1); rc=$?
  printf '%s rc=%s\n%s\n' "$t" "$rc" "$(printf '%s\n' "$out" | grep -E '^(ok|not ok)' )"
done
