#!/bin/bash
set -u
export TMPDIR="$PWD/.test-phase-tmp"
. tests/fm-watch-arm.test.sh
mkdir -p "$TMP_ROOT/baseline"
cp -R bin "$TMP_ROOT/baseline/"
git show 48f35d6b^:bin/fm-watch-arm.sh > "$TMP_ROOT/baseline/bin/fm-watch-arm.sh"
chmod +x "$TMP_ROOT/baseline/bin/fm-watch-arm.sh"
WATCH_ARM="$TMP_ROOT/baseline/bin/fm-watch-arm.sh"
printf 'Negative control: the pre-fix arm at 48f35d6b^ under the current long-main-turn replay\n'
test_successor_left_for_main_covers_the_whole_turn
