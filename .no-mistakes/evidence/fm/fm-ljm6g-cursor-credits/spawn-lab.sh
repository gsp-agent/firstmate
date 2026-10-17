#!/usr/bin/env bash
# Drive the real bin/fm-spawn.sh --harness cursor in a disposable marked lab home
# (bin/fm-lab-home.sh), on the lab's private fm-lab tmux socket, at
# cursor_models_pct=100 with and without credit room. Nothing reaches a model:
#   - the bead is pre-seeded at 2 Cursor launches today, so a spawn that stays on
#     Cursor stops at the guard's `take` refusal before any pane or worktree;
#   - config/project-capacity names the project twice (an unreadable declaration),
#     so a spawn that falls back to Codex stops at project-capacity admission,
#     after the fallback is announced and recorded but before any pane or worktree.
# Usage: spawn-lab.sh <worktree> <evidence-dir>
set -u
WT=${1:?worktree}; EV=${2:?evidence dir}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "${LAB:?}"
}
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/cursor-usage" "$LAB/pstack/.cursor-plugin"
printf '{"name":"pstack","version":"0.15.21"}\n' > "$LAB/pstack/.cursor-plugin/plugin.json"
touch "$LAB/state/.last-watcher-beat"
P="$LAB/projects/labproj"
git init -q -b main "$P" && git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
printf 'labproj 1\nlabproj 1\n' > "$LAB/config/project-capacity"
TODAY=$(TZ=America/Chicago date +%F)

spawn_case() {  # <label> <bead-id> <spending file content>
  local label=$1 id=$2 content=$3 out="$LAB/$2.out" rc
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLab check of Cursor credit routing for %s.\n\n## Firstmate spec\nDo nothing; this spawn is stopped before launch.\n' "$id" > "$LAB/data/$id/brief.md"
  printf '{"day":"%s","beads":{"%s":2}}\n' "$TODAY" "$id" > "$LAB/state/cursor-dispatch.json"
  printf '%s\n' "$content" > "$LAB/cursor-usage/20261017-0800-spending.txt"
  # Run fm-spawn inside a pane of the lab's own tmux server, so $TMUX names the
  # fm-lab socket and every path resolves inside the lab.
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t primary -n "$id" -c "$WT" \
    "env HOME='$LAB/user-home' FM_HOME='$LAB' FM_CURSOR_USAGE_DIR='$LAB/cursor-usage' FM_PSTACK_DIR='$LAB/pstack' \
      FM_CURSOR_CLI_CONFIG='$LAB/cursor-cli-config.json' FM_CURSOR_MODELS_RULE='$LAB/pstack-models.mdc' \
      '$WT/bin/fm-spawn.sh' '$id' '$P' --mode no-mistakes --yolo off --harness cursor > '$out' 2>&1; echo \$? > '$out.rc'"
  for _ in $(seq 1 300); do [ -s "$out.rc" ] && break; sleep 0.2; done
  rc=$(cat "$out.rc" 2>/dev/null || echo timeout)
  printf '### %s\n' "$label"
  printf '    spending file:\n'; sed 's/^/      /' "$LAB/cursor-usage/20261017-0800-spending.txt"
  printf '    $ fm-spawn.sh %s %s --mode no-mistakes --yolo off --harness cursor   (exit %s)\n' "$id" "projects/labproj" "$rc"
  sed "s|$LAB|<lab>|g; s/^/      /" "$out"
  printf '    state/%s.cursor-fallback: ' "$id"
  if [ -f "$LAB/state/$id.cursor-fallback" ]; then sed "s|$LAB|<lab>|g" "$LAB/state/$id.cursor-fallback"; else echo '(absent)'; fi
  printf '    state/%s.meta: %s\n' "$id" "$([ -e "$LAB/state/$id.meta" ] && echo present || echo absent)"
  printf '    lab tmux windows: %s\n' "$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t primary -F '#W' | tr '\n' ' ')"
  printf '    cursor-dispatch.json: %s\n\n' "$(cat "$LAB/state/cursor-dispatch.json")"
}

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$WT" -e FM_HOME="$LAB" "sleep 600"

{
  spawn_case "pct 100 with enabled on-demand room and prepaid credit: spawn stays on Cursor" lab-room-c1 \
    "$(printf 'cursor_models_pct=100\nother_models_pct=45\non_demand=enabled\nprepaid_balance=445.63\nmonthly_additional_usage_used=138.38\nmonthly_additional_usage_limit=400\ncycle_resets=2026-11-14\nread_at=2026-10-17T03:00-05:00')"
  spawn_case "pct 100 with prepaid credit but on-demand used at the limit: spawn falls back to Codex" lab-noroom-c2 \
    "$(printf 'cursor_models_pct=100\nother_models_pct=45\non_demand=enabled\nprepaid_balance=184.05\nmonthly_additional_usage_used=400.00\nmonthly_additional_usage_limit=400\ncycle_resets=2026-11-14\nread_at=2026-10-17T03:00-05:00')"
  spawn_case "pct 100 with prepaid credit but on-demand disabled: spawn falls back to Codex" lab-off-c3 \
    "$(printf 'cursor_models_pct=100\nother_models_pct=45\non_demand=disabled\nprepaid_balance=84.07\nmonthly_additional_usage_used=10\nmonthly_additional_usage_limit=400\ncycle_resets=2026-11-14\nread_at=2026-10-17T03:00-05:00')"
} | tee "$EV/spawn-lab-transcript.txt"
echo "lab user-home after the runs: $(find "$LAB/user-home" -mindepth 1 -maxdepth 2 | sed "s|$LAB|<lab>|g" | tr '\n' ' ')" | tee -a "$EV/spawn-lab-transcript.txt"
