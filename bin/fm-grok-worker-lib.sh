#!/usr/bin/env bash
# Worker-only Grok configuration and slim launch rendering for crewmate and
# scout spawns (bin/fm-spawn.sh is the one caller).
# Usage: . bin/fm-grok-worker-lib.sh
#
# fm_grok_worker_provision <operator-grok-home> <worker-home> <worktree>
# creates a per-task Grok home that trims the fixed launch context a worker
# otherwise inherits from the operator's seat: the discovered skills index
# (all but a small allowlist), compat and user-config MCP servers, plugin
# skills, image/video tools, and oversized tool output.
# Discovery is `grok inspect --json` in the worktree at spawn time, so no
# operator-specific server, skill, or plugin name is ever recorded here.
# The operator's own home is never written: the worker home carries only a
# generated config.toml plus symlinks to the operator's auth.json (sign-in
# is referenced, never copied) and hooks directory (the turn-end hook
# bin/fm-spawn.sh installs there keeps loading unchanged).
# When discovery is unavailable (no grok or python3 on PATH), the generated
# config still carries the compat, media, and output-cap sections.
#
# fm_grok_slim_launch_brief <source-brief> <state> <task-id> <code-root>
#   <kind> <decision-owner>
# prints a short launch brief: the worker role, the task intent and spec,
# the delivery lines, the Herdr contract when the source carries one, the
# context discipline, and a pointer to the full brief for the sections a
# worker needs only later (rules, waiting, definition of done).
# It returns 1 when the source has no filled intent or spec subsection, so
# the caller falls back to the full launch brief rather than guessing.
# Secondmate charters never take either path: fm-spawn.sh gates both on
# KIND != secondmate, so a supervisor seat keeps its full configuration.

FM_GROK_WORKER_ALLOW_SKILLS='firstmate-coding-guidelines long-running-background-tasks no-mistakes'

fm_grok_worker_home() {  # <state-dir> <task-id>
  printf '%s/%s.grok-home\n' "$1" "$2"
}

fm_grok_worker_provision() {  # <operator-grok-home> <worker-home> <worktree>
  local op_home=$1 worker_home=$2 worktree=$3
  [ -n "$op_home" ] && [ -n "$worker_home" ] && [ -n "$worktree" ] || return 1
  mkdir -p "$worker_home" || return 1
  if [ -e "$op_home/auth.json" ] || [ -L "$op_home/auth.json" ]; then
    if [ ! -e "$worker_home/auth.json" ] && [ ! -L "$worker_home/auth.json" ]; then
      ln -s "$op_home/auth.json" "$worker_home/auth.json" || return 1
    fi
  fi
  if [ ! -e "$worker_home/hooks" ] && [ ! -L "$worker_home/hooks" ]; then
    ln -s "$op_home/hooks" "$worker_home/hooks" || return 1
  fi
  if command -v python3 >/dev/null 2>&1 && command -v grok >/dev/null 2>&1; then
    FM_GROK_ALLOW="$FM_GROK_WORKER_ALLOW_SKILLS" python3 -I - "$op_home" "$worker_home" "$worktree" <<'PY' || return 1
import json, os, subprocess, sys

op_home, worker_home, worktree = sys.argv[1:4]
allow = set(os.environ.get("FM_GROK_ALLOW", "").split())
skills, mcps, plugins = set(), set(), set()
try:
    out = subprocess.run(
        ["grok", "inspect", "--json"],
        capture_output=True, text=True, cwd=worktree, timeout=60,
    )
    data = json.loads(out.stdout)
    skills = {s["name"] for s in data.get("skills", []) if s.get("name")}
    mcps = {m["name"] for m in data.get("mcpServers", []) if m.get("name")}
    plugins = {p["name"] for p in data.get("plugins", []) if p.get("name")}
except Exception:
    pass

model_default = ""
try:
    import tomllib
    with open(os.path.join(op_home, "config.toml"), "rb") as fh:
        cfg = tomllib.load(fh)
    value = cfg.get("models", {}).get("default", "")
    if isinstance(value, str):
        model_default = value
except Exception:
    pass

def toml_list(values):
    return "[" + ", ".join(json.dumps(v) for v in sorted(values)) + "]"

lines = [
    "# Generated per-task worker configuration. Do not edit by hand.",
    "disabled_mcp_servers = " + toml_list(mcps),
    "",
    "[skills]",
    "disabled = " + toml_list(skills - allow),
    "",
    "[compat.claude]",
    "skills = false",
    "mcps = false",
    "",
    "[compat.cursor]",
    "skills = false",
    "mcps = false",
    "",
    "[plugins]",
    "disabled = " + toml_list(plugins),
    "",
    "[features]",
    "image_gen = false",
    "video_gen = false",
    "",
    "[mcp]",
    "max_output_bytes = 8000",
    "",
    "[toolset.bash]",
    "output_byte_limit = 8000",
]
if model_default:
    lines += ["", "[models]", "default = " + json.dumps(model_default)]
with open(os.path.join(worker_home, "config.toml"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
PY
  else
    cat >"$worker_home/config.toml" <<'EOF' || return 1
# Generated per-task worker configuration. Do not edit by hand.
disabled_mcp_servers = []

[compat.claude]
skills = false
mcps = false

[compat.cursor]
skills = false
mcps = false

[features]
image_gen = false
video_gen = false

[mcp]
max_output_bytes = 8000

[toolset.bash]
output_byte_limit = 8000
EOF
  fi
  return 0
}

fm_grok_slim_launch_brief() {  # <source-brief> <state> <task-id> <code-root> <kind> <decision-owner>
  local source_brief=$1 state=$2 task_id=$3 root=$4 kind=$5 decision_owner=$6
  local intent spec delivery ship_branch base_branch herdr_section status_file report_line
  intent=$(fm_brief_task_heading_body "$source_brief" "## Captain's intent") || intent=
  spec=$(fm_brief_task_heading_body "$source_brief" "## Firstmate spec") || spec=
  [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
  [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
  delivery=$(sed -n 's/^Delivery contract: .*/&/p' "$source_brief" | head -n 1)
  ship_branch=$(sed -n 's/^Ship branch: .*/&/p' "$source_brief" | head -n 1)
  base_branch=$(sed -n 's/^Base branch: .*/&/p' "$source_brief" | head -n 1)
  herdr_section=$(fm_brief_heading_body "$source_brief" "# Herdr isolation - HARD SAFETY CONTRACT") || herdr_section=
  status_file="$state/$task_id.status"
  fm_brief_worker_role "$state" "$task_id" "$root" || return 1
  printf '\nDecision owner for this dispatch: %s\n\n' "$decision_owner"
  printf '# Task\n## Captain'\''s intent\n%s\n\n## Firstmate spec\n%s\n' "$intent" "$spec"
  if [ -n "$delivery" ] || [ -n "$ship_branch" ] || [ -n "$base_branch" ]; then
    printf '\n'
    [ -z "$delivery" ] || printf '%s\n' "$delivery"
    [ -z "$ship_branch" ] || printf '%s\n' "$ship_branch"
    [ -z "$base_branch" ] || printf '%s\n' "$base_branch"
  fi
  if [ -n "$herdr_section" ]; then
    printf '\n# Herdr isolation - HARD SAFETY CONTRACT\n%s\n' "$herdr_section"
  fi
  printf '\n# Start here\n'
  if [ "$kind" = scout ]; then
    report_line=$(sed -n 's/^Write your findings to //p' "$source_brief" | head -n 1)
    [ -z "$report_line" ] || printf 'This is a scout task: the deliverable is a written report, not a PR. Write your findings to %s\n' "$report_line"
    printf 'Work in your disposable worktree; the report is the only thing that survives.\n'
  else
    printf 'Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, not the primary checkout.\n'
    printf 'If they do not, append `blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree` to `%s` and stop.\n' "$status_file"
    printf 'Confirm you are on your ship branch before editing; the full Setup section of the brief below names it.\n'
  fi
  printf 'Report status by appending one line `echo "{state} [at=<epoch>]: {one short line}" >> %s` with a numeric `date +%%s` stamp; states are working, needs-decision, blocked, paused, done, failed.\n' "'$status_file'"
  printf 'Your steering inbox is `%s/%s.inbox`; move each handled `NNN.msg` to its `handled/` directory.\n' "$state" "$task_id"
  printf '\n'
  fm_worker_context_rules || return 1
  printf '\n# Full brief\n'
  printf 'The complete brief is at `%s`.\n' "$source_brief"
  printf 'Read the section you need when you reach it: Rules before acting beyond setup, Waiting before waiting, and Definition of done before reporting done.\n'
  printf 'Those sections remain the contract; this launch text only defers them.\n'
  return 0
}
