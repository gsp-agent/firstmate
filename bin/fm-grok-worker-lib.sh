#!/usr/bin/env bash
# Worker-only Grok configuration and launch text for crewmate and scout
# spawns. bin/fm-spawn.sh provisions the worker home and renders the launch
# brief; bin/fm-control.sh runs fm_grok_worker_skills as a relaunch
# pre-check, so a skills file the launch would refuse stops the relaunch
# before the running worker is stopped.
# Usage: . bin/fm-grok-worker-lib.sh
#
# fm_grok_worker_skills <skills-file> prints the skill names the spawning
# home's optional config/grok-worker-skills lists: one name per line, with
# surrounding whitespace trimmed and blank and `#` lines ignored. An absent
# file prints nothing; a present one that cannot be read as UTF-8 text
# prints a cannot-read error on stderr and returns 1.
#
# fm_grok_worker_provision <operator-grok-home> <worker-home> <worktree>
#   <skills-file>
# creates a per-task Grok home that trims the fixed launch context a worker
# otherwise inherits from the operator's seat: the discovered skills index
# (all but the built-in allowlist below and the names fm_grok_worker_skills
# reads from <skills-file>), compat and user-config MCP servers, plugin
# skills, image/video tools, and oversized tool output.
# Discovery is `grok inspect --json` in the worktree at spawn time, so no
# operator-specific server, skill, or plugin name is ever recorded here.
# The worker home carries a generated config.toml plus a symlink to each of
# these operator Grok home entries that exists: auth.json (sign-in is
# referenced, never copied), trusted_folders.toml (folder trust, so project
# instructions and global hooks load as they do for the operator), the
# AGENTS.md and rules global instructions, the managed_config.toml and
# requirements.toml policy files, the hooks directory (the turn-end hook
# bin/fm-spawn.sh installs there keeps loading unchanged), and the sessions
# directory (worker transcripts land with the operator's and outlive
# teardown, which removes only the link).
# The one write to the operator's home is creating that sessions directory
# when it is absent, so the link never dangles.
# The worker home, and the operator sessions directory when provisioning
# creates it, are private (mode 0700), matching Grok's own home.
# When discovery fails or is unavailable (no grok or python3 on PATH), the
# generated config still carries the compat, media, and output-cap sections,
# and a one-line warning on stderr names the failure and the worker home
# whose skills index and MCP servers stay untrimmed.
#
# fm_grok_worker_context_rules prints the tool-output and skill-loading
# discipline every Grok ship and scout launch brief carries, so exploration
# before the first edit stays small; bin/fm-spawn.sh renders it into Grok
# launches only, and no other harness receives it.
#
# fm_grok_slim_launch_brief <source-brief> <state> <task-id> <code-root>
#   <decision-owner>
# prints the launch brief the full path prints, minus the source brief's
# Waiting, Project memory, and Definition of done sections. It carries the
# Definition of done's delivery lines and names each left-out section with
# the point at which the worker reads it from the full brief, along with
# the Setup, Rules, and home brief additions sections it carries. Every
# other section (Task, the Herdr declaration or contract, Setup, Rules with
# its status command, the instruction inbox, and home brief additions) is
# carried verbatim.
# It returns 1 without printing when the source has none of the left-out
# sections, or carries a continuation note bin/fm-control.sh appends (a
# relaunch `## Progress note` or a restore `## Restore note`), so the caller
# falls back to the full launch brief and the worker reads that note up front.
# Secondmate charters never take either path: fm-spawn.sh gates both on
# KIND != secondmate, so a supervisor seat keeps its full configuration.

FM_GROK_WORKER_ALLOW_SKILLS='firstmate-coding-guidelines long-running-background-tasks no-mistakes'

fm_grok_worker_home() {  # <state-dir> <task-id>
  printf '%s/%s.grok-home\n' "$1" "$2"
}

fm_grok_worker_skills() {  # <skills-file>
  [ -e "$1" ] || [ -L "$1" ] || return 0
  python3 -I - "$1" <<'PY'
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
except OSError as exc:
    sys.exit(f"error: cannot read {path}: {exc.strerror}")
except UnicodeDecodeError:
    sys.exit(f"error: cannot read {path}: not UTF-8 text")
for line in lines:
    line = line.strip()
    if line and not line.startswith("#"):
        print(line)
PY
}

fm_grok_worker_provision() {  # <operator-grok-home> <worker-home> <worktree> <skills-file>
  local op_home=$1 worker_home=$2 worktree=$3 skills_file=$4 extra_skills name
  [ -n "$op_home" ] && [ -n "$worker_home" ] && [ -n "$worktree" ] && [ -n "$skills_file" ] || return 1
  extra_skills=$(fm_grok_worker_skills "$skills_file") || return 1
  (umask 077 && mkdir -p "$worker_home" "$op_home/sessions") || return 1
  for name in auth.json trusted_folders.toml AGENTS.md rules managed_config.toml requirements.toml hooks sessions; do
    [ -e "$op_home/$name" ] || [ -L "$op_home/$name" ] || continue
    if [ ! -e "$worker_home/$name" ] && [ ! -L "$worker_home/$name" ]; then
      ln -s "$op_home/$name" "$worker_home/$name" || return 1
    fi
  done
  if command -v python3 >/dev/null 2>&1 && command -v grok >/dev/null 2>&1; then
    FM_GROK_ALLOW="$FM_GROK_WORKER_ALLOW_SKILLS $extra_skills" python3 -I - "$op_home" "$worker_home" "$worktree" <<'PY' || return 1
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
except Exception as exc:
    print(f"warning: Grok worker home {worker_home}: grok inspect --json failed ({type(exc).__name__}: {exc}); its skills index and MCP servers are not trimmed", file=sys.stderr)

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
    echo "warning: Grok worker home $worker_home: python3 or grok is not on PATH, so discovery did not run; its skills index and MCP servers are not trimmed" >&2
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

fm_grok_worker_context_rules() {
  cat <<'EOF'
# Worker context discipline
Keep the context before your first edit small.
Read files in ranges that cover what you need; do not dump a whole file when a range will do.
Cap search and grep output near 50 lines, and narrow the pattern or path when it returns more.
Tail or head long command output instead of capturing all of it.
Do not read skills at session start.
Load a skill only when a step needs it, by reading that skill's SKILL.md at that point.
A skill your session does not list is at the project's `.agents/skills/<name>/SKILL.md`, or at the path the instruction naming it gives.
EOF
}

fm_grok_slim_launch_brief() {  # <source-brief> <state> <task-id> <code-root> <decision-owner>
  local source_brief=$1 state=$2 task_id=$3 root=$4 decision_owner=$5
  local body done_lines pointer='' carried='' heading when
  ! grep -qE '^## (Progress|Restore) note \(' "$source_brief" || return 1
  body=$(cat "$source_brief") || return 1
  done_lines=$(fm_brief_heading_body "$source_brief" "# Definition of done" |
    grep -E '^(Delivery contract: |Ship branch: |Write your findings to )')
  while IFS='|' read -r heading when; do
    fm_brief_heading_present - "$heading" <<<"$body" || continue
    body=$(fm_brief_heading_omit - "$heading" <<<"$body") || return 1
    pointer+="- \`$heading\` $when"$'\n'
  done <<'SECTIONS'
# Waiting|before you wait on anything.
# Project memory|before you edit a project's AGENTS.md or CLAUDE.md.
# Definition of done|before you report done.
SECTIONS
  [ -n "$pointer" ] || return 1
  for heading in '# Setup' '# Rules' '# Home brief additions'; do
    fm_brief_heading_present - "$heading" <<<"$body" && carried+="${carried:+, }\`$heading\`"
  done
  fm_brief_worker_role "$state" "$task_id" "$root" || return 1
  printf '\nDecision owner for this dispatch: %s\n\n' "$decision_owner"
  printf '%s\n' "$body"
  printf '\n# Full brief\n'
  printf 'The complete brief is at `%s`.\n' "$source_brief"
  [ -z "$carried" ] || printf 'This launch text already carries its %s sections in full above.\n' "$carried"
  printf 'It leaves out the sections below; they remain the contract, so read each one from that file at the point named:\n%s' "$pointer"
  [ -z "$done_lines" ] || printf 'Its Definition of done opens with:\n%s\n' "$done_lines"
  return 0
}
