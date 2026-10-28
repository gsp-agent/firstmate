#!/usr/bin/env bash
# Crew resume records for Herdr restore.
#
# Codex crew launch with --disable hooks, so Herdr never learns the Codex
# session from its hook. fm_crew_codex_session_id finds the session Codex
# itself wrote for this worktree, and fm_crew_report_codex_session reports it
# to the pane's Herdr server with the exact report Herdr's Codex hook would
# have sent, so a restore types `codex resume <id>` and the restore gate
# paces it.
#
# Grok crew run under a per-task GROK_HOME with --always-approve, which a
# bare `grok --resume <id>` does not carry. fm_crew_grok_session finds the
# session Grok wrote for this worktree, and fm_crew_grok_resume_record_write
# records its worker home under the operator Grok home at
# fm-crew-resume/<session-id> (one line: the absolute worker home). That file
# is the contract the agent-config Grok guard needs on a bare --resume: when
# it exists, exec the real Grok with GROK_HOME set to the recorded home and
# --always-approve added. Until the guard reads it, the record is inert.

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
    --source herdr:codex --agent codex --agent-session-id "$3"
}

fm_crew_grok_session() { # <sessions-dir> <worktree> [since-epoch]
  python3 -I - "$1" "$2" "${3:-0}" <<'PY'
import json, os, sys
root, wt, since = sys.argv[1], os.path.realpath(sys.argv[2]), float(sys.argv[3] or 0)
best = None
for cwd_dir in os.listdir(root) if os.path.isdir(root) else []:
    base = os.path.join(root, cwd_dir)
    if not os.path.isdir(base):
        continue
    for sid in os.listdir(base):
        path = os.path.join(base, sid, "summary.json")
        try:
            if since and os.path.getmtime(path) < since - 2:
                continue
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            info = data.get("info") or {}
            if info.get("id") != sid or not info.get("cwd"):
                continue
            if os.path.realpath(info["cwd"]) != wt:
                continue
            cand = (os.path.getmtime(path), sid, data.get("grok_home") or "")
            if best is None or cand > best:
                best = cand
        except Exception:
            continue
if best:
    print(f"{best[1]}\t{best[2]}")
PY
}

fm_crew_grok_resume_record_write() { # <operator-grok-home> <session-id> <worker-home>
  local dir=$1/fm-crew-resume tmp
  case ${2:-} in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case ${3:-} in /*) ;; *) return 1 ;; esac
  mkdir -p "$dir" || return 1
  tmp=$dir/.$2.tmp.$$
  printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$dir/$2"
}

fm_crew_grok_resume_record_read() { # <operator-grok-home> <session-id>
  case ${2:-} in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  local home
  home=$(head -n 1 "$1/fm-crew-resume/$2" 2>/dev/null) || return 1
  case $home in /*) printf '%s\n' "$home" ;; *) return 1 ;; esac
}
