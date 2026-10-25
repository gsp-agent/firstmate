# Hand-driven scenarios sourced by run-bearings-tests.sh (EXTRA_DEFS). They reuse
# the suite's own fixture builders, then run the real bearings and snapshot CLIs
# against a disposable FM_HOME with the DEFAULT 2s budgets, while PATH shims make
# the registry read (head) and the GNU parent-event size read (stat -c %s) wait 3s.
scenario_bearings_view_with_waiting_reads() {
  local home mate fakebin started out canonical
  home=$(make_home view-waiting)
  mate="$TMP_ROOT/view-waiting-home"
  write_domain_alpha_fixture "$home" "$mate"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  '-c %a') printf '600\n' ;;
  '-c %Y') printf '1783792800\n' ;;
  '-c %s') sleep 3; LC_ALL=C wc -c < "$3" | tr -d ' ' ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/head" <<'SH'
#!/usr/bin/env bash
case "$*" in *data/secondmates.md) sleep 3 ;; esac
exec /usr/bin/head "$@"
SH
  chmod +x "$fakebin/uname" "$fakebin/stat" "$fakebin/head"
  echo "== default budgets: registry=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-default} activity=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-default}"
  started=$SECONDS
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 NET_LOG="$home/net.log" FAKE_GH_FAIL=1 \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  echo "== fm-fleet-snapshot.sh --json took $((SECONDS - started))s; Domain Alpha fields:"
  printf '%s' "$canonical" | jq '{registry: (.secondmate_current.registry | {available, complete, reason}),
    domain_alpha: (.secondmate_current.records[] | select(.id == "domain-alpha")
      | {registered, current, provenance_selected: .provenance.selected,
         activity_scan: (.parent_event.activity_scan | {available, reasons})})}'
  started=$SECONDS
  out=$(FAKE_GH_FAIL=1 run "$home" "$fakebin")
  echo "== fm-bearings-snapshot.sh (default view) took $((SECONDS - started))s:"
  printf '%s\n' "$out"
  out=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --json)
  echo "== fm-bearings-snapshot.sh --json, Domain Alpha row:"
  printf '%s' "$out" | jq '[.secondmates[] | select(.id == "domain-alpha") | {id, state, provenance, freshness}]'
}

# Adversarial: the snapshot is launched by a parent that ignores SIGXCPU (an
# inherited SIG_IGN survives exec), and the GNU parent-event size read burns
# CPU. A probe-only 90s wall bound (fm_run_timed, from the run worktree's lib)
# keeps this driver from hanging; the product itself gets the default budget.
scenario_burning_scan_with_inherited_sigxcpu_ignore() {
  local home mate fakebin started rc=0 canonical
  . /Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF/bin/fm-timeout-lib.sh
  home=$(make_home xcpu-ignored)
  mate="$TMP_ROOT/xcpu-ignored-home"
  write_domain_alpha_fixture "$home" "$mate"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  '-c %a') printf '600\n' ;;
  '-c %Y') printf '1783792800\n' ;;
  '-c %s') while :; do :; done ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  started=$SECONDS
  canonical=$(fm_run_timed 90 env PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z FM_SNAPSHOT_NOW_EPOCH=1783792800 \
    /usr/bin/perl -e '$SIG{XCPU} = "IGNORE"; exec @ARGV or die' \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || rc=$?
  echo "== snapshot launched with SIGXCPU ignored: rc=$rc after $((SECONDS - started))s (probe wall bound 90s; 124 = probe had to stop it)"
  if [ -n "$canonical" ]; then
    printf '%s' "$canonical" | jq '.secondmate_current.records[] | select(.id == "domain-alpha") | .parent_event.activity_scan | {available, reasons}'
  else
    echo "== no snapshot output: the burning scan was never stopped by its own budget"
  fi
}

# Adversarial: an ordinary failing GNU size read (exit 2) must stay read_failed,
# never be relabelled timeout by the new status mapping.
scenario_parent_activity_read_error_stays_read_failed() {
  local home mate fakebin canonical
  home=$(make_home activity-read-error)
  mate="$TMP_ROOT/activity-read-error-home"
  write_domain_alpha_fixture "$home" "$mate"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  '-c %a') printf '600\n' ;;
  '-c %Y') printf '1783792800\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq '.secondmate_current.records[] | select(.id == "domain-alpha") | .parent_event.activity_scan | {available, reasons}'
  printf '%s' "$canonical" | jq -e '.secondmate_current.records[] | select(.id == "domain-alpha")
    | .parent_event.activity_scan.available == false and .parent_event.activity_scan.reasons == ["read_failed"]' >/dev/null
}
