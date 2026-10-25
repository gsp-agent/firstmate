#!/bin/bash
# Round 2 live scenarios for the CPU-time scan budgets.
# Builds a disposable Domain Alpha fixture home (the bearings suite's own
# fixture builders), then drives the real bin/fm-fleet-snapshot.sh and
# bin/fm-bearings-snapshot.sh of <tree> under stock /bin/bash with PATH fakes
# for stat (parent-activity read) and head (registry read) that either wait,
# burn CPU, or fail. Prints one line per scenario with the observed JSON
# fields, the wall time, and the SIGXCPU disposition each fake saw.
# Usage: snapshot-scenarios.sh <tree> <label>
set -u
tree=$1 label=$2
case "$BASH_VERSION" in 3.2.57*) ;; *) echo "not stock bash: $BASH_VERSION"; exit 2 ;; esac
PATH="/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$(dirname "$(command -v tasks-axi)")"
export PATH
GUARD_LIB=/Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF/bin/fm-timeout-lib.sh

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-r2-scen.XXXXXX") || exit 2
sed -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$tree/tests/lib.sh#" \
    -e '/^test_[A-Za-z0-9_]*$/d' "$tree/tests/fm-bearings-snapshot.test.sh" > "$scratch/defs.sh"
# shellcheck disable=SC1090,SC1091
. "$scratch/defs.sh"
rm -f "${scratch:?}/defs.sh"; rmdir "${scratch:?}"
# Outer safety wall for this driver only, so a hang cannot stall the probe.
# shellcheck disable=SC1090
. "$GUARD_LIB"

printf '[%s] tree=%s bash=%s resolved=%s load=%s\n' "$label" "$tree" "$BASH_VERSION" "$(command -v bash)" "$(sysctl -n vm.loadavg)"

home=$(make_home r2-domain-alpha)
mate="$TMP_ROOT/r2-domain-alpha-home"
write_domain_alpha_fixture "$home" "$mate"
fakebin=$(make_fakebin "$home")
: > "$home/net.log"
DISP_LOG="$home/xcpu.log"
export DISP_LOG
cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'snapshot:%s\n' "$(perl -e 'print defined $SIG{XCPU} ? $SIG{XCPU} : "DEFAULT"')" >> "$DISP_LOG"
printf 'Linux\n'
SH
cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  '-c %a') printf '600\n' ;;
  '-c %Y') printf '1783792800\n' ;;
  '-c %s')
    printf 'stat:%s\n' "$(perl -e 'print defined $SIG{XCPU} ? $SIG{XCPU} : "DEFAULT"')" >> "$DISP_LOG"
    case "${STAT_MODE:-pass}" in
      wait) sleep 3; LC_ALL=C wc -c < "$3" | tr -d ' ' ;;
      burn) while :; do :; done ;;
      error) exit 1 ;;
      *) LC_ALL=C wc -c < "$3" | tr -d ' ' ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
cat > "$fakebin/head" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *data/secondmates.md)
    printf 'head:%s\n' "$(perl -e 'print defined $SIG{XCPU} ? $SIG{XCPU} : "DEFAULT"')" >> "$DISP_LOG"
    case "${REGISTRY_READ_MODE:-pass}" in
      wait) sleep 3 ;;
      burn) while :; do :; done ;;
      error) exit 7 ;;
    esac
    ;;
esac
exec /usr/bin/head "$@"
SH
chmod +x "$fakebin/uname" "$fakebin/stat" "$fakebin/head"

# snap <name> <launcher: plain|xcpu-ignored> <VAR=value...>
snap() {
  local name=$1 launcher=$2 started rc=0 out pa reg disp
  shift 2
  : > "$DISP_LOG"
  started=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  if [ "$launcher" = xcpu-ignored ]; then
    out=$(fm_run_timed 240 env PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" FAKE_GH_FAIL=1 \
      FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 "$@" \
      perl -e '$SIG{XCPU} = "IGNORE"; exec @ARGV' "$tree/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) || rc=$?
  else
    out=$(fm_run_timed 240 env PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" FAKE_GH_FAIL=1 \
      FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 "$@" \
      "$tree/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) || rc=$?
  fi
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.1f", time - $ARGV[0]' "$started")
  pa=$(printf '%s' "$out" | jq -c '.secondmate_current.records[]? | select(.id == "domain-alpha")
    | .parent_event.activity_scan | {available, reasons}' 2>/dev/null)
  reg=$(printf '%s' "$out" | jq -c '.secondmate_current.registry | {available, complete, reason}' 2>/dev/null)
  disp=$(sort "$DISP_LOG" | uniq -c | awk '{printf "%s%s(x%s)", sep, $2, $1; sep=","}')
  printf '[%s] %-26s launcher=%-12s rc=%s wall=%ss\n      parent_activity_scan=%s\n      registry=%s\n      xcpu_disposition=%s\n' \
    "$label" "$name" "$launcher" "$rc" "$elapsed" "${pa:-<none>}" "${reg:-<none>}" "${disp:-<none>}"
}

snap pa-wait-3s-budget-1s plain STAT_MODE=wait FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=1
snap pa-burn-budget-1s plain STAT_MODE=burn FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=1
snap pa-error-budget-1s plain STAT_MODE=error FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=1
snap reg-wait-3s-budget-1s plain REGISTRY_READ_MODE=wait FM_SNAPSHOT_REGISTRY_TIMEOUT=1
snap reg-burn-budget-1s plain REGISTRY_READ_MODE=burn FM_SNAPSHOT_REGISTRY_TIMEOUT=1
snap reg-error-budget-1s plain REGISTRY_READ_MODE=error FM_SNAPSHOT_REGISTRY_TIMEOUT=1
snap pa-burn-xcpu-ignored xcpu-ignored STAT_MODE=burn FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=1
snap reg-burn-xcpu-ignored xcpu-ignored REGISTRY_READ_MODE=burn FM_SNAPSHOT_REGISTRY_TIMEOUT=1
snap both-wait-default-budgets plain STAT_MODE=wait REGISTRY_READ_MODE=wait

# The bearings wrapper end to end, the way an operator reads it.
for mode in wait burn-xcpu-ignored; do
  : > "$DISP_LOG"
  rc=0
  started=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
  if [ "$mode" = wait ]; then
    out=$(fm_run_timed 240 env PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" FAKE_GH_FAIL=1 \
      FM_BEARINGS_NOW=2026-07-11T18:00:00Z STAT_MODE=wait REGISTRY_READ_MODE=wait \
      "$tree/bin/fm-bearings-snapshot.sh" 2>&1) || rc=$?
  else
    out=$(fm_run_timed 240 env PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" FAKE_GH_FAIL=1 \
      FM_BEARINGS_NOW=2026-07-11T18:00:00Z STAT_MODE=burn REGISTRY_READ_MODE=burn \
      perl -e '$SIG{XCPU} = "IGNORE"; exec @ARGV' "$tree/bin/fm-bearings-snapshot.sh" 2>&1) || rc=$?
  fi
  elapsed=$(perl -MTime::HiRes=time -e 'printf "%.1f", time - $ARGV[0]' "$started")
  disp=$(sort "$DISP_LOG" | uniq -c | awk '{printf "%s%s(x%s)", sep, $2, $1; sep=","}')
  printf '[%s] bearings-%s rc=%s wall=%ss xcpu_disposition=%s\n--- bearings output (secondmate and disclosure lines) ---\n' \
    "$label" "$mode" "$rc" "$elapsed" "${disp:-<none>}"
  printf '%s\n' "$out" | grep -n -i -E 'secondmate|registry|domain-alpha|unknown|timed out|activity' | head -40
  printf -- '--- end ---\n'
done
printf '[%s] done load=%s\n' "$label" "$(sysctl -n vm.loadavg)"
