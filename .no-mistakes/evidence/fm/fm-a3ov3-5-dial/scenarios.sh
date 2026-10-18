#!/usr/bin/env bash
# Drive project-capacity headroom admission through the real bin/fm-spawn.sh
# in the disposable lab. Usage: scenarios.sh <lab-root> <scenario>...
set -u
ROOT=$1
shift
NONCE=${NONCE:-x}
. "$(dirname "$0")/lab-lib.sh"
READ=$ROOT/readings

# The reading program: its behaviour follows $READ/mode; every run is logged.
install_reading() {
  cat > "$READ/reading" <<SH
#!/usr/bin/env bash
printf '%s pid=%s args=%s\n' "\$(date +%s)" "\$\$" "\$*" >> "$READ/runs.log"
case "\$(cat "$READ/mode" 2>/dev/null)" in
  room) echo "cpu_idle_pct=61 load1=7.2 disk_free_gb=533"; exit 0 ;;
  none) echo "cpu_idle_pct=12 load1=91.0 disk_free_gb=533"; exit 1 ;;
  silent) exit 0 ;;
  slow) sleep 3; echo "cpu_idle_pct=55 load1=9.1 disk_free_gb=533"; exit 0 ;;
  hang) sleep 90; echo late; exit 0 ;;
esac
exit 1
SH
  chmod +x "$READ/reading"
}
mode() { printf '%s\n' "$1" > "$READ/mode"; }
runs() { if [ -f "$READ/runs.log" ]; then wc -l < "$READ/runs.log" | tr -d ' '; else echo 0; fi; }
headroom_on() { printf '%s\n' "$READ/reading --lab $NONCE" > "$LAB/config/project-capacity-headroom"; }
alpha_id() { lock_identity alpha; }
beta_id() { lock_identity beta; }
age() {  # <project>: move that project's extra-start epoch 421 s into the past
  local f="$LAB/state/project-capacity-overshare/$(lock_identity "$1")"
  [ -f "$f" ] && printf '%s\n' $(( $(date +%s) - 421 )) > "$f"
  echo "(aged $1 record to now-421: $(cat "$f" 2>/dev/null))"
}
try_spawn() {  # <id> <project>: spawn and print exit + the lines that matter
  local out rc
  out=$(spawn "$1" "$2" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(spawned|deferred|error|headroom|warning|LAB)' | sed 's/^/  | /'
  echo "  exit=$rc"
  return 0
}
after() {  # <id>: what the spawn left behind
  printf '  meta=%s row=%s window=%s\n' \
    "$([ -f "$LAB/state/$1.meta" ] && echo present || echo absent)" \
    "$(row_state "$1")" \
    "$(lab_tmux list-windows -t firstmate -F '#{window_name}' | grep -qx "fm-$1" && echo present || echo absent)"
}
state() { show "records"; records; show "windows"; windows; }

s_off() {
  echo "=== S1 off switch: no headroom file, alpha 1 held by a1 ==="
  rm -f "$LAB/config/project-capacity-headroom"
  make_task "a2-$NONCE" alpha
  show "spawn a2 alpha"; try_spawn "a2-$NONCE" alpha; after "a2-$NONCE"
  echo "  reading runs=$(runs)"
  echo "=== S2 off switch: headroom file with only whitespace ==="
  printf '   \n\t\n' > "$LAB/config/project-capacity-headroom"
  show "spawn a2 alpha"; try_spawn "a2-$NONCE" alpha; after "a2-$NONCE"
  echo "  reading runs=$(runs)"; state
}

s_noroom() {
  echo "=== S3 reading reports no room (exit 1) ==="
  headroom_on; mode none
  show "spawn a2 alpha"; try_spawn "a2-$NONCE" alpha; after "a2-$NONCE"
  echo "  reading runs=$(runs)"
  echo "=== S3b reading exits 0 but prints nothing ==="
  mode silent
  show "spawn a2 alpha"; try_spawn "a2-$NONCE" alpha; after "a2-$NONCE"
  echo "  reading runs=$(runs)"; state
}

s_admit() {
  echo "=== S4 reading reports room: one extra start past alpha's share ==="
  headroom_on; mode room
  show "spawn a2 alpha"; try_spawn "a2-$NONCE" alpha; after "a2-$NONCE"
  echo "  reading runs=$(runs)  alpha identity=$(alpha_id)"; state
}

s_spent() {
  echo "=== S5 at most one extra start per project per window ==="
  make_task "a3-$NONCE" alpha
  local before; before=$(runs)
  show "spawn a3 alpha (reading still reports room)"; try_spawn "a3-$NONCE" alpha; after "a3-$NONCE"
  echo "  reading runs before=$before after=$(runs)"; state
}

s_perproject() {
  echo "=== S6 shares start without a reading; another project has its own window ==="
  make_task "b1-$NONCE" beta; make_task "b2-$NONCE" beta
  local before; before=$(runs)
  mode none
  show "spawn b1 beta (beta 1, 0 holders; reading set to no room)"; try_spawn "b1-$NONCE" beta; after "b1-$NONCE"
  echo "  reading runs before=$before after=$(runs)"
  mode room
  show "spawn b2 beta (beta at share; reading reports room; alpha's window spent)"; try_spawn "b2-$NONCE" beta; after "b2-$NONCE"
  echo "  reading runs=$(runs) beta identity=$(beta_id)"; state
}

s_reopen() {
  echo "=== S7 window passes; when headroom goes only shares start; when it returns one more extra start ==="
  age alpha
  local rec="$LAB/state/project-capacity-overshare/$(alpha_id)" before
  before=$(cat "$rec")
  mode none
  show "spawn a3 alpha (window passed, reading no room)"; try_spawn "a3-$NONCE" alpha; after "a3-$NONCE"
  echo "  record before=$before after=$(cat "$rec")  (unchanged: the window was not consumed)"
  mode room
  show "spawn a3 alpha (window passed, reading room)"; try_spawn "a3-$NONCE" alpha; after "a3-$NONCE"
  echo "  record now=$(cat "$rec") (now=$(date +%s))"; state
}

s_zero() {
  echo "=== S9 declared count 0 is not raised by a room reading ==="
  printf '%s\n' 'alpha 1' 'beta 1' 'gamma 0' > "$LAB/config/project-capacity"
  mkdir -p "$ROOT/seed-gamma"
  git init -q -b main "$ROOT/seed-gamma"; printf '# gamma\n' > "$ROOT/seed-gamma/README.md"
  git -C "$ROOT/seed-gamma" add -A; git -C "$ROOT/seed-gamma" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
  git clone -q --bare "$ROOT/seed-gamma" "$ROOT/gamma.origin.git"
  git clone -q "$ROOT/gamma.origin.git" "$LAB/projects/gamma"
  printf -- '- gamma [local-only +yolo] - lab gamma\n' >> "$LAB/data/projects.md"
  make_task "g1-$NONCE" gamma
  mode room; local before; before=$(runs)
  show "spawn g1 gamma (gamma 0, reading room)"; try_spawn "g1-$NONCE" gamma; after "g1-$NONCE"
  echo "  reading runs before=$before after=$(runs)"
  printf '%s\n' 'alpha 1' 'beta 1' > "$LAB/config/project-capacity"
}

s_failpre() {
  echo "=== S10 an extra start that fails before its worker launches leaves the window open ==="
  age alpha
  make_task "a4-$NONCE" alpha keep-placeholder
  mode room
  show "spawn a4 alpha (brief still has {TASK}; window open; reading room)"; try_spawn "a4-$NONCE" alpha; after "a4-$NONCE"
  echo "  alpha record after failure: $(cat "$LAB/state/project-capacity-overshare/$(alpha_id)" 2>/dev/null || echo '(none)')"
  python3 - "$LAB/data/a4-$NONCE/brief.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", "Hold a place on this project for capacity lab task a4.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Stay idle; this worker only holds a capacity place.", 1)
open(p, "w").write(t)
PY
  show "spawn a4 alpha again (brief fixed)"; try_spawn "a4-$NONCE" alpha; after "a4-$NONCE"; state
}

s_failpost() {
  echo "=== S11 an extra start whose launch was sent keeps its record when the backlog commit fails ==="
  age alpha
  make_task "a5-$NONCE" alpha; make_task "a6-$NONCE" alpha
  mode room
  touch "$ROOT/fail-start"
  show "spawn a5 alpha (window open, reading room, tasks-axi start fails)"; try_spawn "a5-$NONCE" alpha; after "a5-$NONCE"
  rm -f "$ROOT/fail-start"
  local rec="$LAB/state/project-capacity-overshare/$(alpha_id)"
  echo "  alpha record: $(cat "$rec") (now=$(date +%s))"
  show "orphaned a5 window (the error says to close it by hand)"; windows | grep "fm-a5-$NONCE" || echo "  (no a5 window)"
  local before; before=$(runs)
  show "spawn a6 alpha in the same window"; try_spawn "a6-$NONCE" alpha; after "a6-$NONCE"
  echo "  reading runs before=$before after=$(runs)"
  lab_tmux kill-window -t "firstmate:fm-a5-$NONCE" 2>/dev/null && echo "  (closed orphaned a5 window by hand)"
  state
}

s_hang() {
  echo "=== S12 a reading still running after 30 s is no room ==="
  age alpha
  local rec="$LAB/state/project-capacity-overshare/$(alpha_id)" before t0
  before=$(cat "$rec")
  mode hang; t0=$(date +%s)
  show "spawn a6 alpha (reading hangs)"; try_spawn "a6-$NONCE" alpha; after "a6-$NONCE"
  echo "  elapsed=$(( $(date +%s) - t0 ))s record before=$before after=$(cat "$rec")"
}

s_race() {
  echo "=== S13 two simultaneous spawns of one project cannot both take the extra start ==="
  age alpha
  make_task "a7-$NONCE" alpha; make_task "a8-$NONCE" alpha
  mode slow
  local o7 o8
  o7=$ROOT/race-a7.out; o8=$ROOT/race-a8.out
  ( spawn "a7-$NONCE" alpha > "$o7" 2>&1; echo "exit=$?" >> "$o7" ) &
  sleep 0.5
  ( spawn "a8-$NONCE" alpha > "$o8" 2>&1; echo "exit=$?" >> "$o8" ) &
  wait
  show "a7"; grep -E '^(spawned|deferred|error|headroom|exit)' "$o7" | sed 's/^/  | /'; after "a7-$NONCE"
  show "a8"; grep -E '^(spawned|deferred|error|headroom|exit)' "$o8" | sed 's/^/  | /'; after "a8-$NONCE"
  state
}

s_real() {
  echo "=== S14 a reading of this real machine decides the extra start ==="
  cat > "$READ/machine-reading" <<'SH'
#!/usr/bin/env bash
# CPU idle from two top samples, 1-minute load, free GB on /System/Volumes/Data.
idle=$(top -l 2 -n 0 -s 1 | awk '/CPU usage/ {v=$7} END {sub("%","",v); print v}')
load1=$(sysctl -n vm.loadavg | awk '{print $2}')
disk=$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')
echo "cpu_idle_pct=$idle load1=$load1 disk_free_gb=$disk"
awk -v i="$idle" -v l="$load1" -v d="$disk" 'BEGIN { exit !(i >= 25 && l < 80 && d >= 50) }'
SH
  chmod +x "$READ/machine-reading"
  printf '%s\n' "$READ/machine-reading" > "$LAB/config/project-capacity-headroom"
  age beta
  make_task "b3-$NONCE" beta
  show "the machine right now"; "$READ/machine-reading"; echo "  reading exit=$?"
  show "spawn b3 beta (beta at share, window open, real machine reading)"; try_spawn "b3-$NONCE" beta; after "b3-$NONCE"
  state
}

s_still_running() {
  echo "=== S8 running work is never stopped ==="
  windows
  for m in "$LAB"/state/*.meta; do
    printf '  %s holds pr=%s\n' "$(basename "$m" .meta)" "$(sed -n 's/^pr=//p' "$m")"
  done
}

install_reading
for s in "$@"; do "s_$s"; echo; done
