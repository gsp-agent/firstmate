#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, the unknown
# announced state of notes that predate the marker, bounded receipts JSON with
# omission disclosure, the reply cursor's strict order, and the readiness
# projection's model-aware health and unknown lock path. Human note/list/drain
# behaviour stays unchanged when the new flags are omitted.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_SUPERVISION_MODEL

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

# A retired home keeps its old notes readable, but cannot accept another one.
home=$(make_home retired)
out=$(run_inbox "$home" note "preserved before retirement")
retired_id=$(printf '%s\n' "$out" | awk '/^queued / { print $2 }')
cp "$home/state/inbox/$retired_id.note" "$TMP_ROOT/preserved.note"
active_home=$(make_home 'active home')
printf '%s\n' "$active_home" > "$home/config/inbox-retired-to"
for verb in note say announce; do
  set +e
  out=$(run_inbox "$home" "$verb" "$retired_id" 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "retired $verb must fail before saving or announcing"
  assert_contains "$out" "$active_home" "retired $verb names the active home"
  assert_equals "1" "$(count_notes "$home")" "retired $verb must not save another note"
  assert_equals "1" "$(count_wakes "$home")" "retired $verb must not append a wake"
done
cmp "$TMP_ROOT/preserved.note" "$home/state/inbox/$retired_id.note" \
  || fail "retirement must preserve the original note bytes"
assert_contains "$(run_inbox "$home" list)" "preserved before retirement" \
  "retired notes remain readable"
assert_contains "$(run_inbox "$home" status)" "1 note(s)" \
  "retired status remains readable"
run_inbox "$active_home" note "new destination" >/dev/null
assert_equals "1" "$(count_notes "$active_home")" "the active home still accepts one note"
assert_equals "1" "$(count_wakes "$active_home")" "the active home still appends one wake"
pass "retirement refuses capture before any write and preserves read access"

home=$(make_home retired-empty)
: > "$home/config/inbox-retired-to"
set +e
out=$(run_inbox "$home" note "must not be saved" 2>&1)
code=$?
set -e
expect_code 1 "$code" "an empty retirement marker must fail closed"
assert_contains "$out" "inbox-retired-to" "invalid retirement names the setting to repair"
assert_absent "$home/state/inbox" "refusal must happen before even making the inbox"
assert_absent "$home/state/.wake-queue" "refusal must not append a wake"
pass "an invalid retirement destination cannot silently reopen capture"

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "True" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "True" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "True" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "False" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "True" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
home=$(make_home announce-repair)
set +e
unannounced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-2 --json "announce me" 2>/dev/null)
set -e
unannounced_id=$(printf '%s' "$unannounced" | json_get id)
assert_equals "0" "$(count_wakes "$home")" "the isolated submit wrote no wake"
repaired=$(run_inbox "$home" announce "$unannounced_id") \
  || fail "announce should repair a note this version saved but could not announce"
assert_contains "$repaired" "announced $unannounced_id" "the repair reports the announcement"
assert_equals "1" "$(count_wakes "$home")" "repairing appends exactly one wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# A note firstmate already acknowledged needs no wake, so neither the repair
# path nor a request-id replay appends one.
home=$(make_home announce-acked)
set +e
acked=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id acked-1 --json "drained before repair" 2>/dev/null)
set -e
acked_id=$(printf '%s' "$acked" | json_get id)
run_inbox "$home" drain --ack "$acked_id" >/dev/null || fail "drain --ack failed"
acked_repair=$(run_inbox "$home" announce --json "$acked_id") \
  || fail "announce of an acknowledged note should succeed without waking"
assert_equals "True" "$(printf '%s' "$acked_repair" | json_get acknowledged)" \
  "announce reports the note as already acknowledged"
assert_equals "False" "$(printf '%s' "$acked_repair" | json_get announced)" \
  "announce does not claim a wake it never appended"
acked_human=$(run_inbox "$home" announce "$acked_id") \
  || fail "human announce of an acknowledged note should succeed"
assert_contains "$acked_human" "already-acknowledged $acked_id" \
  "human announce names the acknowledgement"
acked_replay=$(run_inbox "$home" note --request-id acked-1 --json "drained before repair") \
  || fail "replay of an acknowledged note should exit 0"
assert_equals "replay" "$(printf '%s' "$acked_replay" | json_get outcome)" \
  "retry of an acknowledged note is a replay"
assert_equals "True" "$(printf '%s' "$acked_replay" | json_get acknowledged)" \
  "replay reports the note as already acknowledged"
assert_equals "0" "$(count_wakes "$home")" \
  "an acknowledged note never gets a repair wake"
pass "repair and replay do not wake firstmate for an already-acknowledged note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

json_len() {  # <key>
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

home=$(make_home receipts)
ids=""
i=0
while [ "$i" -lt 21 ]; do
  ids="$ids $(run_inbox "$home" note --request-id "bulk-$i" "bulk body $i" \
    | sed -n 's/^queued //p')"
  i=$((i + 1))
done

receipts=$(run_inbox "$home" receipts) || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
assert_equals "20" "$(printf '%s' "$receipts" | json_len pending)" \
  "pending list is bounded without a reveal flag"
assert_contains "$receipts" "pending notes omitted by bound: 1" \
  "receipts disclose how many pending notes they omitted"
assert_contains "$receipts" "pass --all-pending" \
  "omission names the flag that reveals pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending) \
  || fail "unbounded receipts should succeed"
assert_equals "21" "$(printf '%s' "$all_receipts" | json_len pending)" \
  "--all-pending reveals every pending note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omitted"])')" \
  "revealing every row leaves omitted empty"

# shellcheck disable=SC2086 # deliberate word splitting: one id per --ack arg.
run_inbox "$home" drain --ack $ids >/dev/null || fail "drain --ack of the bulk notes failed"
handled_receipts=$(run_inbox "$home" receipts) || fail "receipts after drain should succeed"
assert_equals "20" "$(printf '%s' "$handled_receipts" | json_len handled)" \
  "handled list is bounded without a reveal flag"
assert_contains "$handled_receipts" "handled notes omitted by bound: 1" \
  "receipts disclose how many handled notes they omitted"
assert_contains "$handled_receipts" "pass --all-handled" \
  "omission names the flag that reveals handled notes"
assert_equals "21" "$(run_inbox "$home" receipts --all-handled | json_len handled)" \
  "--all-handled reveals every handled note"
assert_contains "$handled_receipts" '"acknowledged":true' "handled notes are acknowledged"
pass "receipts JSON is bounded by fixed bounds and discloses what it omitted"

# A note written before this home tracked announcement markers already appended
# its own wake, and nothing proves that, so receipts say unknown rather than
# false and the repair path refuses it instead of appending a second wake.
home=$(make_home preexisting)
run_inbox "$home" note "establish the inbox" >/dev/null || fail "seed note failed"
legacy="1700000000-legacy"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\nfrom before the marker\n' \
  "$legacy" > "$home/state/inbox/$legacy.note"
legacy_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
rows={r["id"]: r["announced"] for r in json.load(sys.stdin)["pending"]}
print(json.dumps(rows[sys.argv[1]]))' "$legacy")
assert_equals "null" "$legacy_announced" \
  "a note that predates the marker reports announced as unknown, not false"
fresh_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.dumps([r["announced"] for r in json.load(sys.stdin)["pending"] if r["id"] != sys.argv[1]]))' "$legacy")
assert_equals "[true]" "$fresh_announced" \
  "a note this version wrote still reports a definite announced state"
before_wakes=$(count_wakes "$home")
set +e
legacy_out=$(run_inbox "$home" announce "$legacy" 2>&1)
legacy_code=$?
set -e
expect_code 1 "$legacy_code" "announcing a note with an unknown announced state is refused"
assert_contains "$legacy_out" "UNKNOWN" "the refusal says the announced state is unknown"
assert_equals "$before_wakes" "$(count_wakes "$home")" \
  "the refused repair must not append a second wake"
pass "notes that predate the announcement marker are unknown, not re-announced"

# Reply cursor: replies recorded within the same second are both readable, in
# recording order, even when the later note id sorts below the earlier one.
home=$(make_home cursor)
mkdir -p "$home/state/inbox"
later="1700000000-aaaaaa"
earlier="1700000000-zzzzzz"
for nid in "$earlier" "$later"; do
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder %s\n' \
    "$nid" "$nid" > "$home/state/inbox/$nid.note"
done
run_inbox "$home" reply "$earlier" "answer one" >/dev/null || fail "first reply failed"
run_inbox "$home" reply "$later" "answer two" >/dev/null || fail "second reply failed"
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
assert_equals "2" "$(printf '%s' "$replies" | json_len replies)" \
  "both replies appear without a cursor"
order=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(" ".join(r["id"] for r in json.load(sys.stdin)["replies"]))')
assert_equals "$earlier $later" "$order" "replies are ordered by when they were recorded"
first_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["replies"][0]["cursor"])')
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
assert_equals "1" "$(printf '%s' "$after" | json_len replies)" \
  "--after returns only replies recorded later"
after_id=$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
assert_equals "$later" "$after_id" \
  "a same-second reply recorded after the cursor is still delivered"

set +e
conflict=$(run_inbox "$home" reply "$earlier" "answer one" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a second reply for the same note is refused"
assert_contains "$conflict" "already recorded" "the refusal names the existing record"
pass "the reply channel is durable and its cursor is a strict order"

# A lost sequence counter must not move the cursor backwards: the next reply
# still sorts after every reply a client has already read.
lost_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["reply_cursor"])')
rm -f "$home/state/inbox/.replies/.seq"
third="1700000000-mmmmmm"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder three\n' \
  "$third" > "$home/state/inbox/$third.note"
run_inbox "$home" reply "$third" "answer three" >/dev/null || fail "third reply failed"
after_lost=$(run_inbox "$home" receipts --after "$lost_cursor") \
  || fail "receipts after a lost counter should succeed"
assert_equals "$third" "$(printf '%s' "$after_lost" | json_get replies 0 id)" \
  "a reply recorded after the counter was lost is still after the client cursor"
pass "the reply cursor never goes backwards when the sequence counter is lost"

# A reply without a valid sequence is malformed: it gets no invented position
# and receipts say so instead of silently ordering it.
home=$(make_home malformed-reply)
mkdir -p "$home/state/inbox/.replies"
bad="1700000000-badseq"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder\n' \
  "$bad" > "$home/state/inbox/$bad.note"
printf 'id=%s\nat=2026-01-01T00:00:00Z\n--\nno sequence here\n' \
  "$bad" >"$home/state/inbox/.replies/$bad"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed reply should succeed"
assert_equals "0" "$(printf '%s' "$malformed" | json_len replies)" \
  "a reply without a sequence is not placed in the reply stream"
assert_contains "$malformed" "malformed replies without a valid sequence: 1 ($bad)" \
  "receipts name the malformed reply"
pass "a reply without a valid sequence is reported as malformed"

# One undecodable note must not fail the whole receipts view.
home=$(make_home non-utf8)
run_inbox "$home" note "readable note" >/dev/null || fail "seed note failed"
printf 'id=1700000000-binary\nat=2026-01-01T00:00:00Z\nsource=text\n--\n\377\376 bytes\n' \
  > "$home/state/inbox/1700000000-binary.note"
binary=$(run_inbox "$home" receipts) || fail "receipts must survive a non-UTF-8 note"
assert_equals "2" "$(printf '%s' "$binary" | json_len pending)" \
  "the undecodable note and the readable note are both listed"
pass "a non-UTF-8 note does not break the receipts view"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "no lock file is free, not live"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["live_harness"])')
assert_equals "False" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')
[ "$can" = "False" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a dead recorded pid is stale"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a non-file lock is unreadable rather than held"
# Readiness must not inherit the pull guard's autoarm mid-turn allowance.
# Each supervision model comes from a live lock holder of that harness.
home=$(make_home ready-holder)
perl -e '$0="claude"; sleep 300' &
holder_pid=$!
perl -e '$0="pi"; sleep 300' &
pi_pid=$!
perl -e '$0="codex"; sleep 300' &
codex_pid=$!
sleep 0.2
kill_holder() {
  kill "$holder_pid" "$pi_pid" "$codex_pid" 2>/dev/null || true
  wait "$holder_pid" "$pi_pid" "$codex_pid" 2>/dev/null || true
}
trap 'kill_holder; fm_test_cleanup' EXIT
printf '%s\n' "$holder_pid" > "$home/state/.lock"
printf 'acked:handling:ready-recovery\n' > "$home/state/.watcher-down"
printf 'epoch=1 owner_pid=%s outcome=rewake updated_at=1 session_pid=%s\n' \
  "$holder_pid" "$holder_pid" > "$home/state/.claude-autoarm-epoch"
python3 - "$home/state/.last-watcher-beat" <<'PY_AGE'
import os, sys, time
path = sys.argv[1]
open(path, "a").close()
stamp = int(time.time()) - 3603
os.utime(path, (stamp, stamp))
PY_AGE
stale=$(run_inbox "$home" ready) || fail "ready should succeed with a stale autoarm beacon"
printf 'ready 3603-second regression: %s\n' "$stale"
assert_equals "held" "$(printf '%s' "$stale" | json_get lock state)" \
  "the stale-beacon regression holds a live primary lock"
[ "$(printf '%s' "$stale" | json_get wake_consumer beacon_age_seconds)" -ge 3603 ] \
  || fail "the regression beacon must be at least 3603 seconds old"
assert_equals "down" "$(printf '%s' "$stale" | json_get wake_consumer state)" \
  "a 3603-second beacon cannot inherit a healthy autoarm verdict"
assert_equals "stale-beacon" "$(printf '%s' "$stale" | json_get wake_consumer reason)" \
  "the stale-beacon regression reports its cause"
assert_equals "False" "$(printf '%s' "$stale" | json_get can_receive)" \
  "a held lock and old rewake record cannot receive without a watcher"

# A live auto-arm claim is a cycle being armed now, so it reads live while the
# beacon still holds the poll from before a long turn; a stuck claim does not.
# No model override: the claude lock holder makes this an auto-arm home.
claim_identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$holder_pid")
printf 'epoch=2 owner_pid=%s outcome=arming updated_at=%s\n%s\n' "$holder_pid" "$(date +%s)" "$claim_identity" \
  > "$home/state/.claude-autoarm-epoch"
arming=$(run_inbox "$home" ready) || fail "ready should succeed with an open auto-arm claim"
assert_equals "healthy" "$(printf '%s' "$arming" | json_get wake_consumer state)" \
  "an open auto-arm claim reads live under a stale beacon"
assert_equals "True" "$(printf '%s' "$arming" | json_get can_receive)" \
  "an open auto-arm claim can receive"
python3 - "$home/state/.claude-autoarm-epoch" <<'PY_AGE'
import os, sys, time
stamp = int(time.time()) - 3603
os.utime(sys.argv[1], (stamp, stamp))
PY_AGE
stuck=$(run_inbox "$home" ready) || fail "ready should succeed with a stuck auto-arm claim"
assert_equals "down" "$(printf '%s' "$stuck" | json_get wake_consumer state)" \
  "a claim stuck past grace with a stale beacon is not live"
assert_equals "stale-beacon" "$(printf '%s' "$stuck" | json_get wake_consumer reason)" \
  "the stuck claim reports the stale beacon"
assert_equals "False" "$(printf '%s' "$stuck" | json_get can_receive)" \
  "a stuck claim cannot receive"

# Mid-turn on an auto-arm primary the watcher has exited on its close and the
# beacon holds that cycle's last poll, which the model-aware verdict calls live.
rm -f "$home/state/.claude-autoarm-epoch"
touch "$home/state/.last-watcher-beat"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an auto-arm home between cycles"
assert_equals "healthy" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "an auto-arm home reads a fresh cycle as live with no watcher running"
assert_equals "True" "$(printf '%s' "$ready" | json_get can_receive)" \
  "an auto-arm home can receive mid-turn with a fresh beacon"
for holder in "$pi_pid:extension" "$codex_pid:persistent"; do
  model=${holder#*:}
  printf '%s\n' "${holder%%:*}" > "$home/state/.lock"
  ready=$(run_inbox "$home" ready) \
    || fail "ready should succeed for $model without a watcher"
  assert_equals "held" "$(printf '%s' "$ready" | json_get lock state)" \
    "the $model holder is a live primary"
  assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
    "$model requires a live watcher even with a fresh beacon"
  assert_equals "no-watcher" "$(printf '%s' "$ready" | json_get wake_consumer reason)" \
    "$model reports the missing watcher"
  assert_equals "False" "$(printf '%s' "$ready" | json_get can_receive)" \
    "$model cannot receive without a watcher"
done

watch_home=$(make_home ready-watcher)
printf '%s\n' "$holder_pid" > "$watch_home/state/.lock"
fm_test_track_watcher_state "$watch_home/state"
FM_HOME="$watch_home" FM_STATE_OVERRIDE="$watch_home/state" \
  FM_DATA_OVERRIDE="$watch_home/data" FM_CONFIG_OVERRIDE="$watch_home/config" \
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bash "$ROOT/bin/fm-watch.sh" > "$watch_home/watch.out" 2>&1 &
watch_pid=$!
for _ in $(seq 1 200); do
  [ -s "$watch_home/state/.watch.lock/pid-identity" ] \
    && [ -e "$watch_home/state/.last-watcher-beat" ] && break
  kill -0 "$watch_pid" 2>/dev/null || fail "the test watcher exited before publishing its beacon"
  sleep 0.1
done
[ -e "$watch_home/state/.last-watcher-beat" ] || fail "the test watcher did not publish a beacon"
for holder in "$holder_pid:autoarm" "$pi_pid:extension" "$codex_pid:persistent"; do
  model=${holder#*:}
  printf '%s\n' "${holder%%:*}" > "$watch_home/state/.lock"
  held=$(run_inbox "$watch_home" ready) \
    || fail "ready should succeed for $model with a live watcher"
  assert_equals "healthy" "$(printf '%s' "$held" | json_get wake_consumer state)" \
    "$model accepts a fresh beacon from its live watcher"
  assert_equals "True" "$(printf '%s' "$held" | json_get can_receive)" \
    "$model can receive with a held lock and healthy watcher"
done
printf 'ready live-watcher regression: %s\n' "$held"

# A stopped watcher keeps its pid and identity but cannot refresh its beacon.
kill -STOP "$watch_pid"
python3 - "$watch_home/state/.last-watcher-beat" <<'PY_AGE'
import os, sys, time
stamp = int(time.time()) - 120
os.utime(sys.argv[1], (stamp, stamp))
PY_AGE
ready=$(FM_GUARD_GRACE=60 run_inbox "$watch_home" ready)
assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "a live watcher cannot excuse a beacon beyond configured grace"
assert_equals "False" "$(printf '%s' "$ready" | json_get can_receive)" \
  "a stalled watcher cannot receive"
ready=$(FM_GUARD_GRACE=300 run_inbox "$watch_home" ready)
assert_equals "healthy" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "the same live watcher and beacon are healthy within configured grace"
ready=$(FM_WATCHER_STALE_GRACE=60 FM_GUARD_GRACE=300 run_inbox "$watch_home" ready)
assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "the watcher's explicit stale grace takes precedence"

foreign_home=$(make_home ready-foreign-watcher)
printf '%s\n' "$codex_pid" > "$foreign_home/state/.lock"
cp -R "$watch_home/state/.watch.lock" "$foreign_home/state/.watch.lock"
touch "$foreign_home/state/.last-watcher-beat"
ready=$(run_inbox "$foreign_home" ready)
assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "another home's live watcher cannot make this home healthy"
assert_equals "False" "$(printf '%s' "$ready" | json_get can_receive)" \
  "another home's watcher cannot receive this home's notes"

kill -CONT "$watch_pid"
kill -TERM "$watch_pid"
wait "$watch_pid" 2>/dev/null || true
touch "$watch_home/state/.last-watcher-beat"
# A secondmate caller inherits its own primary's model from fm-spawn.sh; the
# inspected home's holder decides, whatever the caller carries.
for inherited in '' autoarm extension persistent; do
  printf '%s\n' "$codex_pid" > "$watch_home/state/.lock"
  ready=$(FM_SUPERVISION_MODEL="$inherited" run_inbox "$watch_home" ready)
  assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
    "a fresh leftover beacon cannot hide a codex watcher's exit (caller model '$inherited')"
  assert_equals "no-watcher" "$(printf '%s' "$ready" | json_get wake_consumer reason)" \
    "the codex home reports its exited watcher (caller model '$inherited')"
  assert_equals "False" "$(printf '%s' "$ready" | json_get can_receive)" \
    "watcher exit makes the codex primary unable to receive (caller model '$inherited')"
  printf '%s\n' "$holder_pid" > "$watch_home/state/.lock"
  ready=$(FM_SUPERVISION_MODEL="$inherited" run_inbox "$watch_home" ready)
  assert_equals "healthy" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
    "a claude home between cycles reads live (caller model '$inherited')"
  assert_equals "True" "$(printf '%s' "$ready" | json_get can_receive)" \
    "a claude home between cycles can receive (caller model '$inherited')"
done
pass "readiness follows the inspected home's supervision model, never the caller's or a stale beacon"

# --- delivery: an idle main with an old unread row cannot receive ----------
# Replay of the 10-21 23:11Z exit picker: the beat stays fresh from the
# backstop arm while main sits idle behind a modal and rows wait unread.
# The consumer verdict still says healthy; delivery reads stalled.
home=$(make_home ready-delivery-stalled)
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
now=$(date +%s)
printf 'idle %s %s %s\n' "$now" "$holder_pid" "delivery-session" \
  > "$home/state/.claude-turn"
printf '%s\t%s\t%s\t%s\t%s\n' "$((now - 7200))" 1 check "inbox:delivery-note" \
  "check: captain inbox note delivery-note - stalled" \
  > "$home/state/.wake-queue"
stalled=$(FM_WATCHER_STALE_GRACE=300 run_inbox "$home" ready) \
  || fail "ready should succeed for a delivery-stalled home"
printf 'ready delivery-stalled regression: %s\n' "$stalled"
assert_equals "healthy" "$(printf '%s' "$stalled" | json_get wake_consumer state)" \
  "a fresh beat still reads a healthy consumer when delivery stalls"
assert_equals "delivery-stalled" "$(printf '%s' "$stalled" | json_get wake_consumer reason)" \
  "an idle main with a two-hour unread row reports delivery-stalled"
assert_equals "False" "$(printf '%s' "$stalled" | json_get can_receive)" \
  "an idle main with a two-hour unread row cannot receive"
assert_equals "idle" "$(printf '%s' "$stalled" | json_get delivery turn_state)" \
  "the stalled delivery shows the idle turn state"
[ "$(printf '%s' "$stalled" | json_get delivery oldest_unread_age_seconds)" -ge 7000 ] \
  || fail "the stalled delivery must show the oldest unread age"

# A long busy turn with a fresh row keeps today's answer and shows busy.
home=$(make_home ready-delivery-busy)
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
now=$(date +%s)
printf 'busy %s %s %s\n' "$now" "$holder_pid" "delivery-session" \
  > "$home/state/.claude-turn"
printf '%s\t%s\t%s\t%s\t%s\n' "$now" 1 check "inbox:delivery-note" \
  "check: captain inbox note delivery-note - busy" \
  > "$home/state/.wake-queue"
busy=$(FM_WATCHER_STALE_GRACE=300 run_inbox "$home" ready) \
  || fail "ready should succeed for a busy home"
assert_equals "True" "$(printf '%s' "$busy" | json_get can_receive)" \
  "a busy main with a fresh row can still receive"
assert_equals "supervised" "$(printf '%s' "$busy" | json_get wake_consumer reason)" \
  "a busy main keeps the consumer reason"
assert_equals "busy" "$(printf '%s' "$busy" | json_get delivery turn_state)" \
  "the busy delivery shows the busy turn state"

# An empty queue reads as today, with no unread age to report.
home=$(make_home ready-delivery-empty)
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
now=$(date +%s)
printf 'idle %s %s %s\n' "$now" "$holder_pid" "delivery-session" \
  > "$home/state/.claude-turn"
empty=$(FM_WATCHER_STALE_GRACE=300 run_inbox "$home" ready) \
  || fail "ready should succeed for an empty-queue home"
assert_equals "True" "$(printf '%s' "$empty" | json_get can_receive)" \
  "an empty queue can receive as today"
assert_equals "supervised" "$(printf '%s' "$empty" | json_get wake_consumer reason)" \
  "an empty queue keeps the consumer reason"
assert_equals "None" "$(printf '%s' "$empty" | json_get delivery oldest_unread_age_seconds)" \
  "an empty queue has no unread age"

# A holder with no turn record of its own keeps today's answer: no record,
# or an idle record from another pid, reads unknown and never stalls.
for turn_owner in none other; do
  home=$(make_home "ready-delivery-$turn_owner")
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  now=$(date +%s)
  if [ "$turn_owner" = other ]; then
    printf 'idle %s %s %s\n' "$now" "$pi_pid" "other-session" \
      > "$home/state/.claude-turn"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$((now - 7200))" 1 check "inbox:delivery-note" \
    "check: captain inbox note delivery-note - $turn_owner" \
    > "$home/state/.wake-queue"
  unowned=$(FM_WATCHER_STALE_GRACE=300 run_inbox "$home" ready) \
    || fail "ready should succeed for a $turn_owner turn record"
  assert_equals "True" "$(printf '%s' "$unowned" | json_get can_receive)" \
    "a $turn_owner turn record with an old unread row can receive as today"
  assert_equals "supervised" "$(printf '%s' "$unowned" | json_get wake_consumer reason)" \
    "a $turn_owner turn record keeps the consumer reason"
  assert_equals "unknown" "$(printf '%s' "$unowned" | json_get delivery turn_state)" \
    "a $turn_owner turn record reads an unknown turn state"
done
pass "delivery stalls only for an idle main with an old unread row"

# The model is the lock holder's, not the caller's: a codex primary still needs
# its watcher process when a Claude session asks.
home=$(make_home ready-codex-holder)
printf '%s\n' "$codex_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
ready=$(CLAUDECODE=1 run_inbox "$home" ready) || fail "ready should succeed for a codex primary"
assert_equals "held" "$(printf '%s' "$ready" | json_get lock state)" \
  "the codex fixture holds a live primary lock"
assert_equals "down" "$(printf '%s' "$ready" | json_get wake_consumer state)" \
  "a Claude caller cannot lend a codex home the auto-arm verdict"
assert_equals "no-watcher" "$(printf '%s' "$ready" | json_get wake_consumer reason)" \
  "the codex home reports its missing watcher"
kill_holder
trap fm_test_cleanup EXIT
pass "readiness reads the supervision model from the inspected home's lock holder"

home=$(make_home ready-no-beacon)
nobeat=$(run_inbox "$home" ready) || fail "ready should succeed with no beacon"
assert_equals "down" "$(printf '%s' "$nobeat" | json_get wake_consumer state)" \
  "a home with no beacon has no healthy consumer"
assert_equals "no-beacon" "$(printf '%s' "$nobeat" | json_get wake_consumer reason)" \
  "a home with no beacon reports the missing observation"
assert_equals "None" "$(printf '%s' "$nobeat" | json_get wake_consumer beacon_age_seconds)" \
  "a beacon that does not exist has no age"

home=$(make_home ready-no-override)
printf '%s\n' "$$" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
no_override=$(run_inbox "$home" ready) || fail "ready should succeed with no model override"
assert_equals "unknown" "$(printf '%s' "$no_override" | json_get lock state)" \
  "an unclassified session lock stays unknown"
assert_equals "down" "$(printf '%s' "$no_override" | json_get wake_consumer state)" \
  "an unknown primary cannot make a missing watcher healthy"
assert_equals "False" "$(printf '%s' "$no_override" | json_get can_receive)" \
  "a missing watcher is not receivable even when the lock is unknown"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
# An empty request id must be refused, never treated as "no request id given":
# falling through to the non-idempotent path would make a retry a second note.
blank_out=$(run_inbox "$home" note --request-id '' --json "silently duplicated" 2>&1)
blank_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
expect_code 1 "$blank_code" "an empty request id is refused, not ignored"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_contains "$blank_out" "invalid request id" "an empty request id is rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# The voice handover passes a raw transcript as the first argument, so a body
# that opens with a double dash is text, not an option.
home=$(make_home dash-body)
transcript="--- handover: ship the console backend --now"
dash_out=$(run_inbox "$home" note "$transcript") \
  || fail "a note body opening with dashes should be queued"
assert_contains "$dash_out" "queued " "a dash-leading body is queued like any other"
assert_equals "1" "$(count_notes "$home")" "a dash-leading body writes one note"
dash_body=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.load(sys.stdin)["pending"][0]["body"])')
assert_equals "$transcript" "$dash_body" "the transcript is stored verbatim"
escaped=$(run_inbox "$home" note -- "--request-id is body text here") \
  || fail "-- should end option parsing"
assert_contains "$escaped" "queued " "-- escapes a body that looks like a flag"
pass "a note body that opens with a double dash is queued as text"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"
