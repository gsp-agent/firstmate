#!/usr/bin/env bash
# Scenario 8: `fm-captain-hold.sh diverged`, the only caller of the refactored
# open-task listing. A status log that says a captain call is resolved while
# the backlog still holds it is reported; a closed call is not; an unreadable
# listing stays silent and exits 0.
# Run with BIN_ROOT=<extracted old bin parent> to replay a previous revision.
set -u
. "$(dirname "$0")/lab-lib.sh"
WT=${BIN_ROOT:-$WT}
cd "$WT" || exit 1
LAB=$(lab_new) || exit 1
echo "host: $(uptime | sed "s/.*load/load/")   timing allowance: $([ -n "${LAB_ALLOWANCE:-}" ] && echo "widened read/row/check bounds" || echo "production bounds")"
echo "lab home: $LAB   code under test: $WT"
for id in still-held closed-call; do
  hold_cli "$LAB" 2026-10-14T02:00:00Z hold "$id" --title "Call $id, with a comma" \
    --reason 'Should I deploy this to production?' >/dev/null || echo "FAIL  hold $id"
done
tasks "$LAB" add plain 'Plain row' --kind ship --repo sample >/dev/null
printf 'Close it.\n' > "$LAB/d.txt"
hold_cli "$LAB" '' answer closed-call --decision-file "$LAB/d.txt" >/dev/null || echo 'FAIL  answer'
cat > "$LAB/state/origin-a.status" <<'EOF'
needs-decision [key=still-held]: deploy?
resolved [key=still-held]: answered in chat
needs-decision [key=closed-call]: deploy?
resolved [key=closed-call]: answered
needs-decision [key=plain]: unrelated
resolved [key=plain]: unrelated
EOF
out=$(hold_cli "$LAB" '' diverged); rc=$?
printf 'diverged exit %s output:\n%s\n' "$rc" "$out"
check 'reports exactly the still-held call' "$(printf 'still-held\torigin-a\tstill-held\tCall still-held, with a comma')" "$out"
check 'exit status' 0 "$rc"
cat > "$LAB/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then echo 'listing unavailable' >&2; exit 1; fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LAB/fakebin/tasks-axi"
out=$(hold_cli "$LAB" '' diverged 2>&1); rc=$?
printf 'diverged with an unreadable listing: exit %s output: [%s]\n' "$rc" "$out"
check 'unreadable listing stays silent' '' "$out"
check 'unreadable listing exits 0' 0 "$rc"
echo "FAILS=${LAB_FAILS:-0}"
