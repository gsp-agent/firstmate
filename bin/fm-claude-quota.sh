#!/usr/bin/env bash
# fm-claude-quota.sh - read Claude's quota for the account a Claude worker
# from this home would launch on, with no macOS Keychain prompt.
#
# Usage:
#   fm-claude-quota.sh --fill    read a quota-axi --json snapshot on stdin and
#                                print it with that reading filled in
#
# To see the reading alone:
#   quota-axi --json | bin/fm-claude-quota.sh --fill | jq .claudeQuota
#
# Claude Code's Keychain item opens silently only for the claude binary, so
# quota-axi withholds the value read (attention keychain_prompt_required)
# unless someone once approved its dialog through --allow-keychain-prompt.
# Firstmate never passes that flag and never answers the dialog. cusage
# polls usage through Keychain items of its own that were approved when each
# account was added, so it reads every account's windows with no prompt. Its
# launchd poller (com.dalecarman.cusage, every 30 minutes) writes a snapshot,
# and this reads that snapshot with `cusage -c -j`, which makes no network
# fetch but still runs cusage's per-account Keychain attribute probes.
#
# The account is config/claude-account's pin when the home has one
# (bin/fm-worker-account-lib.sh), otherwise this process's CLAUDE_CONFIG_DIR,
# which bin/fm-spawn.sh hands an unpinned Claude worker, otherwise ~/.claude.
# cusage names an account by its directory ~/.claude-accounts/<label>, so
# only a root there has a reading and cusage is not run for any other.
#
# Reading, one JSON object, known or unknown:
#   known:  {"provider":"claude","source":"cusage","account":"<label>",
#             "status":"known","effectivePercentRemaining":N,
#             "limitedBy":"<window>","windows":[{"key":..,"usedPercent":..,
#             "resetsAt":..}],"summary":"claude N% left, limited by ..."}
#   unknown: {"provider":"claude","source":"cusage","account":"<label>"|null,
#             "status":"unknown","cause":"...",
#             "summary":"claude quota unknown: <cause>"}
# effectivePercentRemaining is 100 minus the most-used of the five_hour and
# seven_day windows cusage reports as reliable whose reset has not passed,
# since a cached snapshot does not roll a window over. summary is the phrase
# a route reason quotes: it names those windows, the snapshot's age (the
# account's fetched_at), and any reliable, unreset model-scoped window
# (seven_day_opus, seven_day_sonnet, or limit:...) more used than the
# limiting window, which never changes effectivePercentRemaining or limitedBy.
# Only an account cusage marks measured false is unmeasured: one with no
# measured mark, as cusage leaves its replay of a last good reading, is read.
#
# --fill leaves a snapshot whose claude row quota-axi measured (status known
# or partial) unchanged and runs nothing. Otherwise it adds the reading as
# top-level claudeQuota and exits 0 whether the reading is known or unknown,
# and a known reading replaces the claude row that
# quota_row (bin/fm-quota-axi-lib.sh) binds for an unqualified Claude
# candidate with one all_models availability carrying its
# effectivePercentRemaining, runway exhausted_now at 0 and unknown otherwise,
# and no spendPriority, so ranking leaves Claude unranked rather than invent
# one. A snapshot that is not valid exits 2 with nothing on stdout.
#
# It never reads Claude Code's Keychain item and never blocks: a missing
# cusage, a run past FM_CLAUDE_QUOTA_SECONDS (default 15, cusage's own bound
# for building that document), no readable snapshot, an account the snapshot has no reading time
# for, a reading more than 3600 seconds old (two poller runs, so the poller
# has stopped; cusage's own warning for the account is added when it gives
# one), an account cusage cannot measure, or no unreset five_hour or
# seven_day window is an unknown reading with its cause.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_CLAUDE_QUOTA_SECONDS=${FM_CLAUDE_QUOTA_SECONDS:-15}
POLLER="its poller (com.dalecarman.cusage, every 30m) may have stopped"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

unknown() {  # <label or ""> <cause>
  jq -cn --arg a "$1" --arg c "$2" '
    ($c | gsub("[\\r\\n]+"; " ")) as $cause |
    {provider: "claude", source: "cusage", account: (if $a == "" then null else $a end),
     status: "unknown", cause: $cause, summary: "claude quota unknown: \($cause)"}'
}

reading() {
  local pin root label accounts parent doc rc=0
  pin=$(fm_worker_account_resolve claude "$CONFIG" 2>/dev/null) || {
    unknown '' "config/claude-account cannot be resolved"
    return
  }
  if [ -n "$pin" ]; then
    root=$(printf '%s\n' "$pin" | cut -f2)
  else
    root=${CLAUDE_CONFIG_DIR:-}
  fi
  if [ -z "$root" ]; then
    unknown '' "Claude workers launch on ~/.claude, which is not a cusage account (~/.claude-accounts/<label>)"
    return
  fi
  label=$(basename "$root")
  accounts=$(cd "${HOME:-/nonexistent}/.claude-accounts" 2>/dev/null && pwd -P) || accounts=
  parent=$(cd "$(dirname "$root")" 2>/dev/null && pwd -P) || parent=
  if [ -z "$accounts" ] || [ "$parent" != "$accounts" ]; then
    unknown '' "Claude workers launch on $root, which is not a cusage account (~/.claude-accounts/<label>)"
    return
  fi
  if ! command -v cusage >/dev/null 2>&1; then
    unknown "$label" "cusage is not installed"
    return
  fi
  doc=$(fm_run_timed "$FM_CLAUDE_QUOTA_SECONDS" cusage -c -j 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    unknown "$label" "cusage -c -j did not answer within ${FM_CLAUDE_QUOTA_SECONDS}s"
    return
  fi
  # cusage exits 1 when any one account could not be read, so the document,
  # not the exit status, says whether this account was.
  printf '%s\n' "$doc" | jq -ce --arg l "$label" --arg poller "$POLLER" '
    def unknown($cause):
      ($cause | gsub("[\\r\\n]+"; " ")) as $c |
      {provider: "claude", source: "cusage", account: $l, status: "unknown", cause: $c,
       summary: "claude quota unknown: \($c)"};
    def age: floor | if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
      else "\(. / 3600 | floor)h\(. % 3600 / 60 | floor)m" end;
    def current: .reliable != false and (.used_percentage | type) == "number" and
      ((.resets_at | type) != "number" or .resets_at > now);
    if (.accounts | type) != "array" then error("no accounts") else . end |
    ([.accounts[] | select(.label == $l)] | first) as $a |
    if $a == null or ($a.fetched_at | type) != "number" or $a.fetched_at <= 0 then
      unknown("cusage snapshot has no reading for \($l); \($poller)")
    else
      ([now - $a.fetched_at, 0] | max) as $age |
      if $age > 3600 then
        unknown("cusage snapshot for \($l) is \($age | age) old; \($poller)" +
          (if ($a.warning | type) == "string" and $a.warning != "" then "; cusage warns: \($a.warning)" else "" end))
      elif ($a.error // null) != null then unknown("cusage could not measure \($l): \($a.error)")
      elif $a.measured == false then unknown("cusage has not measured \($l)")
      else
        [$a.windows[]? | select(.key == "five_hour" or .key == "seven_day")] as $all |
        [$all[] | select(current) |
          {key, usedPercent: (.used_percentage + 0),
           resetsAt: (if (.resets_at | type) == "number" then (.resets_at | floor | todate) else null end)}] as $w |
        if ($w | length) == 0 and ($all | length) > 0 then
          unknown("every five_hour and seven_day window for \($l) has reset since cusage read it \($age | age) ago")
        elif ($w | length) == 0 then unknown("cusage has no five_hour or seven_day window for \($l)")
        else
          ($w | max_by(.usedPercent)) as $limit |
          ([[100 - $limit.usedPercent, 0] | max, 100] | min) as $left |
          [$a.windows[]? |
            select((.key == "seven_day_opus" or .key == "seven_day_sonnet" or (.key | tostring | startswith("limit:"))) and
                   current and .used_percentage > $limit.usedPercent) |
            "\(.key) \(.used_percentage + 0)% used"] as $also |
          {provider: "claude", source: "cusage", account: $l, status: "known",
           effectivePercentRemaining: $left, limitedBy: $limit.key, windows: $w,
           summary: ("claude \($left)% left, limited by \($limit.key) (\($w | map("\(.key) \(.usedPercent)% used") | join(", "))" +
             (if $also == [] then "" else "; also \($also | join(", "))" end) +
             "; cusage account \($l), as of \($age | age) ago)")}
        end
      end
    end' 2>/dev/null || unknown "$label" "cusage -c -j gave no readable account list (exit $rc); $POLLER"
}

fill() {
  local snapshot claude
  snapshot=$(cat) || die "cannot read the snapshot on stdin"
  printf '%s\n' "$snapshot" | fm_quota_json_valid || die "stdin is not a valid quota-axi --json snapshot"
  if printf '%s\n' "$snapshot" | jq -e "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row |
    $row != null and (["known", "partial"] | index($row.quotaSemantics.status)) != null' >/dev/null 2>&1; then
    printf '%s\n' "$snapshot"
    return 0
  fi
  claude=$(reading)
  printf '%s\n' "$snapshot" | jq -c --argjson r "$claude" '
    . + {claudeQuota: $r} |
    if $r.status != "known" then .
    else
      (.schemaVersion == 6) as $six |
      .providers |= (map(select(.provider != "claude" or ($six and .accountKey != "default"))) +
        [{provider: "claude"} + (if $six then {accountKey: "default"} else {} end) +
         {source: "cusage", quotaSemantics: {status: "known", effectiveAvailability: [
           {scope: "all_models", status: "known", effectivePercentRemaining: $r.effectivePercentRemaining,
            boundedBy: [$r.limitedBy],
            runway: {status: (if $r.effectivePercentRemaining <= 0 then "exhausted_now" else "unknown" end)}}]}}])
    end' || die "cannot fill the snapshot"
}

case "${1:-}" in
--fill) [ "$#" -eq 1 ] || die "--fill takes no argument"; fill ;;
-h | --help | help) usage ;;
*) die "usage: fm-claude-quota.sh --fill (see --help)" ;;
esac
