#!/usr/bin/env bash
# Worker-only Grok configuration and slim launch rendering for crewmate and
# scout spawns (bin/fm-spawn.sh is the one caller).
# Usage: . bin/fm-grok-worker-lib.sh
#
# fm_grok_worker_provision <operator-grok-home> <worker-home> <worktree>
#   <skills-file>
# creates a per-task Grok home that trims the fixed launch context a worker
# otherwise inherits from the operator's seat: the discovered skills index
# (all but the built-in allowlist below and the names <skills-file> lists),
# compat and user-config MCP servers, plugin skills, image/video tools, and
# oversized tool output.
# <skills-file> is the spawning home's optional config/grok-worker-skills:
# one skill name per line, with blank lines and `#` lines ignored. An absent
# file keeps only the built-in allowlist; one that cannot be read fails
# provisioning.
# Discovery is `grok inspect --json` in the worktree at spawn time, so no
# operator-specific server, skill, or plugin name is ever recorded here.
# The worker home carries a generated config.toml plus symlinks to the
# operator's auth.json (sign-in is referenced, never copied), hooks
# directory (the turn-end hook bin/fm-spawn.sh installs there keeps loading
# unchanged), and sessions directory (worker transcripts land with the
# operator's and outlive teardown, which removes only the link).
# The one write to the operator's home is creating that sessions directory
# when it is absent, so the link never dangles.
# When discovery is unavailable (no grok or python3 on PATH), the generated
# config still carries the compat, media, and output-cap sections.
#
# fm_grok_slim_launch_brief <source-brief> <state> <task-id> <code-root>
#   <decision-owner>
# prints the launch brief the full path prints, minus the source brief's
# Rules, Waiting, Project memory, and Definition of done sections. It carries
# the rule-4 status lines and the Definition of done's delivery lines, and
# names each left-out section with the point at which the worker reads it
# from the full brief. Every other section (Task, the Herdr declaration or
# contract, Setup, the instruction inbox, the context discipline, and home
# brief additions) is carried verbatim.
# It returns 1 without printing when the source has no rule-4 status lines
# or none of those sections, so the caller falls back to the full launch
# brief. bin/fm-spawn.sh also takes the full launch brief on a relaunch,
# because the progress note bin/fm-control.sh appends ends the source brief.
# Secondmate charters never take either path: fm-spawn.sh gates both on
# KIND != secondmate, so a supervisor seat keeps its full configuration.

FM_GROK_WORKER_ALLOW_SKILLS='firstmate-coding-guidelines long-running-background-tasks no-mistakes'

fm_grok_worker_home() {  # <state-dir> <task-id>
  printf '%s/%s.grok-home\n' "$1" "$2"
}

fm_grok_worker_provision() {  # <operator-grok-home> <worker-home> <worktree> <skills-file>
  local op_home=$1 worker_home=$2 worktree=$3 skills_file=$4 name
  [ -n "$op_home" ] && [ -n "$worker_home" ] && [ -n "$worktree" ] && [ -n "$skills_file" ] || return 1
  mkdir -p "$worker_home" "$op_home/sessions" || return 1
  if [ -e "$op_home/auth.json" ] || [ -L "$op_home/auth.json" ]; then
    if [ ! -e "$worker_home/auth.json" ] && [ ! -L "$worker_home/auth.json" ]; then
      ln -s "$op_home/auth.json" "$worker_home/auth.json" || return 1
    fi
  fi
  for name in hooks sessions; do
    if [ ! -e "$worker_home/$name" ] && [ ! -L "$worker_home/$name" ]; then
      ln -s "$op_home/$name" "$worker_home/$name" || return 1
    fi
  done
  if command -v python3 >/dev/null 2>&1 && command -v grok >/dev/null 2>&1; then
    FM_GROK_ALLOW="$FM_GROK_WORKER_ALLOW_SKILLS" python3 -I - "$op_home" "$worker_home" "$worktree" "$skills_file" <<'PY' || return 1
import json, os, subprocess, sys

op_home, worker_home, worktree, skills_file = sys.argv[1:5]
allow = set(os.environ.get("FM_GROK_ALLOW", "").split())
try:
    with open(skills_file, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                allow.add(line)
except FileNotFoundError:
    pass
except OSError as exc:
    sys.exit(f"error: cannot read {skills_file}: {exc.strerror}")
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

fm_grok_slim_launch_brief() {  # <source-brief> <state> <task-id> <code-root> <decision-owner>
  local source_brief=$1 state=$2 task_id=$3 root=$4 decision_owner=$5
  local body status_lines done_lines pointer='' heading when
  body=$(cat "$source_brief") || return 1
  status_lines=$(awk '
    /^4\. Report status by appending one line:$/ { grab = 1 }
    grab { sub(/^4\. /, ""); sub(/^   /, ""); out = out $0 "\n" }
    grab && /^Substitute `<epoch>`/ { printf "%s", out; exit }
  ' "$source_brief")
  [ -n "$status_lines" ] || return 1
  done_lines=$(fm_brief_heading_body "$source_brief" "# Definition of done" |
    grep -E '^(Delivery contract: |Ship branch: |Write your findings to )')
  while IFS='|' read -r heading when; do
    fm_brief_heading_present - "$heading" <<<"$body" || continue
    body=$(fm_brief_heading_omit - "$heading" <<<"$body") || return 1
    pointer+="- \`$heading\` $when"$'\n'
  done <<'SECTIONS'
# Rules|before you act beyond the Setup section above.
# Waiting|before you wait on anything.
# Project memory|before you edit a project's AGENTS.md or CLAUDE.md.
# Definition of done|before you report done.
SECTIONS
  [ -n "$pointer" ] || return 1
  fm_brief_worker_role "$state" "$task_id" "$root" || return 1
  printf '\nDecision owner for this dispatch: %s\n\n' "$decision_owner"
  printf '%s\n' "$body"
  printf '\n# Status\n%s\n' "$status_lines"
  printf '\n# Full brief\n'
  printf 'The complete brief is at `%s`.\n' "$source_brief"
  printf 'This launch text leaves out the sections below; they remain the contract, so read each one from that file at the point named:\n%s' "$pointer"
  [ -z "$done_lines" ] || printf 'Its Definition of done opens with:\n%s\n' "$done_lines"
  return 0
}
