#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-quota.sh --fill: the prompt-free Claude
# reading for the account a Claude worker launches on, filled into a
# quota-axi --json snapshot as claudeQuota. A fake cusage serves
# CUSAGE_FIXTURE; no case reads the real cusage or any Keychain item.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-claude-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
USER_HOME="$TMP_ROOT/user-home"
FM_HOME_DIR="$TMP_ROOT/fm-home"
CUSAGE="$TMP_ROOT/cusage.json"
mkdir -p "$FM_HOME_DIR/config"
for label in dale hilda george nobody nell erika ruth vera rita; do
  mkdir -p "$USER_HOME/.claude-accounts/$label"
done

cat > "$FAKEBIN/cusage" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CUSAGE_CALLS:?}"
cat "${CUSAGE_FIXTURE:?}"
exit "${CUSAGE_EXIT:-0}"
SH
chmod +x "$FAKEBIN/cusage"

# The quota-axi --json snapshot quota-axi 0.1.61 prints when it withholds
# Claude's Keychain read: its Claude row is unmeasured.
UNMEASURED='{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}'

# Every time is relative to the clock read here, and each case whose age it
# asserts writes the fixture right before its read: an age at the start of
# its bucket (720 s is 12m, 7500 s is 2h5m) holds for the next minute.
write_cusage() {
  NOW=$(date +%s)
  R5=$((NOW + 18000))
  R7=$((NOW + 432000))
  cat > "$CUSAGE" <<JSON
{"schema_version": 5, "accounts": [
  {"label": "dale", "measured": true, "error": null, "fetched_at": $((NOW - 720)), "windows": [
    {"key": "five_hour", "used_percentage": 61.5, "resets_at": $R5, "reliable": true},
    {"key": "seven_day", "used_percentage": 22.0, "resets_at": $R7, "reliable": true}]},
  {"label": "hilda", "measured": true, "error": null, "fetched_at": $((NOW - 720)), "windows": [
    {"key": "five_hour", "used_percentage": 99.0, "resets_at": $R5, "reliable": false},
    {"key": "seven_day", "used_percentage": 73.0, "resets_at": $R7, "reliable": true}]},
  {"label": "george", "measured": false, "error": "refresh token rejected\nsign in again", "fetched_at": $((NOW - 720)), "windows": []},
  {"label": "erika", "measured": null, "error": null, "warning": "stale · last good 2h5m ago · API rate-limited · backed off 30m", "fetched_at": $((NOW - 7500)), "windows": [
    {"key": "seven_day", "used_percentage": 10.0, "resets_at": $R7, "reliable": true}]},
  {"label": "nell", "measured": true, "error": null, "windows": [
    {"key": "seven_day", "used_percentage": 10.0, "resets_at": $R7, "reliable": true}]},
  {"label": "ruth", "measured": true, "error": null, "fetched_at": $((NOW - 720)), "windows": [
    {"key": "five_hour", "used_percentage": 100.0, "resets_at": $((NOW - 300)), "reliable": true},
    {"key": "seven_day", "used_percentage": 22.0, "resets_at": $R7, "reliable": true},
    {"key": "seven_day_opus", "used_percentage": 95.0, "resets_at": $R7, "reliable": true},
    {"key": "seven_day_sonnet", "used_percentage": 99.0, "resets_at": $((NOW - 60)), "reliable": true},
    {"key": "limit:weekly_scoped:3", "used_percentage": 20.0, "resets_at": $R7, "reliable": true}]},
  {"label": "vera", "measured": true, "error": null, "fetched_at": $((NOW - 720)), "windows": [
    {"key": "five_hour", "used_percentage": 100.0, "resets_at": $((NOW - 300)), "reliable": true},
    {"key": "seven_day", "used_percentage": 100.0, "resets_at": $((NOW - 60)), "reliable": true}]},
  {"label": "rita", "measured": null, "error": null, "warning": "stale · last good 12m ago · API rate-limited · backed off 30m", "fetched_at": $((NOW - 720)), "windows": [
    {"key": "five_hour", "used_percentage": 40.0, "resets_at": $R5, "reliable": true},
    {"key": "seven_day", "used_percentage": 30.0, "resets_at": $R7, "reliable": true}]}]}
JSON
}
iso() { jq -rn --argjson t "$1" '$t | todate'; }

run() {  # <claude config dir> <args...>
  local dir=$1
  shift
  HOME="$USER_HOME" CLAUDE_CONFIG_DIR="$dir" FM_HOME="$FM_HOME_DIR" PATH="$FAKEBIN:$PATH" \
    CUSAGE_FIXTURE="${CUSAGE_FIXTURE:-$CUSAGE}" CUSAGE_CALLS="$TMP_ROOT/cusage.calls" "$TOOL" "$@"
}

reading() {  # <claude config dir>: the claudeQuota a fill adds to the unmeasured snapshot
  local filled
  filled=$(printf '%s\n' "$UNMEASURED" | run "$1" --fill) || return
  printf '%s\n' "$filled" | jq -c '.claudeQuota'
}

write_cusage
out=$(reading "$USER_HOME/.claude-accounts/dale")
expect_code 0 "$?" "a fill with a known reading exits 0"
assert_equals '{"provider":"claude","source":"cusage","account":"dale","status":"known","effectivePercentRemaining":38.5,"limitedBy":"five_hour","windows":[{"key":"five_hour","usedPercent":61.5,"resetsAt":"'"$(iso "$R5")"'"},{"key":"seven_day","usedPercent":22,"resetsAt":"'"$(iso "$R7")"'"}],"summary":"claude 38.5% left, limited by five_hour (five_hour 61.5% used, seven_day 22% used; cusage account dale, as of 12m ago)"}' \
  "$out" "the reading is the launch account's most-used window"
assert_equals '-c -j' "$(cat "$TMP_ROOT/cusage.calls")" "cusage's cached snapshot is read once, never fetched"
pass "a reading names the launch account's limiting window and percent"

printf '%s\n' "$USER_HOME/.claude-accounts/hilda" > "$FM_HOME_DIR/config/claude-account"
write_cusage
out=$(reading "$USER_HOME/.claude-accounts/dale")
assert_contains "$out" '"account":"hilda"' "the home's pin wins over the ambient account"
assert_contains "$out" '"summary":"claude 27% left, limited by seven_day (seven_day 73% used; cusage account hilda, as of 12m ago)"' \
  "a window cusage marks unreliable is left out"
printf '%s\n' ordinary > "$FM_HOME_DIR/config/claude-account"
out=$(reading "$USER_HOME/.claude-accounts/dale")
assert_contains "$out" '"cause":"Claude workers launch on ~/.claude, which is not a cusage account (~/.claude-accounts/<label>)"' \
  "an ordinary pin is not a cusage account"
rm -f "$FM_HOME_DIR/config/claude-account"
pass "a pinned home reads its pinned account"

out=$(reading "$USER_HOME/.claude-accounts/george")
expect_code 0 "$?" "a fill with an unknown reading exits 0"
assert_contains "$out" '"status":"unknown","cause":"cusage could not measure george: refresh token rejected sign in again"' \
  "an account cusage could not measure is unknown with cusage's own cause on one line"
out=$(CUSAGE_EXIT=1 reading "$USER_HOME/.claude-accounts/nobody")
assert_contains "$out" '"cause":"cusage snapshot has no reading for nobody; its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
  "an exit-1 document is still read for the accounts it holds"
out=$(reading "$USER_HOME/.claude-accounts/nell")
assert_contains "$out" '"status":"unknown","cause":"cusage snapshot has no reading for nell; its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
  "an account with no reading time has no snapshot"
pass "an account cusage cannot measure is an unknown reading with its cause"

write_cusage
out=$(reading "$USER_HOME/.claude-accounts/erika")
expect_code 0 "$?" "a fill with a stale reading exits 0"
assert_contains "$out" '"status":"unknown","cause":"cusage snapshot for erika is 2h5m old; its poller (com.dalecarman.cusage, every 30m) may have stopped; cusage warns: stale · last good 2h5m ago · API rate-limited · backed off 30m"' \
  "a snapshot older than two poller runs is unknown with its age and cusage's own warning"
for printed in '' 'not json'; do
  printf '%s\n' "$printed" > "$TMP_ROOT/cusage-missing.json"
  out=$(CUSAGE_FIXTURE="$TMP_ROOT/cusage-missing.json" CUSAGE_EXIT=3 reading "$USER_HOME/.claude-accounts/dale")
  assert_contains "$out" '"status":"unknown","cause":"cusage -c -j gave no readable account list (exit 3); its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
    "a missing snapshot is unknown with its cause"
done
pass "a stale or missing snapshot is an unknown reading naming its age or its poller"

write_cusage
out=$(reading "$USER_HOME/.claude-accounts/rita")
assert_contains "$out" '"status":"known","effectivePercentRemaining":60,"limitedBy":"five_hour"' \
  "a replay of cusage's last good reading is read"
assert_contains "$out" '"summary":"claude 60% left, limited by five_hour (five_hour 40% used, seven_day 30% used; cusage account rita, as of 12m ago)"' \
  "a replayed reading names its age"
pass "an account cusage replays from its last good reading gives a known reading"

write_cusage
out=$(reading "$USER_HOME/.claude-accounts/ruth")
assert_equals '78|seven_day|["seven_day"]' "$(printf '%s\n' "$out" | jq -r '"\(.effectivePercentRemaining)|\(.limitedBy)|\([.windows[].key] | tojson)"')" \
  "a five_hour window whose reset passed is dropped and model windows never set the figure"
assert_contains "$out" '"summary":"claude 78% left, limited by seven_day (seven_day 22% used; also seven_day_opus 95% used; cusage account ruth, as of 12m ago)"' \
  "only an unreset model window more used than the limiting one is shown"
write_cusage
out=$(reading "$USER_HOME/.claude-accounts/vera")
assert_contains "$out" '"status":"unknown","cause":"every five_hour and seven_day window for vera has reset since cusage read it 12m ago"' \
  "a snapshot whose windows all reset is unknown with that cause"
pass "a window whose reset passed is dropped, and a more-used model window is shown without changing the figure"

six='{"schemaVersion":6,"providers":[
  {"provider":"claude","accountKey":"profile:abc","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}},
  {"provider":"claude","accountKey":"default","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},
  {"provider":"codex","accountKey":"codex-home","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":77,"runway":{"status":"through_reset"}}]}}]}'
write_cusage
out=$(printf '%s\n' "$six" | run "$USER_HOME/.claude-accounts/dale" --fill)
expect_code 0 "$?" "a schema 6 fill exits 0"
assert_equals '[["claude","profile:abc",50],["codex","codex-home",77],["claude","default",38.5]]' \
  "$(printf '%s\n' "$out" | jq -c '[.providers[] | [.provider, .accountKey, .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining]]')" \
  "schema 6 replaces only the default Claude row and keeps every other account"
assert_equals 'claude 38.5% left, limited by five_hour (five_hour 61.5% used, seven_day 22% used; cusage account dale, as of 12m ago)' \
  "$(printf '%s\n' "$out" | jq -r '.claudeQuota.summary')" "the fill carries the reading it used"
rc=0
out=$(printf '%s\n' '{"schemaVersion":5,"providers":"nope"}' | run "$USER_HOME/.claude-accounts/dale" --fill 2>&1) || rc=$?
expect_code 2 "$rc" "an invalid snapshot exits 2"
assert_contains "$out" 'stdin is not a valid quota-axi --json snapshot' "an invalid snapshot is named"
pass "a fill keeps the snapshot's other rows and refuses one that is not valid"

printf '# all fm-claude-quota tests passed\n'
