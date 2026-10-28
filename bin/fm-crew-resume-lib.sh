#!/usr/bin/env bash
# Codex crew resume on a Herdr restore.
#
# Codex crew launch with --disable hooks, so Herdr never learns the Codex
# session from its hook. fm_crew_codex_session_id finds the session Codex
# itself wrote for this worktree, and fm_crew_report_codex_session reports it
# to the pane's Herdr server with the exact report Herdr's Codex hook would
# have sent, then reads the pane's registration back: Herdr can accept a
# report with rc=0 and never apply it (bin/backends/herdr.sh's
# fm_backend_herdr_pane_agent_session_ref), so only the read-back counts.
# A restore then types `codex resume <id>` and the restore gate paces it.
#
# That bare resume carries neither the crew's CODEX_HOME nor its launch flags.
# fm_crew_codex_args is the one list of Codex crew launch arguments after the
# model and effort flags: bin/fm-spawn.sh renders it into the launch line with
# fm_crew_shell_words and records the same list. state/<task>.meta already
# holds the task's model, effort, harness, kind and worktree;
# fm_crew_codex_resume_record_write keeps the rest in
# state/<task>.codex-resume, found from a session id by its session_id= line:
#   session_id=<id>
#   codex_home=<absolute CODEX_HOME>
#   arg=<one launch argument per line, in order>
# Teardown removes it with the task's other state files.

# launch_template in bin/fm-spawn.sh says why a crew carries each of these.
fm_crew_codex_args() { # <shell-quoted turn-end path>
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_CREW_CODEX_ARGS=(--dangerously-bypass-approvals-and-sandbox --disable hooks -c "notify=[\"bash\",\"-c\",\"touch $1\"]")
}

fm_crew_shell_words() { # <arg>...: each argument as a shell word and a space
  local w
  for w in "$@"; do
    case $w in
    '' | *[!A-Za-z0-9_./:=-]*) printf "'%s' " "$(printf '%s' "$w" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s ' "$w" ;;
    esac
  done
}

fm_crew_codex_session_id() { # <codex-home> <worktree> <since-epoch>
  python3 -I - "$1" "$2" "$3" <<'PY'
import json, os, sys
home, wt, since = sys.argv[1], os.path.realpath(sys.argv[2]), float(sys.argv[3])
best = None
for root, _dirs, files in os.walk(os.path.join(home, "sessions")):
    for name in files:
        if not name.startswith("rollout-") or not name.endswith(".jsonl"):
            continue
        path = os.path.join(root, name)
        try:
            if os.path.getmtime(path) < since - 2:
                continue
            with open(path, encoding="utf-8") as fh:
                meta = json.loads(fh.readline())
            payload = meta.get("payload") or {}
            sid = payload.get("id") or payload.get("session_id")
            if sid and payload.get("cwd") and os.path.realpath(payload["cwd"]) == wt:
                cand = (os.path.getmtime(path), sid)
                if best is None or cand > best:
                    best = cand
        except Exception:
            continue
if best:
    print(best[1])
PY
}

fm_crew_report_codex_session() { # <herdr-session> <pane-id> <session-id>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  fm_backend_herdr_cli "$1" pane report-agent-session "$2" \
    --source herdr:codex --agent codex --agent-session-id "$3" >/dev/null || return 1
  [ "$(fm_backend_herdr_pane_agent_session_ref "$1" "$2")" = "codex	$3" ]
}

fm_crew_codex_resume_record_write() { # <record> <session-id> <codex-home> <launch-arg>...
  local record=$1 sid=$2 home=$3 tmp arg
  shift 3
  case $sid in '' | */* | *[[:space:]]*) return 1 ;; esac
  case $home in /*) ;; *) return 1 ;; esac
  tmp=$record.tmp.$$
  if ! {
    printf 'session_id=%s\n' "$sid"
    printf 'codex_home=%s\n' "$home"
    for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
  } >"$tmp" || ! mv -f "$tmp" "$record"; then
    rm -f "$tmp"
    return 1
  fi
}
