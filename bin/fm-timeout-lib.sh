#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound and the caller's stdin.
#       Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks), and a command killed by
#       signal n, which reports 128+n on every mechanism - so a SIGKILLed child
#       is 137 and a SIGTERMed one 143, never the 0 a caller would read as
#       success. A signal-death status the wrapper records while the runner
#       already reports the bound is the bound's own TERM, not the command's
#       exit, and is reported as 124 too. Only 137 raised by GNU/BSD timeout's
#       own KILL escalation, with no status recorded by the bounded command,
#       also collapses into 124: there it means the bound fired, not that the
#       command chose to die.
#
#   fm_exec_timed <seconds> <grace-seconds> <command> [args...]
#       Replaces the calling shell with the bounded command, so it must be the
#       last command of a subshell: the bound kills the command, not the
#       caller. The command runs in its own process group; TERM goes to that
#       group at the bound, and KILL once <grace-seconds> more have passed,
#       for a command that ignores TERM or is mid-way through work it will not
#       abandon. A TERM, INT, or HUP delivered to the bounding process is
#       forwarded to the group and starts the same grace. The perl watchdog
#       also starts that escalation when its owner dies before it could be
#       signalled. The owner is captured before
#       the watchdog starts: FM_EXEC_TIMED_OWNER_PID when the caller names it,
#       else the calling script ($$) when fm_exec_timed runs in a subshell,
#       else the shell's parent. The escalation starts once that owner is gone
#       or the watchdog's parent changes, so an owner that dies while the
#       watchdog is still starting is detected too. The watchdog stays in the
#       caller's process group so that group's signals reach it, so a KILL to
#       that whole group kills the watchdog too; a sentinel it starts in a
#       group of its own, before the command, then runs the same escalation
#       (TERM, then KILL after the grace) in its place. The timeout/gtimeout
#       fallback does neither: it bounds the command only by its deadline and
#       grace, so owner death alone does not stop the command.
#       Exit status is the command's own, except 124 (the bound was hit) or
#       137 (GNU timeout's status when its KILL had to fire); fm_timed_out
#       accepts both. The perl watchdog also reports 130 once an INT has
#       reached it, whatever the command then did: a caller started in the
#       background by a non-interactive shell inherits INT ignored, so this
#       status is the only way it learns of the interrupt. The seconds and
#       grace values must be positive integers written without a leading
#       zero (125 otherwise). The perl watchdog is
#       preferred: once termination has begun it also KILLs whatever the group
#       left behind, so a descendant that outlives the command and holds its
#       output cannot keep a capturing caller waiting, and GNU timeout, the
#       fallback, cannot be followed by that reap from a replaced shell. A
#       descendant that moves into a process group of its own is outside both
#       signals and the reap (the Claude and Pi CLIs do this for every tool
#       command they run), so it ends only through the command's own TERM
#       handling; that is what the grace is for, and a command KILLed after
#       the grace can leave such a descendant running. With
#       no perl, timeout, or gtimeout on the host it refuses with 127 rather
#       than run unbounded: there is no bash fallback, because a monitor-mode
#       watchdog cannot replace the caller.
#
#   fm_timed_out <status>
#       0 iff <status> is how fm_run_timed or fm_exec_timed reports the bound.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four fm_run_timed mechanisms terminate the bounded command's process
# group, including descendants that remain in it; a descendant that creates
# another process group is outside this cleanup. HUP, INT, or TERM delivered
# to the waiting caller also stops that group and reaps the owned runner before
# the signal is redelivered under the caller's restored traps. GNU/BSD
# `timeout` does this by default because it does not run the command in the
# foreground process group; the perl fallback does it explicitly with setpgrp
# plus a negative pid, and the bash fallback uses monitor mode to give the
# bounded child its own process group before signaling its negative pid.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_wait_timed() {
  local runner_pid=$1 runner_rc=0 group
  shift
  if [ -z "$fm_timed_signal" ]; then
    wait "$runner_pid" || runner_rc=$?
  fi
  if [ -n "$fm_timed_signal" ]; then
    trap '' HUP INT TERM
    for group in "$@"; do
      kill -TERM -- "-$group" 2>/dev/null || true
    done
    kill -TERM "$runner_pid" 2>/dev/null || true
    if [ "$#" -gt 0 ]; then
      sleep 0.2
      for group in "$@"; do
        kill -KILL -- "-$group" 2>/dev/null || true
      done
    fi
    wait "$runner_pid" 2>/dev/null || true
    for group in "$@"; do
      [ "$group" = "$runner_pid" ] || wait "$group" 2>/dev/null || true
    done
    return "$fm_timed_signal"
  fi
  return "$runner_rc"
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) <&0 &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if fm_wait_timed "$child_pid" "$child_pid" "$watchdog_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # The explicit <&0 keeps the caller's stdin: an asynchronous command without
  # a redirection gets /dev/null instead, which would starve a command fed by
  # a heredoc or pipe (the perl arm already inherits stdin).
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" <&0 &
  runner_pid=$!
  if fm_wait_timed "$runner_pid" "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$command_rc" -le 255 ]; then
        case "$runner_rc" in
          124) [ "$command_rc" -lt 128 ] && return "$command_rc" ;;
          *) return "$command_rc" ;;
        esac
      fi
      ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1 mechanism fm_timed_signal="" fm_timed_traps fm_timed_rc=0 runner_pid
  shift
  mechanism=$(fm_timeout_mechanism)
  fm_timed_traps=$(trap -p HUP INT TERM)
  trap 'fm_timed_signal=129' HUP
  trap 'fm_timed_signal=130' INT
  trap 'fm_timed_signal=143' TERM
  case "$mechanism" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" || fm_timed_rc=$? ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" || fm_timed_rc=$? ;;
    perl)
      perl -MPOSIX=setpgid,sigprocmask,SIG_BLOCK,SIG_SETMASK,SIGTERM,SIGINT,SIGHUP -e '
        my $t = shift;
        my $mask = POSIX::SigSet->new;
        sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP), $mask);
        my $pid;
        my $stop = sub {
          my $rc = shift;
          $SIG{$_} = "IGNORE" for qw(ALRM HUP INT TERM);
          kill "TERM", -$pid;
          select undef, undef, undef, 0.2;
          kill "KILL", -$pid;
          waitpid $pid, 0;
          exit $rc;
        };
        local $SIG{ALRM} = sub { $stop->(124) };
        local $SIG{HUP} = sub { $stop->(129) };
        local $SIG{INT} = sub { $stop->(130) };
        local $SIG{TERM} = sub { $stop->(143) };
        $pid = fork;
        die "fork failed" unless defined $pid;
        if (!$pid) {
          $SIG{$_} = "DEFAULT" for qw(ALRM HUP INT TERM);
          setpgid(0, 0);
          sigprocmask(SIG_SETMASK, $mask);
          exec @ARGV;
          exit 127;
        }
        setpgid($pid, $pid);
        sigprocmask(SIG_SETMASK, $mask);
        alarm $t;
        waitpid $pid, 0;
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
      ' "$seconds" "$@" <&0 &
      runner_pid=$!
      fm_wait_timed "$runner_pid" || fm_timed_rc=$?
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" || fm_timed_rc=$? ;;
    *) fm_timed_rc=124 ;;
  esac
  trap - HUP INT TERM
  eval "$fm_timed_traps"
  if [ -n "$fm_timed_signal" ]; then
    bash -c "kill -$((fm_timed_signal - 128)) \"\$PPID\""
    return "$fm_timed_signal"
  fi
  return "$fm_timed_rc"
}

fm_timed_out() {  # <status>
  case ${1:-} in
    124 | 137) return 0 ;;
  esac
  return 1
}

# The perl watchdog forks the command into its own process group (both sides
# call setpgid, so the group exists before either can signal it) and polls
# waitpid(WNOHANG) against wall-clock deadlines rather than using alarm+die,
# which keeps the bound off perl's platform-dependent syscall-restart signal
# semantics and off the drift of counting sleep intervals.
fm_exec_timed() {  # <seconds> <grace-seconds> <command...>
  local seconds=${1:-} grace=${2:-} value owner
  for value in "$seconds" "$grace"; do
    case "$value" in
      '' | 0* | *[!0-9]*)
        echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
        exit 125
        ;;
    esac
  done
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
    exit 125
  fi
  owner=${FM_EXEC_TIMED_OWNER_PID:-$$}
  unset FM_EXEC_TIMED_OWNER_PID
  if command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX=WNOHANG,setpgid,sigprocmask,SIG_BLOCK,SIG_SETMASK,SIGTERM,SIGINT,SIGHUP -MTime::HiRes=time -e '
      my ($bound, $grace, $owner, $shell_parent) = (shift, shift, shift, shift);
      # exec preserves the shell PID, including in Bash 3.2 subshells where
      # BASHPID is unavailable. Keep the pre-exec parent for startup races.
      $owner = $shell_parent if $owner == $$;
      my $parent = getppid();
      my ($pid, $pending, $kill_at, $timed_out, $interrupted) = (0, "", 0, 0, 0);
      for my $sig (qw(TERM INT HUP)) {
        $SIG{$sig} = sub {
          if ($pid) { kill $sig, -$pid } else { $pending = $sig }
          $kill_at ||= time + $grace;
          $interrupted = 1 if $sig eq "INT";
        };
      }
      # Hold these signals from the fork until the child has reset them: perl
      # defers one that lands before the reset and dispatches it afterwards
      # as a call to a sub named DEFAULT, which drops it.
      my $mask = POSIX::SigSet->new;
      sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP), $mask);
      # The sentinel exists before the command does, in a group of its own, so
      # a KILL to the callers group cannot take it too. The command writes its
      # pid, which is its group, before exec; EOF with no "done" from this
      # watchdog means the watchdog was killed, and the sentinel ends that
      # group in its place.
      pipe(my $heard, my $tell) or exit 127;
      my $sentinel = fork;
      exit 127 unless defined $sentinel;
      if ($sentinel == 0) {
        $SIG{$_} = "IGNORE" for qw(TERM INT HUP);
        setpgid(0, 0);
        sigprocmask(SIG_SETMASK, $mask);
        close $tell;
        open STDIN, "<", "/dev/null";
        open STDOUT, ">", "/dev/null";
        open STDERR, ">", "/dev/null";
        my $said = "";
        while (sysread $heard, $said, 64, length $said) {
          exit 0 if $said =~ /done/;
        }
        exit 0 unless $said =~ /^(\d+)/;
        my $group = $1;
        kill "TERM", -$group;
        my $kill_group_at = time + $grace;
        select undef, undef, undef, 0.05 while time < $kill_group_at && kill 0, -$group;
        kill "KILL", -$group;
        exit 0;
      }
      setpgid($sentinel, $sentinel);
      close $heard;
      my $child = fork;
      exit 127 unless defined $child;
      if ($child == 0) {
        $SIG{$_} = "DEFAULT" for qw(TERM INT HUP);
        kill $pending, $$ if $pending;
        setpgid(0, 0);
        { local $SIG{PIPE} = "IGNORE"; syswrite $tell, "$$\n"; }
        sigprocmask(SIG_SETMASK, $mask);
        exec @ARGV;
        exit 127;
      }
      setpgid($child, $child);
      $pid = $child;
      sigprocmask(SIG_SETMASK, $mask);
      kill $pending, -$pid if $pending;
      my $deadline = time + $bound;
      sub finish {
        my $status = shift;
        kill "KILL", -$pid if $kill_at;
        { local $SIG{PIPE} = "IGNORE"; syswrite $tell, "done"; }
        exit 124 if $timed_out;
        exit 130 if $interrupted;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      while (1) {
        my $done = waitpid $pid, WNOHANG;
        finish($?) if $done == $pid;
        exit 127 if $done == -1;
        if ($kill_at) {
          if (time >= $kill_at) {
            kill "KILL", -$pid;
            waitpid $pid, 0;
            finish($?);
          }
        } elsif (time >= $deadline) {
          $timed_out = 1;
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        } elsif (getppid() != $parent || !kill(0, $owner)) {
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        }
        select undef, undef, undef, 0.05;
      }
    ' -- "$seconds" "$grace" "$owner" "$PPID" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    exec timeout -k "$grace" "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout -k "$grace" "$seconds" "$@"
  fi
  printf 'fm_exec_timed: cannot bound %s within %ss: none of perl, timeout, or gtimeout is available\n' "${1##*/}" "$seconds" >&2
  exit 127
}
