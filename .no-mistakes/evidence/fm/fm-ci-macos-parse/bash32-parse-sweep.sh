#!/bin/bash
# Mirrors the "Stock macOS Bash snapshot compatibility" CI job's parse sweep:
# every shell file bin/fm-lint.sh lists must parse under stock /bin/bash 3.2.
# Also parses the base (upstream-lean 9ed80766) copy of the file that broke it.
set -u
cd "$1"
echo "stock bash: $(/bin/bash --version | head -1)"
echo "head: $(git rev-parse --short HEAD)"
inv=$(mktemp "${TMPDIR:-/tmp}/fm-shell-inventory.XXXXXX")
CI=true bin/fm-lint.sh --list-files > "$inv"  # CI context: the full canonical set
echo "files in inventory: $(wc -l < "$inv" | tr -d ' ')"
fail=0
while IFS= read -r f; do
  /bin/bash -n "$f" || { echo "FAIL: stock macOS Bash 3.2 failed to parse $f"; fail=1; }
done < "$inv"
rm -f "$inv"
[ "$fail" -eq 0 ] && echo "PASS: every inventoried shell file parses under stock Bash 3.2 at HEAD"
echo "--- failing-first: the base copy of tests/fm-pi-watch-extension.test.sh"
base=$(mktemp "${TMPDIR:-/tmp}/fm-pi-watch-base.XXXXXX")
git show 9ed80766:tests/fm-pi-watch-extension.test.sh > "$base"
if /bin/bash -n "$base"; then echo "base parsed (unexpected)"; else echo "base copy FAILS to parse under stock Bash 3.2 (expected, the reported red)"; fi
rm -f "$base"
/bin/bash -n tests/fm-pi-watch-extension.test.sh && echo "HEAD copy of tests/fm-pi-watch-extension.test.sh parses under stock Bash 3.2"
exit "$fail"
