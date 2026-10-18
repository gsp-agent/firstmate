#!/usr/bin/env bash
# Cross-home scenarios: a local secondmate home spawning alpha under the lab
# root home's capacity declaration. Usage: mate-scenarios.sh <lab-root> <s>...
set -u
ROOT=$1
shift
NONCE=${NONCE:-x}
. "$(dirname "$0")/lab-lib.sh"
MATE=$ROOT/mate
READ=$ROOT/readings
mode() { printf '%s\n' "$1" > "$READ/mode"; }
runs() { if [ -f "$READ/runs.log" ]; then wc -l < "$READ/runs.log" | tr -d ' '; else echo 0; fi; }
REC() { printf '%s\n' "$LAB/state/project-capacity-overshare/$(lock_identity alpha)"; }
age() { printf '%s\n' $(( $(date +%s) - 421 )) > "$(REC)"; echo "(aged alpha record to now-421: $(cat "$(REC)"))"; }

# The same helpers as lab-lib.sh, parameterised by home.
home_run() { local h=$1; shift; (cd "$h" && env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
  PATH="$ROOT/shim:$PATH" SHELL=/bin/bash TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" \
  TMUX_TMPDIR="$TMUXD" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux FM_HOME="$h" "$@"); }
home_task() {  # <home> <id>
  home_run "$1" "$WT/bin/fm-brief.sh" "$2" alpha --mode local-only >/dev/null
  python3 - "$1/data/$2/brief.md" "$2" <<'PY'
import sys
p, tid = sys.argv[1], sys.argv[2]; t = open(p).read()
t = t.replace("{TASK}", f"Hold a place on alpha for capacity lab task {tid}.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Stay idle; this worker only holds a capacity place.", 1)
open(p, "w").write(t)
PY
  home_run "$1" "$WT/bin/fm-tasks-axi.sh" add "$2" "capacity lab $2" --kind ship --repo alpha >/dev/null
}
home_spawn() {  # <home> <id>
  local rc=0 wt
  home_run "$1" "$WT/bin/fm-spawn.sh" "$2" "$1/projects/alpha" --mode local-only --yolo on --harness "sleep 3600" || rc=$?
  wt=$(sed -n 's/^worktree=//p' "$1/state/$2.meta" 2>/dev/null)
  case "$wt" in '' | "$ROOT/treehouse/"*) ;; *) echo "LAB GUARD: $wt outside lab pool" >&2; exit 99 ;; esac
  return "$rc"
}
try() {  # <home> <id>
  local out rc
  out=$(home_spawn "$1" "$2" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(spawned|deferred|error|headroom|warning|LAB)' | sed 's/^/  | /'
  echo "  exit=$rc meta=$([ -f "$1/state/$2.meta" ] && echo present || echo absent)"
}

s_mate_reads_root() {
  echo "=== S15 a secondmate home reads the root home's headroom file, not its own ==="
  home_task "$MATE" "m1-$NONCE"
  age
  mode room
  printf '%s\n' "$READ/reading --mate-copy" > "$MATE/config/project-capacity-headroom"
  mv "$LAB/config/project-capacity-headroom" "$ROOT/root-headroom.saved"
  local before; before=$(runs)
  show "mate spawn m1 alpha (root home has no headroom file; mate has its own copy)"; try "$MATE" "m1-$NONCE"
  echo "  reading runs before=$before after=$(runs)"
  rm -f "$MATE/config/project-capacity-headroom"
  printf '%s\n' "$READ/reading --root-copy" > "$LAB/config/project-capacity-headroom"
  show "mate spawn m1 alpha (root home's headroom file reports room)"; try "$MATE" "m1-$NONCE"
  echo "  last reading args: $(tail -1 "$READ/runs.log" | sed 's/.*args=//')"
  echo "  record in root home state: $(REC) epoch=$(cat "$(REC)") (now=$(date +%s))"
  echo "  mate's own state has no overshare dir: $([ -d "$MATE/state/project-capacity-overshare" ] && echo present || echo absent)"
  home_task "$LAB" "a9-$NONCE"
  show "root spawn a9 alpha right after (same origin, same window)"; try "$LAB" "a9-$NONCE"
}

s_cross_race() {
  echo "=== S16 a root-home spawn and a secondmate spawn of alpha race for one extra start ==="
  home_task "$MATE" "m2-$NONCE"
  age
  mode slow
  local o1=$ROOT/xrace-root.out o2=$ROOT/xrace-mate.out
  ( try "$LAB" "a9-$NONCE" > "$o1" 2>&1 ) &
  sleep 1
  ( try "$MATE" "m2-$NONCE" > "$o2" 2>&1 ) &
  wait
  show "root a9"; cat "$o1"
  show "mate m2"; cat "$o2"
  echo "  record epoch=$(cat "$(REC)") (now=$(date +%s))"
}

s_status() {
  echo "=== final: every worker still running, no record lost ==="
  windows
  records
}

for s in "$@"; do "s_$s"; echo; done
