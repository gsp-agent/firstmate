#!/usr/bin/env bash
# Drive the real Stop hook (bin/fm-claude-stop-autoarm.sh) at <commit> through
# five postures and print each full rewake banner and exit code, so the base
# and head banners can be compared byte for byte. Uses the change head's
# fixtures from tests/fm-claude-stop-autoarm.test.sh (fake harness owning the
# home's lock, a host engine stand-in that hands the wake back).
# Usage: stop-banner-diff.sh <worktree> <commit>
set -u
wt=$1 commit=$2
out=$(mktemp -d "${TMPDIR:-/tmp}/fm-stop-banner.XXXXXX") || exit 1
cd "$wt" || exit 1
git archive --format=tar "$commit" bin tests | tar -x -C "$out"
git show 527b9c60:tests/fm-claude-stop-autoarm.test.sh \
  | awk '/^run_case test_[a-z0-9_]+$/ { next } /^test_[a-z0-9_]+$/ { next } { print }' \
  > "$out/tests/banner-driver.test.sh"
cat >> "$out/tests/banner-driver.test.sh" <<'DRIVER'

banner_case() {  # <name> <host on|off> <record none|empty|away|quiet> <fixture>
  local name=$1 host=$2 record=$3 kind=$4 dir rc
  dir=$(make_primary_dir "$TMP_ROOT/banner-$name")
  [ "$host" = off ] || rm -f "$dir/config/supervision-host-off"
  : > "$dir/state/task.meta"
  case "$record" in
    empty) : > "$dir/state/.afk-contract" ;;
    away) FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" enter --words 'away for the day' >/dev/null 2>&1 ;;
    quiet) FM_HOME="$dir" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 ;;
  esac
  if [ "$kind" = handed-back ]; then write_host_fixture "$dir" handed-back; else write_arm_fixture "$dir" "$kind"; fi
  printf -- '--- %s (host %s, record %s)\n' "$name" "$host" "$record"
  run_autoarm "$dir" 2>/dev/null; rc=$?
  printf 'EXIT=%s\n' "$rc"
}
banner_case host-away-record on away handed-back
banner_case host-damaged-record on empty handed-back
banner_case host-quiet-record on quiet handed-back
banner_case host-no-record on none handed-back
banner_case hostoff-away-record off away actionable
DRIVER
bash "$out/tests/banner-driver.test.sh" 2>&1
rm -rf "${out:?}"
