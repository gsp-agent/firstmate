#!/usr/bin/env bash
# Disposable probe: a red suite run with a real watcher held before its pid write.
# Sources the suite from this copy, so suite_cleanup is the code under test.
# PROBE_VARIANT: under-arm | reparented | orphaned-arm | own-group-orphaned-arm
# PROBE_OUT: directory outside the suite's tree that keeps pids for the driver.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
. "$SELF_DIR/fm-supervision-host.test.sh"
variant=${PROBE_VARIANT:?}
out=${PROBE_OUT:?}
home=$TMP_ROOT/probe-home
mkdir -p "$home/state"
printf '%s\n' "$home" >> "$HOMES_FILE"
held_bin=$TMP_ROOT/held-bin
mkdir -p "$held_bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$held_bin/${f##*/}"; done
rm -f "$held_bin/fm-secondmate-liveness-lib.sh"
{
  printf '%s\n' 'echo "$$" > "$FM_HOME/watcher-held"' '_fm_held_polls=0'
  printf 'while [ "$_fm_held_polls" -lt %s ]; do\n' "$((FM_TEST_STUB_MAX_BLOCK_SECONDS * 10))"
  printf '%s\n' '  sleep 0.1' '  _fm_held_polls=$((_fm_held_polls + 1))' 'done'
  printf '. "%s"\n' "$ROOT/bin/fm-secondmate-liveness-lib.sh"
} > "$held_bin/fm-secondmate-liveness-lib.sh"
case "$variant" in
  under-arm)
    ( FM_HOME="$home" "$held_bin/fm-watch.sh" > "$home/watcher.out" 2>&1 & wait ) &
    printf 'arm\t%s\n' "$!" > "$home/state/.supervision-host"
    ;;
  reparented)
    ( FM_HOME="$home" "$held_bin/fm-watch.sh" > "$home/watcher.out" 2>&1 & ) &
    wait "$!"
    ;;
  orphaned-arm)
    (
      FM_HOME="$home" FM_ARM_CONFIRM_TIMEOUT="$FM_TEST_STUB_MAX_BLOCK_SECONDS" \
        "$held_bin/fm-watch-arm.sh" > "$home/arm.out" 2>&1 &
      printf '%s\n' "$!" > "$home/arm.pid"
    ) &
    wait "$!"
    ;;
  own-group-orphaned-arm)
    (
      set -m
      FM_HOME="$home" FM_ARM_CONFIRM_TIMEOUT="$FM_TEST_STUB_MAX_BLOCK_SECONDS" \
        "$held_bin/fm-watch-arm.sh" > "$home/arm.out" 2>&1 </dev/null &
      printf '%s\n' "$!" > "$home/arm.pid"
    ) &
    wait "$!"
    ;;
  *) fail "unknown variant $variant" ;;
esac
wait_until 900 test -s "$home/watcher-held" || fail "probe: the watcher never reached its hold"
cp "$home/watcher-held" "$out/watcher.pid"
[ ! -e "$home/arm.pid" ] || cp "$home/arm.pid" "$out/arm.pid"
LC_ALL=C ps -o lstart= -p "$(cat "$out/watcher.pid")" > "$out/watcher.lstart"
if [ -e "$home/state/.watch.lock/pid" ]; then echo present > "$out/lockpid"; else echo absent > "$out/lockpid"; fi
{
  printf 'suite pid=%s pgid=%s\n' "$$" "$(ps -o pgid= -p "$$" | tr -d ' ')"
  printf 'watcher pid=%s pgid=%s ppid=%s\n' "$(cat "$out/watcher.pid")" \
    "$(ps -o pgid= -p "$(cat "$out/watcher.pid")" | tr -d ' ')" "$(ps -o ppid= -p "$(cat "$out/watcher.pid")" | tr -d ' ')"
  printf 'state/.watch.lock/pid: %s\n' "$(cat "$out/lockpid")"
} > "$out/held-state"
printf 'probe: before cleanup\n'
trap 'suite_cleanup; printf "probe: after cleanup\n"' EXIT
fail "forced red while a watcher is still starting ($variant)"
