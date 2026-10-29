#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-quota.sh: the prompt-free Claude reading
# for the account a Claude worker launches on, alone and filled into a
# quota-axi --json snapshot. A fake cusage serves CUSAGE_FIXTURE; no case
# reads the real cusage or any Keychain item.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-claude-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
USER_HOME="$TMP_ROOT/user-home"
FM_HOME_DIR="$TMP_ROOT/fm-home"
CUSAGE="$TMP_ROOT/cusage.json"
mkdir -p "$USER_HOME/.claude-accounts/dale" "$USER_HOME/.claude-accounts/hilda" "$FM_HOME_DIR/config"

cat > "$FAKEBIN/cusage" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CUSAGE_CALLS:?}"
cat "${CUSAGE_FIXTURE:?}"
exit "${CUSAGE_EXIT:-0}"
SH
chmod +x "$FAKEBIN/cusage"

# Every time is relative to now, so no case starts failing once a fixed
# reset passes: dale and hilda were read 12m ago and their windows reset
# hours from now.
NOW=$(date +%s)
FETCHED=$((NOW - 750))
R5=$((NOW + 18000))
R7=$((NOW + 432000))
iso() { jq -rn --argjson t "$1" '$t | todate'; }
cat > "$CUSAGE" <<JSON
{"schema_version": 5, "accounts": [
  {"label": "dale", "measured": true, "error": null, "fetched_at": $FETCHED, "windows": [
    {"key": "five_hour", "used_percentage": 61.5, "resets_at": $R5, "reliable": true},
    {"key": "seven_day", "used_percentage": 22.0, "resets_at": $R7, "reliable": true}]},
  {"label": "hilda", "measured": true, "error": null, "fetched_at": $FETCHED, "windows": [
    {"key": "five_hour", "used_percentage": 99.0, "resets_at": $R5, "reliable": false},
    {"key": "seven_day", "used_percentage": 73.0, "resets_at": $R7, "reliable": true}]},
  {"label": "george", "measured": false, "error": "refresh token rejected\nsign in again", "fetched_at": $FETCHED, "windows": []},
  {"label": "erika", "measured": true, "error": null, "fetched_at": $((NOW - 7530)), "windows": [
    {"key": "seven_day", "used_percentage": 10.0, "resets_at": $R7, "reliable": true}]},
  {"label": "nell", "measured": true, "error": null, "windows": [
    {"key": "seven_day", "used_percentage": 10.0, "resets_at": $R7, "reliable": true}]},
  {"label": "ruth", "measured": true, "error": null, "fetched_at": $FETCHED, "windows": [
    {"key": "five_hour", "used_percentage": 100.0, "resets_at": $((NOW - 300)), "reliable": true},
    {"key": "seven_day", "used_percentage": 22.0, "resets_at": $R7, "reliable": true},
    {"key": "seven_day_opus", "used_percentage": 95.0, "resets_at": $R7, "reliable": true},
    {"key": "seven_day_sonnet", "used_percentage": 99.0, "resets_at": $((NOW - 60)), "reliable": true},
    {"key": "limit:weekly_scoped:3", "used_percentage": 20.0, "resets_at": $R7, "reliable": true}]},
  {"label": "vera", "measured": true, "error": null, "fetched_at": $FETCHED, "windows": [
    {"key": "five_hour", "used_percentage": 100.0, "resets_at": $((NOW - 300)), "reliable": true},
    {"key": "seven_day", "used_percentage": 100.0, "resets_at": $((NOW - 60)), "reliable": true}]}]}
JSON

run() {  # <claude config dir> <args...>
  local dir=$1
  shift
  HOME="$USER_HOME" CLAUDE_CONFIG_DIR="$dir" FM_HOME="$FM_HOME_DIR" PATH="$FAKEBIN:$PATH" \
    CUSAGE_FIXTURE="${CUSAGE_FIXTURE:-$CUSAGE}" CUSAGE_CALLS="$TMP_ROOT/cusage.calls" "$TOOL" "$@"
}

out=$(run "$USER_HOME/.claude-accounts/dale")
expect_code 0 "$?" "a known reading exits 0"
assert_equals '{"provider":"claude","source":"cusage","account":"dale","status":"known","effectivePercentRemaining":38.5,"limitedBy":"five_hour","windows":[{"key":"five_hour","usedPercent":61.5,"resetsAt":"'"$(iso "$R5")"'"},{"key":"seven_day","usedPercent":22,"resetsAt":"'"$(iso "$R7")"'"}],"summary":"claude 38.5% left, limited by five_hour (five_hour 61.5% used, seven_day 22% used; cusage account dale, as of 12m ago)"}' \
  "$out" "the reading is the launch account's most-used window"
assert_equals '-c -j' "$(cat "$TMP_ROOT/cusage.calls")" "cusage's cached snapshot is read once, never fetched"
pass "a reading names the launch account's limiting window and percent"

printf '%s\n' "$USER_HOME/.claude-accounts/hilda" > "$FM_HOME_DIR/config/claude-account"
out=$(run "$USER_HOME/.claude-accounts/dale")
assert_contains "$out" '"account":"hilda"' "the home's pin wins over the ambient account"
assert_contains "$out" '"summary":"claude 27% left, limited by seven_day (seven_day 73% used; cusage account hilda, as of 12m ago)"' \
  "a window cusage marks unreliable is left out"
printf '%s\n' ordinary > "$FM_HOME_DIR/config/claude-account"
out=$(run "$USER_HOME/.claude-accounts/dale")
assert_contains "$out" '"cause":"Claude workers launch on ~/.claude, which is not a cusage account (~/.claude-accounts/<label>)"' \
  "an ordinary pin is not a cusage account"
rm -f "$FM_HOME_DIR/config/claude-account"
pass "a pinned home reads its pinned account"

mkdir -p "$USER_HOME/.claude-accounts/george"
out=$(run "$USER_HOME/.claude-accounts/george")
expect_code 0 "$?" "an unknown reading exits 0"
assert_contains "$out" '"status":"unknown","cause":"cusage could not measure george: refresh token rejected sign in again"' \
  "an account cusage could not measure is unknown with cusage's own cause on one line"
mkdir -p "$USER_HOME/.claude-accounts/nobody"
out=$(CUSAGE_EXIT=1 run "$USER_HOME/.claude-accounts/nobody")
assert_contains "$out" '"cause":"cusage snapshot has no reading for nobody; its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
  "an exit-1 document is still read for the accounts it holds"
mkdir -p "$USER_HOME/.claude-accounts/nell"
out=$(run "$USER_HOME/.claude-accounts/nell")
assert_contains "$out" '"status":"unknown","cause":"cusage snapshot has no reading for nell; its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
  "an account with no reading time has no snapshot"
pass "an account cusage cannot measure is an unknown reading with its cause"

mkdir -p "$USER_HOME/.claude-accounts/erika"
out=$(run "$USER_HOME/.claude-accounts/erika")
expect_code 0 "$?" "a stale reading exits 0"
assert_contains "$out" '"status":"unknown","cause":"cusage snapshot for erika is 2h5m old; its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
  "a snapshot older than two poller runs is unknown with its age"
for printed in '' 'not json'; do
  printf '%s\n' "$printed" > "$TMP_ROOT/cusage-missing.json"
  out=$(CUSAGE_FIXTURE="$TMP_ROOT/cusage-missing.json" CUSAGE_EXIT=3 run "$USER_HOME/.claude-accounts/dale")
  assert_contains "$out" '"status":"unknown","cause":"cusage -c -j gave no readable account list (exit 3); its poller (com.dalecarman.cusage, every 30m) may have stopped"' \
    "a missing snapshot is unknown with its cause"
done
pass "a stale or missing snapshot is an unknown reading naming its age or its poller"

mkdir -p "$USER_HOME/.claude-accounts/ruth" "$USER_HOME/.claude-accounts/vera"
out=$(run "$USER_HOME/.claude-accounts/ruth")
assert_equals '78|seven_day|["seven_day"]' "$(printf '%s\n' "$out" | jq -r '"\(.effectivePercentRemaining)|\(.limitedBy)|\([.windows[].key] | tojson)"')" \
  "a five_hour window whose reset passed is dropped and model windows never set the figure"
assert_contains "$out" '"summary":"claude 78% left, limited by seven_day (seven_day 22% used; also seven_day_opus 95% used; cusage account ruth, as of 12m ago)"' \
  "only an unreset model window more used than the limiting one is shown"
out=$(run "$USER_HOME/.claude-accounts/vera")
assert_contains "$out" '"status":"unknown","cause":"every five_hour and seven_day window for vera has reset since cusage read it 12m ago"' \
  "a snapshot whose windows all reset is unknown with that cause"
pass "a window whose reset passed is dropped, and a more-used model window is shown without changing the figure"

six='{"schemaVersion":6,"providers":[
  {"provider":"claude","accountKey":"profile:abc","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}},
  {"provider":"claude","accountKey":"default","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},
  {"provider":"codex","accountKey":"codex-home","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":77,"runway":{"status":"through_reset"}}]}}]}'
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
