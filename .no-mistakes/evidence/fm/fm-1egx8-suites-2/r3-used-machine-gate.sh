#!/opt/homebrew/bin/bash
# Shared machine gate (dale-gl52). Traps this matcher avoids, each measured (2026-10-02 to 2026-10-05):
#  1. a bare `pgrep -fl xcodebuild` also matches every `xcodebuildmcp` MCP server — 32+ on this box,
#     none of them a build. A lane counting those would wait forever.
#  2. piping that to `grep xcodebuild` makes pgrep match the GREP's own command line, so an idle
#     box reads 1 real build.
#  3. gj preps for ~30 s BEFORE xcodebuild appears, so a check that only looks for xcodebuild can
#     green-light a second heavy job on top of one that has already started. Check gj too.
#  4. once launched, a simulator run has no xcodebuild or gj row left (read YES at 4:01:48 PM and
#     4:39:13 PM with an app live). Count its app, which runs from .../Devices/<udid>/data/Containers/
#     Bundle/Application/, and a live `simctl launch|install|boot`. Never launchd_sim: a booted but
#     idle simulator (Dale keeps them open) names Devices/<udid>/data/ too. An app left running in
#     an open simulator counts; the process cannot say whose it is.
#  5. `gj build --help` (any gj row with --help or -h) is a test reading usage, not a job.
#  6. a headless Blender/Cycles bake has no xcodebuild or gj row (read YES at 7:11:26 PM CDT
#     2026-10-02 while be-still's Cycles bake, pid 98482 `Blender --background`, ran; a Clickless
#     release build then started on top of it at 7:11:51). Count Blender run with -b or
#     --background; an interactive Blender (Dale's own window) is not counted.
#  7. be-still's Swift viewpoint renderer (pm-bestill, measured ~7:48 PM CDT 2026-10-02) has no gj
#     row either. Interpreted it runs as swift-frontend with -interpret and an argument ending
#     render-tree-viewpoint-realitykit.swift; compiled, lanes name the executable render-tree-viewpoint.
#     Match the EXECUTABLE (ps comm), never argv text: a shell whose command line carries the pattern
#     is not a render (a lane's waiter matched a zsh that way at 6:50 PM CDT).
#  8. carman-compound's verifier runs headless Blender with --check, seconds each at half a core, in
#     back-to-back mutant series; counted under trap 6 it held SLOT FREE at NO from 6:37 to 8:17 PM CDT
#     2026-10-02 (pm-bestill). A headless Blender whose arguments carry --check is NOT heavy; every other
#     headless Blender (bake, render) still counts. Ruled by pm-dale 8:20 PM CDT on dale-gl52.
#  9. trap 6 matched the Blender path anywhere in a process's COMMAND TEXT, so a lane's own zsh whose
#     command line carried a Blender --background invocation read as a bake: coord bd-2js-cont-bd-2js-g1
#     got SLOT FREE = NO from its own shell 9:12-9:19 PM CDT 2026-10-02 (pm-bestill). Count Blender only
#     when the Blender executable is the process itself (argv0), as trap 7 does for the renderer.
# 10. a lane may run gj from a PRIVATE COPY (<worktree>/build/gj-private/gj, so its upload archives the
#     lane's worktree, not Dale's checkout); `bin/gj` missed it, and the gate read SLOT FREE = YES at
#     9:08:56 AM CDT 2026-10-05 while bd-6do's `gj upload bestill` held gj's compile lock (measured by
#     pm-clickless gen 7's lane; its Release build queued on that lock until 9:10:05). Match gj-private/gj too.
# 11. trap 10 is one more path, and the next copy of gj will run from a path no list names. What
#     serializes gj's compiles is its compile lock (gj-oti): /usr/bin/lockf holds a kernel flock on
#     /tmp/gj-compile.lock for every verb that compiles (build, run, archive, unit, check, resolve, dist,
#     upload), from before its prepare step, and the kernel drops it when the holder exits. So (1d)
#     reads the lock, whatever path gj ran from: F_GETLK reports another process's flock on macOS
#     (F_WRLCK held, F_UNLCK free; measured 9:24 AM CDT 2026-10-05) and never takes it, so no real gj
#     waits on this gate. Not lsof: Darwin leaves its lock field blank for a flock, so it cannot tell
#     held from merely open. A missing file is free (gj keeps it with -k; only a reboot clears /tmp);
#     any other failure to read counts as held. The gj rows in (1b) stay: a `gj run` streaming its
#     app's log has already let the lock go. MACHINE_GATE_LOCK_FILE points the read at a temp lock for
#     proofs; never GJ_COMPILE_LOCK_FILE, which gj's test suites export for their own (.agent-config-ticx3).
# 12. Dale active at the Mac: pm-dale's 4:46 PM CDT 2026-10-05 bar (heavy agent work stops while he is on the Mac until the
#     5-minute load holds under 100) was not in this gate: at 6:26:18 PM CDT it printed SLOT FREE = YES with his HID idle
#     17 s and the 5-minute load 276, and check-carmanco-9re-p13 started two Blender --check mutants. Ruled by pm-dale gen 52
#     6:28 PM CDT on dale-gl52 (first mate note 1791242897-IYrtG6): (4) reads NO when HID idle < 600 s AND the 5-minute
#     load >= 100, for every job that waits here, --check series included. One named P0 for a client date may pass by
#     name: MACHINE_GATE_DALE_EXEMPT=<bead> in that job's own environment (the first mate names it; 10-05: clickless-tv1).
# 13. a read the gate cannot make is not an idle box. Under coord-bd-0w6's Codex sandbox (7:04 AM CDT 2026-10-06;
#     re-run under `codex sandbox` 7:13 AM) pgrep exited 3 ("Cannot get process list"), ps 126 and sysctl 1 ("Operation
#     not permitted"), every count read 0, and the gate printed SLOT FREE = YES. Each read's exit code is now kept: pgrep
#     above 1 (1 is "no match", the normal idle box) or any failed ps, sysctl or ioreg prints UNREADABLE under its line and
#     makes SLOT FREE = NO naming it. Each read is captured whole and then filtered, never checked through a pipe: a
#     healthy `ioreg | awk '... exit'` reads 141 (SIGPIPE) every run. pm-dale gen 54's card, .agent-config-9owor.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-9owor-20261006T121328Z ~/.agent-state/machine-gate.sh
# 14. the presence bar is OFF (2026-10-06). Dale, typed at his desk 3:56:50 PM CT: "don't bar the agents. if it bothers me,
#     I will tell you and we will look for a solution. the only time that we need to stop something is when agents kill
#     the machine with too many blender or simulator sessions running, and even then, the answer is not to stop, but to
#     coordinate and make a line". PM charter 2026-10-06T21:03:37Z; ordered by the first mate gen 69 at 4:10 PM CDT.
#     Row (4) is SHOWN ONLY, like row (2): it no longer makes SLOT FREE = NO, a failed ioreg read no longer does either,
#     and MACHINE_GATE_DALE_EXEMPT has nothing left to exempt. The heavy-job rows (1) to (1d) still decide, so heavy load
#     stays a line, one at a time. Item 12 above is history. Changed by pm-config gen 27.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-presence-20261006T211156Z ~/.agent-state/machine-gate.sh
# 15. GSP's local Next.js builds and authenticated-screens runs are heavy and were in no row: at 9:5x AM CDT 2026-10-07
#     two lanes (gsp-xfcyb, gsp-ckmk3) each ran a Sight `next build` + screens at once beside three headless Blender
#     checks, with the 15-minute load at 356-377 on 16 cores. Dale, 9:45:14 AM CT at his desk (dale-pyrt, P0): "we need
#     that load to be managed better. like 20% less load"; his 10-06 3:56 PM words make the answer a line, not a stop.
#     Row (1e) counts one per run: a node process whose script is tsx running scripts/authenticated-screens*, or Next's
#     own `next build` (node .../next/dist/bin/next build, or the next-build process). Matched on argv0 + script, never
#     on text anywhere in a command line (traps 7 and 9: a codex or zsh whose prompt names the script is not a run).
#     Changed by the first mate gen 77. Undo: cp ~/.agent-state/machine-gate.sh.bak-g77-load-20261007T145133Z ~/.agent-state/machine-gate.sh
# 16. SLOT FREE = YES was read as 'it is my turn', and it never measured that: it says no heavy job is running THIS
#     SECOND. The laptop's turns are a line pm-carman holds by message (~/.agent-state/pm-carman/g21/laptop-line.md), and a
#     queued lane is between steps exactly when this gate reads free. Twice a job started in that gap: a heru lane's headless
#     Blender at 8:45:19 PM CDT 2026-10-06 (the line file's 8:46 PM entry, 'gate gap'), and pm-config gen 42's own gj build at
#     3:32:49 AM CDT 2026-10-08, which stopped coord-bd-cka's live Be Still swap mid-warning (pm-carman gen 33's 3:35 AM note).
#     Row (5) now SAYS so, above the last line, so anything that reads the last line is unaffected. It decides nothing.
#     Ruled fine as written by the first mate gen 84, 3:41 AM CDT 2026-10-08. Changed by pm-config gen 42.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-g42-line-20261008T090114Z ~/.agent-state/machine-gate.sh
#     SUPERSEDED by 21 (10-09): the turn is this gate's run lock, never pm-carman's or any PM's word.
# 17. trap 9 fixed only Blender: row (1b)'s gj, simctl and simulator-app patterns still matched TEXT anywhere in a
#     command line. At 9:05:12 and 9:06:33 AM CDT 2026-10-08 pid 88088 (/bin/zsh -c, a lane's message whose text held
#     'xcrun simctl launch --console-pty') read as a simulator job: (1b) = 1, SLOT FREE = NO with 0 builds and 0 booted
#     simulators, and Dale's Clickless 111 install lost a try (pm-carman gen 35; pm-clickless verified 9:06:16). All
#     three now match only when the process IS the job: gj as argv0 or as the script bash runs (gj is a bash script;
#     real rows read 'bash /Users/dalecarman/bin/gj build ...'), simctl as argv0 or behind xcrun (real argv0:
#     /Library/Developer/PrivateFrameworks/CoreSimulator.framework/.../bin/simctl), the app as argv0. A shell that
#     really runs one has that child's own row. Not seen by (1b): a gj or Xcode path with a space in it (none on this
#     Mac; (1d)'s lock still catches every gj compile). Row (1)'s grep is the same shape and is left alone: no incident,
#     and no real xcodebuild row was at hand to prove an anchor against. Rows and runner (10 heavy, 8 text; the old
#     pattern called 7 of the 8 heavy): ~/.agent-state/pm-config/gen45/gate/. Changed by pm-config gen 45.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-g45-argv0-20261008T141313Z ~/.agent-state/machine-gate.sh
# 18. trap 17's rows were right, but (1b) read ONE ps snapshot. A simulator test relaunches its app every ~20-30 s
#     (simctl launch --console-pty --terminate-running-process), and between the old app's exit and the next simctl row
#     (1b) read 0 for about a second: pm-carman gen 36 measured it at 11:22:43 AM CDT 2026-10-08 in Be Still build 23's
#     test launch. (1b) now reads ps twice, MACHINE_GATE_RESAMPLE_SECS apart (default 3 s), and counts a job seen in
#     either sample, deduped by pid (a relaunched app counts twice, two pids; only > 0 matters). A failed second read is
#     UNREADABLE, like the first. Every gate read takes about 3 s longer. Not covered: pm-carman's ~11:21:4x read of 0
#     while its own ps right after showed both rows (not reproduced; may be a matcher miss, not a gap).
#     Offline proof (stubbed ps, nothing planted live): ~/.agent-state/pm-config/gen46/gate/prove-trap18.{sh,out}.
#     Changed by pm-config gen 46. Undo: cp ~/.agent-state/machine-gate.sh.bak-g46-resample-20261008T171002Z ~/.agent-state/machine-gate.sh
# 19. row (1) matched TEXT, as trap 17 warned: at 10:34-10:38 AM CDT 2026-10-09 a /bin/zsh -c waiter (pm-bestill's pgrep loop,
#     pid 76137) whose argv held "xcodebuild .*(archive|exportArchive)" read as "REAL xcodebuild builds = 1"; no xcodebuild ran,
#     and Dale's build-27 archive waited until pm-carman ruled it false at 10:38 (pm-carman gen 41, 10:38:09 AM). Row (1) now
#     counts a process only when its executable IS xcodebuild (pgrep -x, the process name), so a shell that names it is not a
#     build; the bare text count stays on the line for the xcodebuildmcp note. .agent-config-qunzj, pm-config gen 49.
# 20. Dale's hold was not in this gate: under his 8:19:25 AM CDT 2026-10-09 hold ("don't let anything heavy run until I tell
#     you that we are clear") it printed SLOT FREE = YES, and pm-day's new generation ran typecheck, unit, the DB suite and
#     mutants 9:22:45-9:31:11 and 9:36:14-9:41:01 AM (pm-pipe at 8:25 and 8:47 AM). Ruled by the first mate gen 94 at 9:52 AM:
#     the gate reads ONE hold file that pm-carman sets and clears. Format agreed with pm-carman gen 41 at 9:54:37 AM:
#     ~/.agent-state/pm-carman/hold, whose presence IS the hold; lines `words: <Dale's words>`, `at: <UTC, e.g.
#     2026-10-09T13:19:25Z>`, and any number of `allow: <herdr agent name>`. Allow lines are PER RUN: pm-carman adds one
#     when it gives a word under the hold and removes it at that run's DONE; none is standing permission. While the file
#     exists, row (6) prints the hold, and the last line is the normal verdict only for pm-carman (the line holder reads the
#     machine) and the runs the file names; every other asker, an asker outside herdr (no HERDR_PANE_ID) or a malformed or
#     unreadable file reads SLOT FREE = NO [HOLD]. The asker is the herdr name of HERDR_PANE_ID. With no file, the output is
#     unchanged. MACHINE_GATE_HOLD_FILE points the read at a temp file for proofs. .agent-config-qunzj, pm-config gen 49.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-g49-hold-20261009T170850Z ~/.agent-state/machine-gate.sh
#     SUPERSEDED in part by 21 (10-09): the hold file is ~/.agent-state/machine-line/hold, set by the first mate; nobody
#     passes it by name.
# 21. THE LINE IS THE PIPELINE'S (dale-vk3m, .agent-config-5fzor, pm-config gen 52, 10-09). Dale, 5:35:38 PM CT in pm-dale's tab:
#     "just don't let pm-carman become the authority. the authority for machine use needs to be the pipeline. pm-config,
#     firstmate. pm-config is responsible for the machine. firstmate is responsible for getting the work done. the project
#     pm's feed the work". Since 10-06 a lane's turn was pm-carman's word, by message (trap 16); 169 briefs in 24 h said so.
#     Now this gate IS the permission, made atomic: `machine-gate.sh run [--cap <minutes>] -- <command>` takes ONE kernel lock
#     (/usr/bin/lockf -t 0 on ~/.agent-state/machine-line/slot.lock, the same lockf gj's compile lock uses), names the holder
#     in ~/.agent-state/machine-line/holder, re-reads this gate INSIDE the lock, and runs the command only on YES. Otherwise it
#     exits 75 and says who holds the turn; the lane waits and runs the same command again itself. The kernel drops the lock
#     when the holder's process ends, so a dead lane cannot hold the turn. A HUNG one can: row (7) prints who holds the turn,
#     since when, and its cap (default 60 min), and past the cap `machine-gate.sh clear` (the first mate, or pm-config) sends
#     TERM, then KILL 10 s later, to that run's own process tree (its wrapper and every descendant, walked from ps; never a
#     process group, which may hold the caller's own session), never before the cap. The job stays in the caller's process
#     group, so a lane that kills its own command frees the turn with it. ORDER among waiting lanes is the
#     first mate's: the hold file (trap 20) moved to ~/.agent-state/machine-line/hold, and nobody passes it by name any more.
#     Every busy, gate-no, start, end and clear is a row in ~/.agent-state/machine-line/log.tsv: the wait for a turn is read
#     there. Seams for proofs: MACHINE_LINE_DIR, MACHINE_GATE_READ (a command whose last line stands in for this gate's).
#     TRAP 23 (10-09, first mate gen 99, 6:44 PM): a hold set WHILE a run held the turn stalled that run at its next
#     inside read, and it kept the lock, so the allowed lane could not start either (bd-6u38's sitting, 6:38:56-6:43:15 PM,
#     about 4.5 min of Dale's wait). A read from inside the holding run (ancestry to the holder pid) now reads row (7) as
#     yours and passes a hold; a hold governs who starts next.
#     TRAP 24 (10-09, first mate gen 99, 6:52 PM): trap 23 also passed the hold for run's own ADMISSION read (it runs
#     inside the lock), so coord-bd-hrh-p4 STARTED under Dale's M5-install hold at 23:50:01Z. The admission read now
#     honours the hold; only reads made after admission pass it. The proof now runs a real admission under a hold.
#     TRAP 25 (10-09, first mate gen 99, 7:33 PM): first come was decided by retry SPEED. coord-bd-2zl-ui, retrying
#     once a minute as the brief said, got no turn 6:33-7:33 PM, and coord-bd-cz5z-c1 lost 64 tries 6:20-7:25 PM, while
#     lanes retrying every 3-5 s took every free turn. Now the longest LIVE waiter goes first (from log.tsv); a waiter
#     keeps its place while it retries within MACHINE_LINE_LIVE_SECS (180 s); a lane named by the hold skips the line.
#     Undo: cp ~/.agent-state/machine-gate.sh.bak-5fzor-20261009T225734Z ~/.agent-state/machine-gate.sh.
# 26. Lanes wrapped their gated run in bash -c "several commands": 10 of the 83 two-minute holds Claude Code's built-in removal
#     prompt caused in the 8 days to 2026-10-09 were that shape (.agent-config-am65r, the builder's count by source). Its check holds
#     any -c script whose command starts with a variable, then refuses it. Row (5) now says: a script file, never bash -c.
#     Text only; nothing about the turn changed. pm-config gen 53, 2026-10-09.
# 27. A hold counts only once it exists, so nothing could reserve a time ahead. On 2026-10-13 Dale's Clickless
#     install lost its turn: the hold lapsed at 11:00 CT, and a 150-minute run took the line at 11:24 while the
#     install was due about 11:45 (ep-pfizer-clickless). Dale: a live session does not go through firstmate; its
#     own agent reserves the window. `reserve --start <UTC or epoch> --minutes <n> --who <name>` writes
#     $line_dir/reserve. Until that start, a run whose cap would reach it is refused (logged reserve-no, which the
#     waiter line does not count) and a run that ends before it still starts. From the start, for that many
#     minutes, that owner goes ahead of every waiting background run and every other run waits. A hold still
#     governs starts; this does not clear one. MACHINE_GATE_NOW is an epoch for proofs.
#     .agent-config-a3ov3.5.
# 28. reserve and admission did not share an order (review of the a3ov3.5 change, 2026-10-13): a run
#     read an empty reservation, reserve then wrote the window and reported success, and the run still
#     started and held the turn across that window. The owner's run exited 75. Both now take
#     $line_dir/reserve.lock around the decision. Admission re-reads the reservation under that lock
#     and either refuses or logs start before it lets go. Reserve writes under that lock, and it
#     refuses without writing when a started run is still alive and its cap reaches the window. One of
#     them loses. The slot lock is still the turn, held for the whole run; this lock is only the
#     decision, so a run that ends before the window can be underway while a later window is reserved.
#     MACHINE_GATE_BEFORE_ADMIT is a command run after the gate reads YES and before that lock. Proofs
#     pause there to interleave reserve. Unset on a real run.
line_dir="${MACHINE_LINE_DIR:-$HOME/.agent-state/machine-line}"
slot_lock="$line_dir/slot.lock"; holder_file="$line_dir/holder"; line_log="$line_dir/log.tsv"
line_name() {
  local n=''
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    n=$("$HOME/.local/bin/herdr" agent list 2>/dev/null | "$(command -v jq || echo /usr/bin/jq)" -r --arg p "$HERDR_PANE_ID" '.result.agents[] | select(.pane_id==$p) | .name // empty' 2>/dev/null | head -1)
  fi
  printf '%s' "${MACHINE_LINE_NAME:-${n:-pid-$PPID}}"
}
line_logrow() { mkdir -p "$line_dir" 2>/dev/null; printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$line_log" 2>/dev/null; }
slot_read() {
  /usr/bin/perl -e 'use Fcntl qw(:DEFAULT :seek); open(my $h, "<", $ARGV[0]) or do { print $!{ENOENT} ? "free" : "unreadable ($!)"; exit 0 }; my $l = pack("qqiss", 0, 0, 0, F_WRLCK, SEEK_SET); fcntl($h, F_GETLK, $l) or do { print "unreadable (F_GETLK: $!)"; exit 0 }; print((unpack("qqiss", $l))[3] == F_UNLCK ? "free" : "held")' "$slot_lock"
}
holder_desc() {
  local n='' pg='' s='' c='' cmd='' age over=''
  IFS=$'\t' read -r n pg s c cmd < "$holder_file" 2>/dev/null
  [ -n "$n" ] && [ -n "$s" ] && [ -n "$c" ] || { printf 'nobody named (the holder file is empty)'; return; }
  age=$(( ( $(date +%s) - s ) / 60 ))
  [ "$age" -ge "$c" ] && over="; OVER ITS CAP by $(( age - c )) min: the first mate may end it with machine-gate.sh clear"
  printf '%s since %s (%s min of its %s min cap%s): %s' "$n" "$(TZ=America/Chicago date -r "$s" '+%-I:%M:%S %p %Z')" "$age" "$c" "$over" "$cmd"
}
gate_now() {
  case "${MACHINE_GATE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$MACHINE_GATE_NOW" ;;
  esac
}
reservation_load() {
  res_start=''; res_minutes=''; res_who=''
  local f="$line_dir/reserve" s='' m='' w=''
  [ -f "$f" ] && [ -r "$f" ] || return 0
  s=$(sed -n 's/^start: *//p' "$f" | head -1)
  m=$(sed -n 's/^minutes: *//p' "$f" | head -1)
  w=$(sed -n 's/^who: *//p' "$f" | head -1)
  case "$s" in ''|*[!0-9]*) return 0 ;; esac
  case "$m" in ''|*[!0-9]*|0) return 0 ;; esac
  case "$w" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  res_start=$s
  res_minutes=$m
  res_who=$w
}
# 0 when a started run is still alive and its cap reaches the epoch, so reserve must lose.
# Busy rows after that start stay in the log, so this read is the whole file.
# The waiter scan below still keeps the last 3000 rows.
turn_reaches() {
  local epoch="$1" name='' pid='' start='' cap='' cmd=''
  [ -r "$holder_file" ] || return 1
  IFS=$'\t' read -r name pid start cap cmd < "$holder_file" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  case "$cap" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ $(( 10#$start + 10#$cap * 60 )) -ge "$epoch" ] || return 1
  MACHINE_LINE_LOG="$line_log" TURN_NAME="$name" TURN_PID="$pid" /usr/bin/perl -e '
    open(my $f, "<", $ENV{MACHINE_LINE_LOG}) or exit 1;
    my @l = <$f>;
    my $open = 0;
    for (@l) {
      chomp;
      my ($ts, $kind, $who, $det) = split /\t/, $_, 4;
      next unless defined $who && $who eq $ENV{TURN_NAME};
      if ($kind eq "end") { $open = 0; }
      elsif ($kind eq "start" && defined $det && $det =~ /\bpid \Q$ENV{TURN_PID}\E\b/) { $open = 1; }
    }
    exit($open ? 0 : 1);
  '
}
if [ "${1:-}" = run ]; then
  shift; cap=60
  while [ $# -gt 0 ]; do
    case "$1" in --cap) [ $# -ge 2 ] || { echo "machine-gate run: --cap needs whole minutes" >&2; exit 2; }; cap="$2"; shift 2 ;; --) shift; break ;; *) break ;; esac
  done
  case "$cap" in ''|*[!0-9]*) echo "machine-gate run: --cap takes whole minutes, e.g. --cap 30" >&2; exit 2 ;; esac
  [ $# -gt 0 ] || { echo "usage: machine-gate.sh run [--cap <minutes>] -- <command> [args...]" >&2; exit 2; }
  mkdir -p "$line_dir" || exit 2
  me=$(line_name)
  cmdfile=$(mktemp "$line_dir/cmd.XXXXXX") || exit 2
  printf '%s\0' "$@" > "$cmdfile"
  MACHINE_LINE_ME="$me" MACHINE_LINE_CAP="$cap" /usr/bin/lockf -k -s -t 0 "$slot_lock" /bin/bash "$0" __holding "$cmdfile"
  rc=$?
  if [ -e "$cmdfile.started" ]; then rm -f "$cmdfile" "$cmdfile.started"; exit "$rc"; fi
  if [ -e "$cmdfile.gate" ]; then rm -f "$cmdfile" "$cmdfile.gate"; exit 75; fi
  rm -f "$cmdfile"
  if [ "$rc" -eq 75 ]; then
    echo "machine-gate run: NOT STARTED: the turn is held by $(holder_desc). Wait, then run the same command again yourself; never ask a PM for a turn."
    line_logrow busy "$me" "held by $(cut -f1 "$holder_file" 2>/dev/null)"
    exit 75
  fi
  echo "machine-gate run: NOT STARTED: lockf exited $rc" >&2; exit "$rc"
fi
if [ "${1:-}" = __holding ]; then
  cmdfile="$2"; me="${MACHINE_LINE_ME:-unknown}"; cap="${MACHINE_LINE_CAP:-60}"
  cmd=(); while IFS= read -r -d '' a; do cmd+=("$a"); done < "$cmdfile"
  printf '%s\t%s\t%s\t%s\t%s\n' "$me" "$$" "$(date +%s)" "$cap" "$(printf '%s ' "${cmd[@]}" | cut -c1-160)" > "$holder_file"
  if [ -n "${MACHINE_GATE_READ:-}" ]; then out=$(MACHINE_LINE_INSIDE=1 MACHINE_LINE_ADMISSION=1 /bin/bash -c "$MACHINE_GATE_READ" 2>&1); else out=$(MACHINE_LINE_INSIDE=1 MACHINE_LINE_ADMISSION=1 /bin/bash "$0" 2>&1); fi
  last=$(printf '%s\n' "$out" | tail -n 1)
  case "$last" in
    "SLOT FREE = YES"*) ;;
    *) : > "$holder_file"; printf '%s\n' "$out"; echo "machine-gate run: NOT STARTED: the gate reads '$last'. Wait, then run the same command again yourself."; : > "$cmdfile.gate"; line_logrow gate-no "$me" "$last"; exit 75 ;;
  esac
  # trap 28: pause before the reservation lock, so a reserve can land, then bind under the lock.
  if [ -n "${MACHINE_GATE_BEFORE_ADMIT:-}" ]; then
    if ! /bin/bash -c "$MACHINE_GATE_BEFORE_ADMIT"; then
      : > "$holder_file"
      echo "machine-gate run: NOT STARTED: the run stopped before it took the turn. Wait, then run the same command again yourself."
      : > "$cmdfile.gate"
      line_logrow gate-no "$me" "stopped before the turn"
      exit 75
    fi
  fi
  exec 9>>"$line_dir/reserve.lock" || exit 2
  if ! /usr/bin/lockf -s 9; then
    : > "$holder_file"
    echo "machine-gate run: NOT STARTED: the reservation could not be bound. Wait, then run the same command again yourself."
    : > "$cmdfile.gate"
    line_logrow gate-no "$me" "reservation lock"
    exit 75
  fi
  # trap 27: the live session's window. A cap that would reach the start is refused and is not a waiter.
  # At the start, the owner skips the line; everyone else waits out the window. The read is under the lock.
  skip_line=''
  reservation_load
  if [ -n "$res_start" ]; then
    now=$(( 10#$(gate_now) ))
    res_end=$(( 10#$res_start + 10#$res_minutes * 60 ))
    if [ "$now" -lt "$res_end" ]; then
      if [ "$now" -lt $(( 10#$res_start )) ]; then
        if [ $(( now + 10#$cap * 60 )) -ge $(( 10#$res_start )) ]; then
          when=$(date -u -r "$res_start" '+%Y-%m-%dT%H:%M:%SZ')
          : > "$holder_file"
          echo "machine-gate run: NOT STARTED: a ${cap} min cap would reach ${res_who}'s reservation at ${when}. A run that ends before then can start. Wait, then run the same command again yourself."
          : > "$cmdfile.gate"
          line_logrow reserve-no "$me" "cap ${cap}m reaches ${res_who} at ${when}"
          exit 75
        fi
      elif [ "$me" = "$res_who" ]; then
        skip_line=1
      else
        until=$(date -u -r "$res_end" '+%Y-%m-%dT%H:%M:%SZ')
        : > "$holder_file"
        echo "machine-gate run: NOT STARTED: ${res_who} reserved the turn until ${until}. Run the same command again within ${MACHINE_LINE_LIVE_SECS:-180} s to keep your place."
        : > "$cmdfile.gate"
        line_logrow queued "$me" "behind ${res_who} (reserved until ${until})"
        exit 75
      fi
    fi
  fi
  # trap 25: the longest live waiter goes first, never the fastest retrier. A lane named by the hold skips this
  # (the first mate's order). Waiters come from log.tsv's busy, queued and non-HOLD gate-no rows since each lane's
  # last start or end; a waiter that has not retried within MACHINE_LINE_LIVE_SECS (180) has left the line.
  hf="${MACHINE_GATE_HOLD_FILE:-$HOME/.agent-state/machine-line/hold}"
  if [ -z "$skip_line" ] && ! { [ -e "$hf" ] && grep -q -E "^allow: *${me}( |$)" "$hf" 2>/dev/null; }; then
    ahead=$(MACHINE_LINE_LOG="$line_log" ME="$me" LIVE="${MACHINE_LINE_LIVE_SECS:-180}" /usr/bin/perl -MTime::Local -e '
      open(my $f, "<", $ENV{MACHINE_LINE_LOG}) or exit 0; my @l = <$f>; @l = @l[-3000..-1] if @l > 3000;
      my (%first, %last);
      for (@l) { chomp; my ($ts, $kind, $who, $det) = split /\t/, $_, 4; next unless defined $who;
        my ($Y,$M,$D,$h,$m,$s) = $ts =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z/ or next; my $t = timegm($s,$m,$h,$D,$M-1,$Y);
        if ($kind eq "start" || $kind eq "end") { delete $first{$who}; delete $last{$who}; next }
        if ($kind eq "busy" || $kind eq "queued" || ($kind eq "gate-no" && ($det // "") !~ /HOLD:/)) { $first{$who} //= $t; $last{$who} = $t } }
      my $now = time; my $mine = $first{$ENV{ME}} // $now; my ($best, $bt);
      for my $w (keys %first) { next if $w eq $ENV{ME}; next if $now - $last{$w} > $ENV{LIVE};
        if ($first{$w} < $mine && (!defined $bt || $first{$w} < $bt)) { $best = $w; $bt = $first{$w} } }
      if (defined $best) { my @g = gmtime($bt); printf "%s (waiting since %02d:%02d:%02dZ)", $best, $g[2], $g[1], $g[0] }')
    if [ -n "$ahead" ]; then
      : > "$holder_file"; : > "$cmdfile.gate"; line_logrow queued "$me" "behind $ahead"
      echo "machine-gate run: NOT STARTED: $ahead is ahead of you in the line. Run the same command again within ${MACHINE_LINE_LIVE_SECS:-180} s to keep your place."
      exit 75
    fi
  fi
  : > "$cmdfile.started"
  line_logrow start "$me" "pid $$ cap ${cap}m"
  exec 9>&-
  "${cmd[@]}"; rc=$?
  if exec 9>>"$line_dir/reserve.lock"; then
    /usr/bin/lockf -s 9
  fi
  line_logrow end "$me" "rc $rc"
  : > "$holder_file"
  exec 9>&-
  exit "$rc"
fi
if [ "${1:-}" = clear ]; then
  st=$(slot_read)
  [ "$st" = held ] || { echo "machine-gate clear: the turn is $st; nothing to clear"; exit 0; }
  h_name=''; h_pg=''; h_start=''; h_cap=''; h_cmd=''
  IFS=$'\t' read -r h_name h_pg h_start h_cap h_cmd < "$holder_file" 2>/dev/null
  [ -n "$h_name" ] && [ -n "$h_start" ] && [ -n "$h_cap" ] || { echo "machine-gate clear: REFUSED: the turn is held but $holder_file names nobody; read ps before ending anything"; exit 1; }
  age=$(( $(date +%s) - h_start ))
  [ "$age" -ge $(( h_cap * 60 )) ] || { echo "machine-gate clear: REFUSED: $h_name holds the turn $(( age / 60 )) min of its $h_cap min cap"; exit 1; }
  case "$h_pg" in ''|*[!0-9]*|0|1) echo "machine-gate clear: REFUSED: holder pid '$h_pg' is not one to end"; exit 1 ;; esac
  case "$(ps -o args= -p "$h_pg" 2>/dev/null)" in *machine-gate*__holding*) ;; *) echo "machine-gate clear: REFUSED: pid $h_pg is not a machine-gate run (read ps)"; exit 1 ;; esac
  tree() { local all kids k; all="$1"; kids="$1"; while [ -n "$kids" ]; do k=''; for q in $kids; do k="$k $(ps -Ao pid=,ppid= | awk -v q="$q" '$2==q {print $1}')"; done; kids=$(echo $k); [ -n "$kids" ] && all="$all $kids"; done; echo $all; }
  who=$(line_name); victims=$(tree "$h_pg")
  alive() { local v; for v in $victims; do kill -0 "$v" 2>/dev/null && printf '%s ' "$v"; done; }
  kill -TERM $victims 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(alive)" ] && [ "$(slot_read)" != held ] && break; sleep 1; done
  left=$(alive); if [ -n "$left" ]; then kill -KILL $left 2>/dev/null; sleep 1; fi
  left=$(alive); [ -z "$left" ] || echo "machine-gate clear: STILL ALIVE after KILL: $left (read ps)"
  st=$(slot_read); [ -z "$left" ] || st="$st, but pids $left survive"
  [ "$st" = free ] && : > "$holder_file"
  line_logrow clear "$who" "ended $h_name pid $h_pg tree at $(( age / 60 ))m of ${h_cap}m; turn $st"
  echo "machine-gate clear: ended $h_name's run (pid $h_pg and its tree, $(( age / 60 )) min against its $h_cap min cap); the turn is now $st"
  [ "$st" = free ]; exit $?
fi
if [ "${1:-}" = reserve ]; then
  shift
  rstart=''; rmin=''; rwho=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --start) [ $# -ge 2 ] || { echo "machine-gate reserve: --start needs a time" >&2; exit 2; }; rstart="$2"; shift 2 ;;
      --minutes) [ $# -ge 2 ] || { echo "machine-gate reserve: --minutes needs whole minutes" >&2; exit 2; }; rmin="$2"; shift 2 ;;
      --who) [ $# -ge 2 ] || { echo "machine-gate reserve: --who needs a name" >&2; exit 2; }; rwho="$2"; shift 2 ;;
      *) echo "usage: machine-gate.sh reserve --start <UTC or epoch> --minutes <minutes> --who <name>" >&2; exit 2 ;;
    esac
  done
  [ -n "$rstart" ] && [ -n "$rmin" ] && [ -n "$rwho" ] || { echo "usage: machine-gate.sh reserve --start <UTC or epoch> --minutes <minutes> --who <name>" >&2; exit 2; }
  case "$rmin" in ''|*[!0-9]*) echo "machine-gate reserve: --minutes takes whole minutes, at least 1" >&2; exit 2 ;; esac
  rmin=$(( 10#$rmin ))
  [ "$rmin" -ge 1 ] || { echo "machine-gate reserve: --minutes takes whole minutes, at least 1" >&2; exit 2; }
  case "$rwho" in *[!A-Za-z0-9._-]*) echo "machine-gate reserve: --who takes a name of letters, digits, dots, underscores and hyphens" >&2; exit 2 ;; esac
  [ "${#rwho}" -le 80 ] || { echo "machine-gate reserve: --who takes a name of at most 80 characters" >&2; exit 2; }
  case "$rstart" in
    *[!0-9]*)
      epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$rstart" '+%s' 2>/dev/null) || { echo "machine-gate reserve: --start takes a UTC time like 2026-10-13T18:00:00Z, or seconds since the epoch" >&2; exit 2; }
      ;;
    *) epoch=$rstart ;;
  esac
  case "$epoch" in ''|*[!0-9]*) echo "machine-gate reserve: --start takes a UTC time like 2026-10-13T18:00:00Z, or seconds since the epoch" >&2; exit 2 ;; esac
  epoch=$(( 10#$epoch ))
  now=$(( 10#$(gate_now) ))
  end=$(( epoch + rmin * 60 ))
  [ "$end" -gt "$epoch" ] || { echo "machine-gate reserve: --minutes is too large" >&2; exit 2; }
  [ "$end" -gt "$now" ] || { echo "machine-gate reserve: that window has already ended" >&2; exit 2; }
  mkdir -p "$line_dir" || exit 2
  exec 9>>"$line_dir/reserve.lock" || exit 2
  if ! /usr/bin/lockf -s 9; then
    echo "machine-gate reserve: NOT RESERVED: the reservation could not be bound" >&2
    exit 75
  fi
  if turn_reaches "$epoch"; then
    hname=''; hcap=''
    IFS=$'\t' read -r hname _hpid _hstart hcap _hcmd < "$holder_file" || true
    when=$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ')
    exec 9>&-
    echo "machine-gate reserve: NOT RESERVED: ${hname} holds the turn with a ${hcap} min cap that reaches this window at ${when}. The reservation was not written."
    exit 75
  fi
  tmp=$(mktemp "$line_dir/reserve.XXXXXX") || { exec 9>&-; exit 2; }
  printf 'start: %s\nminutes: %s\nwho: %s\n' "$epoch" "$rmin" "$rwho" > "$tmp" || { rm -f "$tmp"; exec 9>&-; exit 2; }
  mv -f "$tmp" "$line_dir/reserve" || { rm -f "$tmp"; exec 9>&-; exit 2; }
  exec 9>&-
  echo "machine-gate reserve: ${rwho} from $(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ') for ${rmin} min"
  exit 0
fi
echo "=== MACHINE GATE $(TZ=America/Chicago date '+%Y-%m-%d %-I:%M:%S %p %Z') ==="
unreadable=''; unread() { unreadable="$unreadable $1 exit $2;"; echo "     UNREADABLE: $1 exited $2, so the line above is blind, not idle"; }
snap=$(pgrep -fl xcodebuild); pgrep_rc=$?
total=$(printf '%s\n' "$snap" | grep -c .)
mcp=$(printf '%s\n' "$snap" | grep -c 'xcodebuildmcp')
xpids=$(pgrep -x xcodebuild); xpgrep_rc=$?   # trap 19: the executable, never text in a command line
realrows=$(for p in $xpids; do ps -o pid=,args= -p "$p" 2>/dev/null; done)
real=$(printf '%s\n' "$realrows" | grep -c .)
echo "(1) REAL xcodebuild builds = $real    [bare pgrep matched $total; $mcp are xcodebuildmcp MCP servers, not builds]"
[ "$real" -gt 0 ] && printf '%s\n' "$realrows" | cut -c1-110
[ "$pgrep_rc" -gt 1 ] && unread 'pgrep -fl xcodebuild' "$pgrep_rc"
[ "$xpgrep_rc" -gt 1 ] && unread 'pgrep -x xcodebuild' "$xpgrep_rc"
psrows=$(ps -Ao pid,command); ps_rc=$?
sleep "${MACHINE_GATE_RESAMPLE_SECS:-3}"   # trap 18: a second sample, so a relaunch gap is not read as idle
psrows2=$(ps -Ao pid,command); ps2_rc=$?
gjrows=$(printf '%s\n%s\n' "$psrows" "$psrows2" | grep -E '^ *[0-9]+ +(([^ ]*/)?bash +)?[^ ]*(bin|gj-private)/gj (build|run|upload|check|unit)|^ *[0-9]+ +([^ ]*xcrun +)?[^ ]*simctl (launch|install|boot) |^ *[0-9]+ +[^ ]*Devices/[^/ ]+/data/Containers/Bundle/Application/|^ *[0-9]+ +[^ ]*Blender\.app/Contents/MacOS/Blender .*(-b|--background)( |$)' | grep -vE '(bin|gj-private)/gj .* (--help|-h)( |$)|Blender\.app/Contents/MacOS/Blender .*--check( |$)' | grep -v grep | awk '!seen[$1]++')
gj=$(printf '%s\n' "$gjrows" | grep -c .)
echo "(1b) gj + simulator + headless Blender heavy jobs in flight = $gj    [gj preps ~30 s before xcodebuild is visible; a sim run then shows only its app; gj --help/-h is no job; Blender counts only with -b/--background]"
[ "$gj" -gt 0 ] && printf '%s\n' "$gjrows" | cut -c1-110
[ "$ps_rc" -ne 0 ] && unread 'ps -Ao pid,command' "$ps_rc"
[ "$ps2_rc" -ne 0 ] && unread 'ps -Ao pid,command (second sample)' "$ps2_rc"
comms=$(ps -Ao pid=,comm=); comm_rc=$?
vprows=$( printf '%s\n' "$comms" | awk '$NF ~ /\/render-tree-viewpoint$/ {print}'
  for p in $(printf '%s\n' "$comms" | awk '$NF ~ /\/swift-frontend$/ {print $1}'); do
    # an if, not a case: /bin/bash 3.2 misparses a case pattern's ")" inside $( ) (measured 7:54 PM CDT)
    # this per-pid ps fails for a pid that has exited since the list: a finished process, not an unreadable list
    if ps -o args= -p "$p" 2>/dev/null | grep -q -- ' -interpret .*render-tree-viewpoint-realitykit\.swift'; then
      echo "$p swift-frontend -interpret render-tree-viewpoint-realitykit.swift"
    fi
  done )
vp=$(printf '%s\n' "$vprows" | grep -c .)
echo "(1c) be-still viewpoint renders in flight = $vp    [executable render-tree-viewpoint, or swift-frontend -interpret ...render-tree-viewpoint-realitykit.swift]"
[ "$vp" -gt 0 ] && printf '%s\n' "$vprows" | cut -c1-110
[ "$comm_rc" -ne 0 ] && unread 'ps -Ao pid=,comm=' "$comm_rc"
webps=$(ps -Axo pid=,ucomm=,args=); webps_rc=$?
webrows=$(printf '%s\n' "$webps" | awk '{a=$0; sub(/^ *[0-9]+ +[^ ]+ +/,"",a)} ($2=="next-build") || ($2=="node" && (a ~ /^node [^ ]*\/tsx\/dist\/cli\.mjs scripts\/authenticated-screens/ || a ~ /^node [^ ]*\/next\/dist\/bin\/next build( |$)/)) {print}')
web=$(printf '%s\n' "$webrows" | grep -c .)
echo "(1e) GSP local next build / authenticated-screens runs in flight = $web    [one per run; argv0 node + its script, or next-build; trap 15]"
[ "$web" -gt 0 ] && printf '%s\n' "$webrows" | cut -c1-110
[ "$webps_rc" -ne 0 ] && unread 'ps -Axo pid=,ucomm=,args=' "$webps_rc"
# trap 22 (with 21): Unity was in no row. pm-carman's line counted it by hand ("The gate does not count Unity builds
#     (pm-heru): check pgrep -x Unity", g41 10-09; coord-bd-hrh-p3 started only "when pgrep -x Unity is empty"). Row (1f)
#     carries that rule as it was kept: a process whose executable IS Unity counts; Unity Hub and its helpers do not.
upids=$(pgrep -x Unity); upgrep_rc=$?   # the whole process name; "Unity Hub" is another name (ps columns split it)
unityrows=$(for p in $upids; do ps -o pid=,args= -p "$p" 2>/dev/null; done)
unity=$(printf '%s\n' "$unityrows" | grep -c .)
[ "$upgrep_rc" -gt 1 ] && unread 'pgrep -x Unity' "$upgrep_rc"
echo "(1f) Unity editor or build processes = $unity    [executable Unity, as pm-carman's line counted it (trap 22); Unity Hub is not counted]"
[ "$unity" -gt 0 ] && printf '%s\n' "$unityrows" | cut -c1-110
lockfile=${MACHINE_GATE_LOCK_FILE:-/tmp/gj-compile.lock}
lockstate=$(/usr/bin/perl -e 'use Fcntl qw(:DEFAULT :seek); open(my $h, "<", $ARGV[0]) or do { print $!{ENOENT} ? "free" : "unreadable ($!)"; exit 0 }; my $l = pack("qqiss", 0, 0, 0, F_WRLCK, SEEK_SET); fcntl($h, F_GETLK, $l) or do { print "unreadable (F_GETLK: $!)"; exit 0 }; print((unpack("qqiss", $l))[3] == F_UNLCK ? "free" : "held")' "$lockfile" 2>&1)
lock=1; [ "$lockstate" = free ] && lock=0
echo "(1d) gj compile lock held = $lock    [$lockfile: $lockstate; read with F_GETLK, never taken; catches gj run from any path; unreadable counts as held]"
if [ "$lock" -eq 1 ] && read -r _n _sh lpid lstart lapp lverb lagent 2>/dev/null < "$lockfile" && [ -n "$lverb" ]; then
  echo "     holder: $lapp $lverb (gj pid $lpid, since $(TZ=America/Chicago date -r "$lstart" '+%-I:%M:%S %p' 2>/dev/null), agent ${lagent:-unknown})"
fi
loadavg=$(sysctl -n vm.loadavg); sysctl_rc=$?
echo "(2) load 1-min = $(printf '%s\n' "$loadavg" | awk '{print $2}')    (shown only)"
[ "$sysctl_rc" -ne 0 ] && unread 'sysctl -n vm.loadavg' "$sysctl_rc"
echo "(3) memory free = $(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2}')    (must be > 20)"
hid=$(ioreg -c IOHIDSystem 2>/dev/null); ioreg_rc=$?
idle=$(printf '%s\n' "$hid" | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
load5=$(printf '%s\n' "$loadavg" | awk '{printf "%d", $3}')
dale=0; if [ -n "$idle" ] && [ "$idle" -lt 600 ] && [ "$load5" -ge 100 ]; then dale=1; fi
echo "(4) Dale active under load = $dale    (shown only since 2026-10-06, his words 3:56:50 PM CT, charter 2026-10-06T21:03:37Z; HID idle ${idle:-unread}s, 5-min load $load5)"
[ "$ioreg_rc" -ne 0 ] && echo "     (4) unread: ioreg exited $ioreg_rc; the line is shown only, so it holds nothing"
echo "(5) the turn is this gate's (trap 21): start a heavy job ONLY as  bash ~/.agent-state/machine-gate.sh run [--cap <min>] -- <command>  (exit 75 = not your turn: wait, then run it again yourself). Heavy means what rows (1) to (1f) count: xcodebuild, gj and simulator runs (gj unit tests included), headless Blender bakes, viewpoint renders, GSP next builds and authenticated-screens runs, Unity; a Node or Python unit suite, a capture, a model-call loop or a script that waits on the network is not heavy, so run it ungated and leave the turn free. More than one command? Write them to a script FILE and gate the file (run -- /bin/zsh job.zsh); do NOT wrap them in bash -c: Claude Code holds a -c script two minutes and then refuses it when a command in it starts with a variable (trap 26). The order among waiting lanes is the first mate's (hold file), except a live session's own reservation: machine-gate.sh reserve --start <UTC or epoch> --minutes <n> --who <name>. Until that start, a run whose cap would reach it is refused and a run that ends before it still starts. At the start, that owner goes ahead of every waiting background run. No hold file is required. Reserve and admission take one lock around that decision. A run already started whose cap reaches the window keeps the turn, and that reserve is refused without writing. A reserve that lands first refuses a later run whose cap would reach it. Never ask a PM for a turn."
if [ -n "$unreadable" ]; then verdict="NO    [UNREADABLE:${unreadable%;}]"; else
verdict="$([ "$real" -eq 0 ] && [ "$gj" -eq 0 ] && [ "$vp" -eq 0 ] && [ "$web" -eq 0 ] && [ "$unity" -eq 0 ] && [ "$lock" -eq 0 ] && echo YES || echo NO)"; fi
line_inside=''
if [ -n "${MACHINE_LINE_INSIDE:-}" ]; then line_inside=1
elif [ "$(slot_read)" = held ]; then
  # trap 23 (with 21): a read from INSIDE the run that holds the turn is the holder's own read. Decided by
  # ancestry to the recorded holder pid, never by a flag a caller could set (first mate gen 99, 6:44 PM 10-09).
  lh=$(cut -f2 "$holder_file" 2>/dev/null); lp=$$
  case "$lh" in ''|*[!0-9]*) ;; *) while [ -n "$lp" ] && [ "$lp" -gt 1 ]; do [ "$lp" = "$lh" ] && { line_inside=1; break; }; lp=$(ps -o ppid= -p "$lp" 2>/dev/null | tr -d ' '); done ;; esac
fi
if [ -n "$line_inside" ]; then
  echo "(7) the turn: yours (this read runs inside the machine-gate.sh run that holds it)"
else
  sst=$(slot_read)
  if [ "$sst" = free ]; then echo "(7) the turn: free    [take it only with machine-gate.sh run; one holder at a time; trap 21]"
  else
    echo "(7) the turn: held by $(holder_desc)    [slot lock $sst]"
    case "$verdict" in YES*) verdict="NO    [TURN: held by $(cut -f1 "$holder_file" 2>/dev/null)]" ;; esac
  fi
fi
reservation_load
if [ -n "$res_start" ]; then
  now=$(( 10#$(gate_now) ))
  if [ "$now" -lt $(( 10#$res_start + 10#$res_minutes * 60 )) ]; then
    echo "(8) reservation: $res_who from $(date -u -r "$res_start" '+%Y-%m-%dT%H:%M:%SZ') for $res_minutes min    [machine-gate.sh reserve; until the start a run whose cap would reach it is refused; at the start that owner goes ahead of waiting runs]"
  fi
fi
# trap 20, moved by 21: the hold file, the first mate's order. Absent: the last line is exactly the verdict above, as before.
hold_file="${MACHINE_GATE_HOLD_FILE:-$HOME/.agent-state/machine-line/hold}"
if [ ! -e "$hold_file" ] && [ ! -L "$hold_file" ]; then echo "SLOT FREE = $verdict"; else
  jqbin=$(command -v jq || echo /usr/bin/jq)
  asker=''
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    hl=$("$HOME/.local/bin/herdr" agent list 2>/dev/null)
    asker=$(printf '%s' "$hl" | "$jqbin" -r --arg p "$HERDR_PANE_ID" '.result.agents[] | select(.pane_id==$p) | .name // empty' 2>/dev/null | head -1)
  fi
  hbad=''; hwords=''; hat=''; hallow=''
  if [ ! -r "$hold_file" ]; then hbad='unreadable'; else
    htext=$(cat "$hold_file" 2>/dev/null) || hbad='unreadable'
    hwords=$(printf '%s\n' "$htext" | sed -n 's/^words: *//p' | head -1)
    hat=$(printf '%s\n' "$htext" | sed -n 's/^at: *//p' | head -1)
    hallow=$(printf '%s\n' "$htext" | sed -n 's/^allow: *//p' | awk '{print $1}' | tr '\n' ' ')
    hepoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$hat" '+%s' 2>/dev/null)
    [ -n "$hbad" ] || { [ -n "$hwords" ] && [ -n "$hepoch" ]; } || hbad='malformed (needs words: and at: in UTC)'
  fi
  if [ -n "$hbad" ]; then
    echo "(6) HOLD: the hold file $hold_file is $hbad, so every asker reads NO"
    echo "SLOT FREE = NO    [HOLD: hold file $hbad]"
  else
    echo "(6) HOLD: \"$hwords\" since $(TZ=America/Chicago date -r "$hepoch" '+%-I:%M:%S %p %Z'); allowed: ${hallow:-none}; asked by: ${asker:-unknown (no herdr pane)}"
    pass=''
    for a in $hallow; do [ -n "$asker" ] && [ "$a" = "$asker" ] && pass=yes; done
    # trap 23: a hold stops new starts, never the run already admitted. The ADMISSION read is a start, so it honours
    # the hold (trap 24); MACHINE_LINE_ADMISSION can only make a read stricter, so setting it bypasses nothing.
    [ -n "$line_inside" ] && [ -z "${MACHINE_LINE_ADMISSION:-}" ] && pass=yes
    if [ -n "$pass" ]; then echo "SLOT FREE = $verdict"; else echo "SLOT FREE = NO    [HOLD: ${asker:-an asker outside herdr} is not named in the hold file]"; fi
  fi
fi
