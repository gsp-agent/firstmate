#!/usr/bin/env bash
# generation-race.sh <tree> <out> - start the producer, then (after its task
# manifest is captured) relaunch t30 (new spawn_gen) and tear down t31 (meta
# removed). Their mutable observations must be discarded as generation-changed,
# not attributed to the new incarnation; every other task is observed normally.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
E=/Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK
tree=$1 out=$2
cp -p "$LAB/state/t30.meta" "$SCR/t30.meta.keep"
cp -p "$LAB/state/t31.meta" "$SCR/t31.meta.keep"
ls -d "${TMPDIR:-/tmp}"/fm-fleet-tasks.* 2>/dev/null | sort > "$SCR/race-pre-dirs"
FM_LAB_PIN_NOW=1 "$E/scripts/run-lab.sh" "$tree" fm-fleet-snapshot.sh --json > "$out" 2> "$out.err" &
pid=$!
# Wait until the producer has captured its manifest (the private task dir holds t64.meta).
new=''
until [ -n "$new" ] && [ -f "$new/t64.meta" ]; do
  sleep 0.05
  new=$(ls -d "${TMPDIR:-/tmp}"/fm-fleet-tasks.* 2>/dev/null | sort | comm -13 "$SCR/race-pre-dirs" - | head -1)
done
sed -i '' 's/^spawn_gen=.*/spawn_gen=fm.relaunched/' "$LAB/state/t30.meta"
mv "$LAB/state/t31.meta" "$SCR/t31.meta.torndown"
echo "mutated at $(date +%T)"
wait "$pid"; echo "producer rc=$?"
cp -p "$SCR/t30.meta.keep" "$LAB/state/t30.meta"
cp -p "$SCR/t31.meta.keep" "$LAB/state/t31.meta"
rm -f "$SCR/t31.meta.torndown"
jq -c '.tasks[] | select(.id == "t29" or .id == "t30" or .id == "t31")
  | {id, spawn_gen, current_state: .current_state.detail, source: .current_state.source,
     status_present: .paths.status_log.present, exists: .endpoint.exists}' "$out"
jq -r '"tasks=\(.tasks | length) generation-changed=\([.tasks[] | select(.current_state.detail == "task generation changed during snapshot") | .id] | join(","))"' "$out"
