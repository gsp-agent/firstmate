# lab-lib.sh - drive the real bin/fm-captain-hold.sh and bin/fm-watch.sh from
# the gate worktree against a disposable, marked lab home.
#
# Real pieces: the worktree's fm-captain-hold.sh and fm-watch.sh, the installed
# hold-domain router (~/.agent-config/configs/claude/hooks/hold-domain.py),
# and the machine's tasks-axi over the lab's own markdown backlog.
# Stand-ins: herdr (records each owner prompt to $LAB/owner.log instead of
# sending; Firstmate instruction 008 forbids touching any real Herdr session),
# and tmux/gh/gh-axi/treehouse/no-mistakes (exit 0, so the watcher never reaches
# the operator's tmux server or GitHub).
set -u
WT=${WT:-/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M53WD160N0NF286RBDJ0Y2WA}
ROUTER="$HOME/.agent-config/configs/claude/hooks/hold-domain.py"
REAL_TASKS_AXI=$(command -v tasks-axi)
export REAL_TASKS_AXI
UPDATE='GSP PRs 4281, 4291, 4309, and 4319 are waiting on a go for update-branch.'
CAPACITY='ep-groove-sight-platform already approved raising GSP capacity from 3 places to 5. Should I apply that?'

lab_new() {  # prints a fresh marked lab home
  local lab
  lab=$(mktemp -d "/tmp/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  mkdir -p "$lab/fakebin"
  local tool
  for tool in tmux gh gh-axi treehouse no-mistakes; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/fakebin/$tool"
    chmod +x "$lab/fakebin/$tool"
  done
  cat > "$lab/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Recording stand-in for herdr: answers the desk lookup, records prompts.
if [ "${1:-} ${2:-}" = 'agent list' ]; then
  printf '%s\n' '{"result":{"agents":[{"name":"pm-dale-desk","pane_id":"human-desk-pane"}]}}'
  exit 0
fi
[ ! -f "$HOLD_DOMAIN_TEST_LOG.fail" ] || { echo 'transport down' >&2; exit 1; }
printf '%s\n' "$*" >> "$HOLD_DOMAIN_TEST_LOG"
printf 'prompt accepted\n'
SH
  chmod +x "$lab/fakebin/herdr"
  printf '%s\n' "$lab"
}

lab_env() {  # <lab> <utc-now-or-empty> <cmd...>
  local lab=$1 now=$2
  shift 2
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$lab/fakebin:$PATH" FM_HOME="$lab" FM_BACKEND=tmux \
    FM_HOLD_DOMAIN_ROUTER="$ROUTER" HOLD_DOMAIN_HERDR="$lab/fakebin/herdr" \
    HOLD_DOMAIN_TEST_LOG="$lab/owner.log" TZ="${LAB_TZ:-UTC}" \
    ${now:+FM_CAPTAIN_HOLD_NOW="$now"} ${LAB_ALLOWANCE:+FM_BACKLOG_ROW_TIMEOUT_SECS=90} \
    ${LAB_ALLOWANCE:+FM_HOLD_ROUTE_TIMEOUT_SECS=300} ${LAB_ALLOWANCE:+FM_CHECK_TIMEOUT=900} "$@"
}
# LAB_ALLOWANCE=1 widens the existing backlog-read (10s), routing-row (30s) and
# watcher-check (90s) bounds for correctness scenarios on an overloaded host.
# Scenario 3 measures the production bounds and never sets it.

hold_cli() {  # <lab> <utc-now> <fm-captain-hold args...>
  local lab=$1 now=$2
  shift 2
  lab_env "$lab" "$now" "$WT/bin/fm-captain-hold.sh" "$@"
}

watch_arm() {  # <lab> <utc-now> : arm the real watcher once; prints its wake reason
  local lab=$1 now=$2
  lab_env "$lab" "$now" perl -e 'alarm shift; exec @ARGV' "${LAB_WATCH_TIMEOUT:-$([ -n "${LAB_ALLOWANCE:-}" ] && echo 1200 || echo 150)}" \
    env FM_CHECK_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_LIVENESS_SECS=999999 bash "$WT/bin/fm-watch.sh"
}

# The primary's protocol after a watcher wake: present the queued wakes with
# bin/fm-wake-drain.sh, then acknowledge them through the sequence it names.
wake_drain_ack() {  # <lab> <utc-now>
  local lab=$1 now=$2 err seq gen
  err=$(lab_env "$lab" "$now" bash "$WT/bin/fm-wake-drain.sh" 2>&1 >>"$lab/drained.out")
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p')
  gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  lab_env "$lab" "$now" bash "$WT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}

# One real watcher cycle whose periodic checks run, stopped by a status wake.
# Like the primary, re-arm after a "check: rearm-resurface" announcement.
watch_once() {  # <lab> <utc-now>
  local lab=$1 now=$2 out tries=0
  rm -f "$lab/state/.last-check"
  printf 'done: lab watcher stop %s\n' "$now" >> "$lab/state/lab-stop.status"
  while :; do
    out=$(watch_arm "$lab" "$now" 2>&1)
    printf '%s\n' "$out"
    wake_drain_ack "$lab" "$now"
    tries=$((tries + 1))
    case "$out" in
      *'check: rearm-resurface'*) [ "$tries" -lt 3 ] || return 1 ;;
      *) return 0 ;;
    esac
  done
}

tasks() {  # <lab> <tasks-axi args...>
  local lab=$1
  shift
  (cd "$lab" && "$REAL_TASKS_AXI" "$@")
}

supervision_needed() {  # <lab> : prints yes/no from the real supervision library
  ( . "$WT/bin/fm-supervision-lib.sh"; if fm_supervision_needed "$1/state"; then echo yes; else echo no; fi )
}

prompts() {  # <lab>
  if [ -f "$1/owner.log" ]; then wc -l < "$1/owner.log" | tr -d ' '; else echo 0; fi
}

check() {  # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s (= %s)\n' "$1" "$3"
  else
    printf 'FAIL  %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    LAB_FAILS=$((${LAB_FAILS:-0} + 1))
  fi
}

field() {  # <lab> <id> <field>
  tasks "$1" show "$2" --full 2>/dev/null | sed -n "s/^  $3: //p" | head -1
}

body_has() {  # <lab> <id> <text> : yes/no
  if tasks "$1" show "$2" --full 2>/dev/null | grep -Fq -- "$3"; then echo yes; else echo no; fi
}
