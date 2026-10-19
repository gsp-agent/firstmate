#!/usr/bin/env bash
# Mint a disposable lab home and start a real Claude primary in it on a private
# tmux socket, per the repo's live-validation runbook. Prints the lab path.
#
# The gate worktree is a linked worktree, which fm_primary_root_matches treats
# as a crew worktree (every primary hook stays inert there), so the primary runs
# from a plain disposable checkout of the change's exact tree, $LAB/fmroot.
# The account was at 99% of its weekly limit, so the primary runs on Haiku at
# low effort; FM_CHECK_INTERVAL=5 makes the registered labprobe check sweep
# every 5s instead of every 300s so a case can raise a wake on demand. (The
# run itself first launched plain `claude`, then relaunched this way in the
# same lab home; the new session took over the stale lock.)
# Usage: lab-up.sh <worktree> [rev]
set -eu
WT=$1 REV=${2:-HEAD}
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fmroot" "$LAB/base"
git archive "$REV" | tar -x -C "$LAB/fmroot"
git -C "$LAB/fmroot" init -q
git -C "$LAB/fmroot" add -A
git -C "$LAB/fmroot" -c user.name=fm-lab -c user.email=fm-lab@invalid commit -qm "lab copy of $(git rev-parse --short "$REV")"
# Pre-change bin/ for side-by-side comparison against the same live home.
git archive 9cfe7cfe bin | tar -x -C "$LAB/base"
# The home runs the host (default on Claude; the opt-in file is harmless).
touch "$LAB/config/supervision-host"
# A registered custom check that prints nothing: the home needs supervision,
# so the Stop auto-arm arms the host, but nothing wakes until a case asks.
cat > "$LAB/state/labprobe.check.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/labprobe.fire" ] || cat "$FM_HOME/labprobe.fire"
exit 0
EOF
chmod 700 "$LAB/state/labprobe.check.sh"
FM_HOME="$LAB" bin/fm-check-register.sh labprobe >/dev/null
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_CHILD_SESSION \
  -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
  -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ATTENDED -u FM_SUPERVISION_MODEL -u TMUX -u TMUX_PANE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$LAB/fmroot" \
  -e FM_HOME="$LAB" -e FM_CHECK_INTERVAL=5 claude --model haiku --effort low
printf '%s\n' "$LAB"
