#!/usr/bin/env bash
# fm-live-session-lib.sh - whether a worker spawn may dispatch into a
# project right now, given an outside live-session detector.
#
# A live session - a tester, a client, or the captain at a headset, present or
# waiting at a set time - is run by the project's own agent, never by
# Firstmate. When the machine has a live-session detector installed,
# bin/fm-control.sh and bin/fm-spawn.sh ask it about the project before stopping
# or launching a ship or scout and defer unless the detector reads clear. Without a
# detector nothing changes.
#
# This file is the single owner of how the detector is found and called and of
# the admission verdict. docs/configuration.md "Live-session check" is the
# operator reference, and the callers own where the check runs.
#
# Detector: FM_LIVE_SESSION_CHECK when that variable is set, otherwise
# ~/.agent-config/scripts/live-session.py. A missing file, including an empty
# override, leaves dispatch unchanged. The detector is an outside check that
# this repository does not ship; its own header owns what it observes. It is
# run as `python3 <detector> <folder>`, bounded to 45 seconds because the
# detector already reads unknown once its own collection outlasts 30. Its
# stderr is discarded: the detector keeps raw source errors out of its output,
# and a crash trace could carry them. Its exit contract:
#   0   clear, no observed live signal; stdout is empty
#   75  live; one stdout line names signal= and source=
#   2   unknown, including bad input and unavailable sources; one stdout line
#       names signal=, source=, and reason=
# Any other status, including the bound and a missing python3, is unknown too,
# because the contract says an undecided read must never be treated as clear.
#
# <folder> is the name of the project's checkout folder, not Firstmate's
# registered project name: the detector matches it as a whole directory
# component of a person's pane, device, calendar, and reservation context, so
# the name must be the one the captain's own checkout carries. That is the last
# component of the project directory with symlinks resolved, so a registered
# agent-config whose directory links to ~/.agent-config is asked about
# .agent-config; asking about agent-config would read a live session as clear.
#
# Admission: clear admits, live defers, and unknown defers. Unknown defers
# because the detector's sources rarely fail on harmless input on the machine
# this was measured on, so an unknown is more likely a real gap than noise;
# the deferral names the detector's reason so a failing source is fixed rather
# than worked around.

FM_LIVE_SESSION_TIMEOUT_SECS=45

# Decide whether a worker for <project-dir> may launch now.
# Returns 0 to admit, or prints why the spawn is deferred and returns 1.
# Requires bin/fm-timeout-lib.sh.
fm_live_session_admit() {  # <project-dir> <project-name>
  local check folder rc=0 out line
  if [ "${FM_LIVE_SESSION_CHECK+x}" = x ]; then
    check=$FM_LIVE_SESSION_CHECK
  else
    check=${HOME}/.agent-config/scripts/live-session.py
  fi
  [ -n "$check" ] && [ -f "$check" ] || return 0
  folder=$(basename -- "$(CDPATH='' cd -- "$1" && pwd -P)")
  out=$(fm_run_timed "$FM_LIVE_SESSION_TIMEOUT_SECS" python3 "$check" "$folder" 2>/dev/null </dev/null) || rc=$?
  line=${out%%$'\n'*}
  if [ -z "$line" ]; then
    if fm_timed_out "$rc"; then
      line="no verdict within ${FM_LIVE_SESSION_TIMEOUT_SECS}s"
    else
      line="exit $rc with no verdict line"
    fi
  fi
  case "$rc" in
    0) return 0 ;;
    75) printf '%s\n' "a person is live on project $2 (live-session check of folder $folder: $line), and a live session is run by the project's own agent, never by Firstmate" ;;
    *) printf '%s\n' "the live-session check cannot tell whether a person is live on project $2 (folder $folder: $line), and an undecided check never counts as clear" ;;
  esac
  return 1
}
