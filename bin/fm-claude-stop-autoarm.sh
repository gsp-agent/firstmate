#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it. An idle home with no unread
#     record exits 0. An unread record is delivered; on an idle host home
#     that includes routine rows, because no park will run the engine.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &); Claude owns the process group, so its timeout/session teardown
#     kills arm and watcher together, and the hook TERMs the arm with itself.
#     HUP, TERM, and INT are translated through the ordinary durable failure
#     handoff instead of leaving the generation frozen at arming. Claude does
#     not deliver the exit 2 of a hook it terminated at the configured timeout
#     as a rewake (measured on Claude Code 2.1.278 and 2.1.281,
#     docs/verification/supervision.md), so a park that outlives that timeout
#     records the failure durably without waking an idle primary; nothing here
#     shortens a quiet park, because no-change heartbeats are absorbed without
#     closing the arm.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm takes that covering cycle over. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Translation: while AFK remains inactive, an actionable arm close
#     (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"), including when that event ends supervision need.
#     The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A banner or notice is printed only after its own commit wins, so a later
#     unread-record delivery never carries a refused notice. The banner shows
#     the close's wake lines, then unread rows not already among them, eight
#     wake lines in all. A close that
#     reports no actionable reason is benign when a live identity-matched
#     watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# this generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses later failure notices in that unresolved episode. It does not
# suppress delivery of an unread record.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# The Stop hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused, both before anything
# is sourced, read, or armed. A park started from a model's tool call would be
# owned by that short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh

Claude Stop hook registered in .claude/settings.json; not for manual use.
It reads the Stop payload on stdin and, in a primary home that needs
supervision or holds an unread record, arms the watcher or supervision host
for this session.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# Check the existing home before fm-wake-lib creates STATE on source; the
# Stop hook must not manufacture the prerequisite that admits a checkout.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

# Allow a healthy watcher's terminal wait to run without a stale-beacon alarm.
# docs/turnend-guard.md "Guard grace and the poll cadence" owns refresh cadence;
# fm_poll_derived_grace (bin/fm-wake-lib.sh) owns the grace derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before any arming decision.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the AFK gate and the admission gate
# (supervision need, or an unread record), so an away home, or an idle home
# with no unread record, remains byte-for-byte inert. Missing or malformed
# locks are uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}

# main-only while an attended host home needs supervision, because the park
# runs the engine that owns routine rows. Every row on a plain home, with the
# host off, or on a host home with no supervision need, where no park will run
# that engine. No scope (return 1) while the away daemon's flag or, on a host
# home, the away record is present: the daemon or the host then takes every
# close. A caller that has just read need passes idle or needed, so need is
# not probed twice at one decision point.
main_unread_scope() {  # [idle|needed]
  [ -e "$STATE/.afk" ] && return 1
  if fm_supervision_host_enabled "$CONFIG" claude; then
    fm_afk_contract_away_present "$STATE" && return 1
    case "${1:-}" in
      needed) printf 'main-only\n'; return 0 ;;
      idle) ;;
      *)
        if need_supervision; then
          printf 'main-only\n'
          return 0
        fi
        ;;
    esac
  fi
  printf 'any\n'
}

# Exit 2 when this generation delivers an unread record. Exit 0 when a record
# was unread but the commit was refused. Return 1 when there is nothing to
# deliver or this generation no longer owns the epoch.
deliver_unread_instead() {  # [idle|needed]
  local scope rows banner
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    return 1
  fi
  scope=$(main_unread_scope "${1:-}") || return 1
  rows=$(fm_wake_main_unread "$STATE" "$scope") || return 1
  [ -n "$rows" ] || return 1
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    return 1
  fi
  banner=$(
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    printf '%s\n' "$rows" | head -8
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  )
  if autoarm_commit rewake; then
    printf '%s\n' "$banner" >&2
    [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
}

# A home with no supervision need still admits when an unread record is waiting.
# The probe's own output is discarded. Delivery after the claim prints it.
if ! need_supervision; then
  [ -s "$STATE/.wake-queue" ] || exit 0
  UNREAD_SCOPE=$(main_unread_scope idle) || exit 0
  fm_wake_main_unread "$STATE" "$UNREAD_SCOPE" >/dev/null || exit 0
fi

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A live open claim defers at once: its owner arms and
# delivers. A micro-mutex contention with a bare hold is another participant's
# short ledger section, held only for a ledger write, so the claim is retried
# a few times over about a second before the contention exit: an idle main
# may fire no next Stop. A role-carrying hold is a legacy lock-holding claim
# from a pre-generation build (or the guard's own terminal-check), which the
# legacy shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
CLAIM_TRIES=0
while :; do
  fm_autoarm_claim_next "$STATE" "$GRACE"
  CLAIM_RC=$?
  [ "$CLAIM_RC" -eq 1 ] || break
  [ -z "$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)" ] || break
  CLAIM_TRIES=$((CLAIM_TRIES + 1))
  [ "$CLAIM_TRIES" -lt 5 ] || break
  sleep 0.2
done
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS: the
# caller prints its banner or notice only then, and exits 2. Markerless
# outcomes commit with the owned ledger write; a notice wins only when its
# following marker write succeeds in the same hold. Failure means refused or
# unverifiable: the caller prints nothing for that outcome, so a later
# winning delivery never carries text a refused commit composed.
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# A superseded generation remains silent. An episode whose attended fail-open
# was already consumed starts no failure continuation, though an unread record
# is still delivered with exit 2.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    deliver_unread_instead || true
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    if autoarm_commit failed "$FAILURE_NOTICE"; then
      printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
      printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
      exit 2
    fi
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child this hook waits on, never a fire-and-forget shell
# & whose child would be reaped when the hook returned: this hook process tree
# is the harness-owned lifecycle. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited for 60 seconds. The child arm's confirm budget is 30 seconds and
# is set only on this launch, so a short FM_ARM_CONFIRM_TIMEOUT in this
# process does not shrink either wait. It is a covering successor
# (bin/fm-watch-arm.sh FM_WATCH_COVER), so a fleet event during the handling
# turn does not leave the home uncovered. Sets SUCCESSOR_FAILURE to the banner
# line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline line monitor_was_on=0 handoff_deadline=
  case $- in *m*) monitor_was_on=1 ;; esac
  while :; do
    if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
      SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
      return 1
    fi
    set -m 2>/dev/null || true
    FM_ARM_CONFIRM_TIMEOUT=30 FM_WATCH_COVER=1 FM_WATCH_PREDECESSOR_ARM_PID=$1 \
      FM_GUARD_GRACE="$GRACE" \
      nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
    pid=$!
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
    deadline=$(( $(date +%s) + 60 ))
    while :; do
      grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null && break
      grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep 0.2
    done
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      if "$SCRIPT_DIR/fm-watch-arm.sh" --cover-handoff "$pid" >/dev/null 2>&1; then
        rm -f "$out" 2>/dev/null || true
        return 0
      fi
      [ -n "$handoff_deadline" ] || handoff_deadline=$(( $(date +%s) + 60 ))
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out" 2>/dev/null || true
      [ "$(date +%s)" -lt "$handoff_deadline" ] && continue
      SUCCESSOR_FAILURE="The handling successor pid=$pid could not record its coverage handover."
      return 1
    fi
    line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
    rm -f "$out" 2>/dev/null || true
    [ -z "$line" ] || line=" ($line)"
    SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
    return 1
  done
}

OUT=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
# Rows already queued are delivered before the park. Routine rows on an
# attended host home are not in this scope, so they still reach the park.
# A home admitted only for an unread row arms nothing once no such row is left.
if ! need_supervision; then
  deliver_unread_instead idle || { autoarm_record clean; exit 0; }
fi
deliver_unread_instead needed || true
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    HOST_RC=0
    FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
  else
    run_arm "$OUT"
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break
  if [ "$HOST_MODE" -eq 1 ]; then
    # The host stood down because this session or generation no longer owns
    # supervision: whoever does owns continuity now.
    if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
      autoarm_record clean
      rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    # A host that died without a close may have left its cycle running with
    # no owner to deliver the close; retrying lets the next host stop what it
    # left and own a fresh cycle, which the healthy-watcher predicate cannot.
    if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
      deliver_unread_instead || true
      [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      OUT=
      continue
    fi
    # A failed hand-back cannot be dismissed just because its successor
    # watcher is healthy: the close is still undelivered.
    [ "$HOST_RC" -eq 0 ] || break
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# If the need vanished mid-cycle, close quietly only when there is no captured
# event to deliver: releasing the final probe hold can itself end that need.
if [ "$ACTIONABLE" -eq 0 ] && ! need_supervision; then
  autoarm_record clean
  deliver_unread_instead idle || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
fi

if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    deliver_unread_instead || {
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    }
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    deliver_unread_instead || {
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    }
  fi
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    if [ -e "$FAILURE_ALARM" ]; then
      deliver_unread_instead || exit 0
    fi
    exit 2
  fi
  deliver_unread_instead || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  unread_rows=
  if UNREAD_SCOPE=$(main_unread_scope); then
    unread_rows=$(fm_wake_main_unread "$STATE" "$UNREAD_SCOPE" || true)
  fi
  BANNER=$(
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    UNREAD_ROWS=$unread_rows awk -v host="$HOST_MODE" '
      BEGIN { rows = split(ENVIRON["UNREAD_ROWS"], unread, "\n") }
      host == 1 && /^supervision-host:/ { print; next }
      /^(signal:|stale:|check:|heartbeat)/ { if (shown < 8) { print; shown++ } seen[$0] = 1 }
      END {
        for (i = 1; i <= rows && shown < 8; i++) {
          if (unread[i] == "" || (unread[i] in seen)) continue
          print unread[i]
          seen[unread[i]] = 1
          shown++
        }
      }
    ' "${OUT:-/dev/null}" 2>/dev/null
    if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
      && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
      printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
    fi
    [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  )
  if autoarm_commit rewake; then
    printf '%s\n' "$BANNER" >&2
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]]; then
    if [ ! -e "$FAILURE_NOTICE" ]; then
      if autoarm_commit failed "$FAILURE_NOTICE"; then
        printf '%s\n' "$BANNER" >&2
        printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        exit 2
      fi
    elif autoarm_commit failed-suppressed; then
      printf '%s\n' "$BANNER" >&2
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  deliver_unread_instead || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
fi

# The alarm suppresses another failure notice. It does not suppress a record.
if [ -e "$FAILURE_ALARM" ]; then
  deliver_unread_instead || true
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  NOTICE=$(
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  )
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    printf '%s\n' "$NOTICE" >&2
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  deliver_unread_instead || {
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  }
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
deliver_unread_instead || {
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
}
