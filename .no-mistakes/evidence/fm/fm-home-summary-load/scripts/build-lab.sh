#!/usr/bin/env bash
# build-lab.sh <worktree> <lab-home> <tmux-dir> <fakebin>
# Populate a marked, disposable lab FM_HOME with a 64-task in-flight fleet:
# 40 local tmux ships (real windows on a private tmux server), 4 scouts,
# 4 local secondmates, 2 orca tasks, 8 remote-host tasks, 2 legacy tasks
# without spawn_gen, 2 tasks with hostile metadata/status text, 2 tasks whose
# recorded window does not exist. Status logs carry long keyed decision
# histories, stamps, quotes, backslashes, tabs and unicode. ~20 tasks carry
# contribution records (one malformed, one unreadable). An away contract
# stands so merge authority resolves to `away`.
# External services (no-mistakes daemon, forges, herdr, orca, ssh) are stubs
# on a private PATH; tmux is the real binary on the lab's private socket.
set -eu
WT=$1 LAB=$2 TDIR=$3 FAKEBIN=$4
STATE=$LAB/state DATA=$LAB/data
mkdir -p "$FAKEBIN" "$LAB/mates"
HEAD_A=0123456789abcdef0123456789abcdef01234567
NOW=2026-10-17T14:00:00Z

# --- stubs for shared services ---------------------------------------------
# no-mistakes: answer "not initialized" after a deterministic per-worktree
# delay (FM_LAB_NM_DELAY_MS, every 8th worktree 6x slower) to mimic a loaded
# daemon. The producer, crew-state, tmux and git are real.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
d=${FM_LAB_NM_DELAY_MS:-0}
n=$(pwd | cksum | cut -d' ' -f1)
[ $((n % 8)) -ne 0 ] || d=$((d * 6))
[ "$d" -eq 0 ] || sleep "$(printf '%d.%03d' $((d / 1000)) $((d % 1000)))"
printf "error: repo not initialized (run 'no-mistakes init' first)\n"
exit 1
SH
for tool in gh glab tea herdr orca cmux zellij ssh; do
  printf '#!/bin/sh\necho "lab stub: %s unavailable" >&2\nexit 1\n' "$tool" > "$FAKEBIN/$tool"
done
chmod +x "$FAKEBIN"/*

# --- private tmux server ----------------------------------------------------
export TMUX_TMPDIR=$TDIR
unset TMUX
tmux -L fm-lab new-session -d -s fmlab -n base 'sleep 1000000'
SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')
printf '%s\n' "$SOCK" > "$LAB/.lab-tmux-socket"

win() {  # <name> <pane-command>
  tmux -L fm-lab new-window -d -t fmlab: -n "$1" "$2"
}

backlog_row() {  # <id> <kind> <extra>
  printf -- '- [ ] %s - Lab fleet task %s (repo: firstmate) (kind: %s)%s (since 2026-10-10)\n' \
    "$1" "$1" "$2" "${3:-}" >> "$DATA/backlog.md"
}

status_history() {  # <file> <n> <id>
  local f=$1 n=$2 id=$3 j=1
  : > "$f"
  while [ "$j" -le "$n" ]; do
    printf 'needs-decision [key=gate-%s]: choose "option %s" for %s\n' "$((j % 5))" "$j" "$id" >> "$f"
    printf 'resolved [key=gate-%s]: captain chose path \\ %s\n' "$((j % 5))" "$j" >> "$f"
    printf 'working [at=10:%02d]: step %s — progressing ✓\n' "$((j % 60))" "$j" >> "$f"
    j=$((j + 1))
  done
}

contribution() {  # <id> <number>
  mkdir -p "$DATA/$1"
  jq -n --arg task "$1" --arg url "https://github.com/o/r/pull/$2" \
    --arg head "$HEAD_A" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$DATA/$1/contributions.json"
}

printf '## In flight\n' > "$DATA/backlog.md"
i=1
while [ "$i" -le 64 ]; do
  id=$(printf 't%02d' "$i")
  meta=$STATE/$id.meta
  status=$STATE/$id.status
  gen="fm.lab$(printf '%06d' "$i")"
  if [ "$i" -le 40 ] || [ "$i" -ge 61 ]; then
    # Local tmux ship with a real worktree on its own branch.
    proj=$LAB/projects/$id
    mkdir -p "$proj"
    git -C "$proj" init -q -b main
    printf '# %s\n' "$id" > "$proj/README.md"
    git -C "$proj" add README.md
    git -C "$proj" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
    git -C "$proj" checkout -q -b "fm/$id"
    case $((i % 3)) in 0) harness=claude ;; 1) harness=codex ;; *) harness=cursor ;; esac
    case $((i % 2)) in 0) mode=no-mistakes ;; *) mode=direct-PR ;; esac
    {
      printf 'window=fmlab:fm-%s\nworktree=%s\nproject=firstmate\nharness=%s\n' "$id" "$proj" "$harness"
      printf 'kind=ship\nmode=%s\nbranch=fm/%s\n' "$mode" "$id"
      [ "$i" -ge 61 ] || printf 'spawn_gen=%s\n' "$gen"
      [ $((i % 4)) -ne 0 ] || printf 'pr=https://github.com/o/r/pull/%s\npr_head=%s\n' "$i" "$HEAD_A"
    } > "$meta"
    case "$i" in
      7|19) ;;  # recorded window never created: endpoint must read false
      *)
        case $((i % 4)) in
          0) win "fm-$id" "printf '✻ Working… (12s · esc to interrupt)\n'; exec sleep 1000000" ;;
          1) win "fm-$id" "printf 'fixture pane\n> \n'; exec sleep 1000000" ;;
          *) win "fm-$id" 'exec sleep 1000000' ;;
        esac
        ;;
    esac
    status_history "$status" $(( (i % 5) * 30 + 10 )) "$id"
    case $((i % 6)) in
      0) printf 'needs-decision [key=scope]: pick "A" or \\B\\ for %s\n' "$id" >> "$status" ;;
      1) printf 'blocked [key=dependency]: wait for "fixture"\tinput — 依存\n' >> "$status" ;;
      2) printf 'done: shipped %s\n' "$id" >> "$status" ;;
      3) printf 'needs-decision: keyless choice with: colons [at=10:30]\n' >> "$status" ;;
      4) printf 'failed: pipeline broke on "%s"\n' "$id" >> "$status" ;;
      *) printf 'paused: waiting on captain\n' >> "$status" ;;
    esac
    backlog_row "$id" ship
    if [ $((i % 5)) -eq 0 ]; then
      busy_gen=$("$WT/bin/fm-busy-event.sh" arm "$STATE" "$id")
      "$WT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle --gen "$busy_gen" --source claude-hook --event stop
    fi
  elif [ "$i" -le 44 ]; then
    proj=$LAB/projects/$id
    mkdir -p "$proj"
    git -C "$proj" init -q -b main
    printf 'window=fmlab:fm-%s\nworktree=%s\nproject=firstmate\nharness=claude\nkind=scout\nmode=report\nspawn_gen=%s\n' \
      "$id" "$proj" "$gen" > "$meta"
    win "fm-$id" "printf 'fixture pane\n> \n'; exec sleep 1000000"
    status_history "$status" 12 "$id"
    printf 'done: report ready\n' >> "$status"
    if [ "$i" -le 42 ]; then mkdir -p "$DATA/$id"; printf '# Report %s\n' "$id" > "$DATA/$id/report.md"; fi
    backlog_row "$id" scout
  elif [ "$i" -le 48 ]; then
    mhome=$LAB/mates/$id
    [ "$i" -eq 48 ] || mkdir -p "$mhome/state"
    printf 'window=fmlab:fm-%s\nhome=%s\nprojects=%s/projects\nharness=claude\nkind=secondmate\nmode=secondmate\nspawn_gen=%s\n' \
      "$id" "$mhome" "$mhome" "$gen" > "$meta"
    win "fm-$id" "printf 'mate pane\n> \n'; exec sleep 1000000"
    status_history "$status" 6 "$id"
    printf 'needs-decision [key=mate-scope]: secondmate asks "go?"\n' >> "$status"
    backlog_row "$id" secondmate
  elif [ "$i" -le 50 ]; then
    if [ "$i" -eq 49 ]; then
      printf 'backend=orca\nterminal=orca-term-%s\nwindow=fmlab:fm-%s\nharness=claude\nkind=ship\nmode=direct-PR\nspawn_gen=%s\n' "$id" "$id" "$gen" > "$meta"
    else
      printf 'backend=orca\nwindow=orca-window-%s\nharness=claude\nkind=ship\nmode=direct-PR\nspawn_gen=%s\n' "$id" "$gen" > "$meta"
    fi
    status_history "$status" 3 "$id"
    backlog_row "$id" ship
  elif [ "$i" -le 58 ]; then
    printf 'kind=scout\nkind=ship\nharness=codex\nremote_host=example.invalid\nremote_root=/remote home\n' > "$meta"
    case $((i % 2)) in 0) printf 'remote_backend=herdr\nremote_target=remote:%s\n' "$id" >> "$meta" ;; esac
    printf 'project=firstmate\nmode=direct-PR\nspawn_gen=%s\n' "$gen" >> "$meta"
    status_history "$status" 20 "$id"
    printf 'blocked [key=dependency]: wait for "fixture" \\ input\n' >> "$status"
    backlog_row "$id" ship
  else
    # 59-60: hostile metadata text, duplicate keys, a value containing '='.
    proj=$LAB/projects/$id
    mkdir -p "$proj"
    git -C "$proj" init -q -b main
    {
      printf 'window=fmlab:fm-%s\nworktree=%s\nproject=fire"mate\\x\nproject=firstmate "quoted" \\ back=slash\n' "$id" "$proj"
      printf 'harness=claude\nkind=ship\nmode=direct-PR\nbranch=fm/ünï-%s\nyolo=1\nspawn_gen=%s\n' "$id" "$gen"
      printf 'pr=https://github.com/o/r/pull/%s?x=1&y=2\npr_head=\n' "$i"
      printf 'noequalsline\n=emptykey\n'
    } > "$meta"
    win "fm-$id" "printf 'fixture pane\n> \n'; exec sleep 1000000"
    printf 'needs-decision [key=a-b]: tab\there, "q", \\back\\, ünï — 漢字\nblocked: no key here: with colon\n' > "$status"
    backlog_row "$id" ship
  fi
  i=$((i + 1))
done
printf '\n## Queued\n- [ ] q01 - Queued lab task (repo: firstmate) (kind: ship)\n\n## Done\n- [x] d01 - Landed lab task (repo: firstmate) (kind: ship)\n' >> "$DATA/backlog.md"

# Contribution records for 20 tasks, one malformed, one unreadable.
for i in 1 2 3 4 5 6 8 9 10 11 12 13 14 15 16 17 18 20 21 22; do
  contribution "$(printf 't%02d' "$i")" "$i"
done
mkdir -p "$DATA/t23" "$DATA/t24"
printf 'incomplete JSON\n' > "$DATA/t23/contributions.json"
printf 'incomplete JSON\n' > "$DATA/t24/contributions.json"
chmod 000 "$DATA/t24/contributions.json"

# Away contract so contribution merge authority resolves through validate.
FM_HOME=$LAB "$WT/bin/fm-afk-contract.sh" enter --words 'lab away posture' >/dev/null
printf 'built lab: %s tasks, socket %s\n' "$(ls "$STATE"/*.meta | wc -l | tr -d ' ')" "$SOCK"

# Claude-harness tasks report through the real busy-event hook record, as a
# live Claude crew does (idle for most, busy for every 4th).
for meta in "$STATE"/*.meta; do
  id=${meta##*/}; id=${id%.meta}
  grep -qx 'harness=claude' "$meta" || continue
  [ ! -f "$STATE/$id.busy-gen" ] || continue
  busy_gen=$("$WT/bin/fm-busy-event.sh" arm "$STATE" "$id")
  case "$id" in *[048]) st=busy ;; *) st=idle ;; esac
  "$WT/bin/fm-busy-event.sh" apply "$STATE" "$id" "$st" --gen "$busy_gen" --source claude-hook --event stop
done
