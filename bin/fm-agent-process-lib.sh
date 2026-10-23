#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: every runtime backend that proves an agent is alive does it by
# attributing operating-system processes - the pane's foreground process group
# on tmux, Herdr's `pane process-info` view plus the pane shell's descendants
# on Herdr - and the two must agree on what a given process name means, or a
# harness one backend recognizes silently reads as a dead pane on the other.
# The classifier moved here verbatim from the tmux adapter, where it was born;
# docs/tmux-backend.md "Agent liveness probe" owns the empirical basis for the
# names below, and tests/fm-tmux-agent-liveness.test.sh plus
# tests/fm-harness-liveness-drift-live-e2e.test.sh keep them honest.

_FM_AGENT_PROCESS_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_AGENT_PROCESS_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AGENT_PROCESS_LIB_DIR=.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-gemini-lib.sh"
unset _FM_AGENT_PROCESS_LIB_DIR

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    # omp (Oh My Pi) is anchored for the same reason as muse: its live process
    # name is the bare word `omp` (verified, omp 18.1.11) and a glob would claim
    # unrelated commands such as ompd or comp.
    *claude*|*codex*|*opencode*|*grok*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp) printf 'agent' ;;
    # agy (Antigravity CLI) is anchored for the same reason as muse and omp: its
    # live process name is the bare word `agy` (verified, agy 1.2.0: a Go-compiled
    # single binary, comm=agy with argv[0]=agy), and a glob would claim
    # unrelated commands containing that fragment. devin is anchored the same
    # way (verified, devin 3000.11.1: comm=devin), so a `*devin*` glob never
    # claims an unrelated command.
    agy|devin) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args>   the flattened command line, read only for the node-bundle
#            harnesses whose identity sits in argv[1] (bin/fm-gemini-lib.sh).
#   [pid]    when given, lets the Gemini rule read argv boundaries from the
#            live process instead of the flattened line.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} args=${3:-} pid=${4:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ -n "$pid" ] && fm_gemini_pid_is_gemini "$pid"; then
    printf 'agent'
    return 0
  fi
  if [ -n "$args" ] && fm_gemini_args_are_gemini "$args"; then
    printf 'agent'
    return 0
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_snapshot: one tab-separated row per live process:
# pid, ppid, pgid, class, args. class is the argv0 verdict from
# fm_agent_process_classify_name. Empty and nonzero when the process table
# cannot be read, so a caller does not treat "no rows" as "no processes".
fm_agent_process_snapshot() {
  local raw line pid ppid pgid args argv0 class
  raw=$(LC_ALL=C ps -axo pid=,ppid=,pgid=,command= 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # A command line is data. Word-split it without globbing, or a `*` in
    # argv would become a filename and the pid columns would shift.
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    pid=$1
    ppid=$2
    pgid=$3
    shift 3 || continue
    args=$*
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ppid" in ''|*[!0-9]*) continue ;; esac
    case "$pgid" in ''|*[!0-9]*) continue ;; esac
    argv0=${args%%[[:space:]]*}
    [ -n "$argv0" ] || continue
    class=$(fm_agent_process_classify_name "$argv0" "$argv0")
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$pgid" "$class" "$args"
  done
}

# fm_agent_process_background_pids: pids to stop before a Claude exit.
# <mode> is shells or commands. <roots> and <commands> are newline-separated.
# The snapshot is stdin in fm_agent_process_snapshot's format.
# shells selects shell-classified descendants of the roots that sit outside
# every root's process group, plus the processes those shells have started.
# A root is walked only when this snapshot still classifies that pid as agent.
# Any other owner of that pid selects nothing.
# commands selects descendants whose args contain one listed command as a
# whole token sequence, then the same shell closure. Roots themselves are
# never selected. Prints nothing when there is nothing to stop.
fm_agent_process_background_pids() {  # <mode> <roots> <commands>
  local mode=$1 roots=$2 commands=$3
  {
    printf '%s\n' "$roots" | while IFS= read -r _fm_root; do
      case "$_fm_root" in
        ''|*[!0-9]*) ;;
        *) printf 'R\t%s\n' "$_fm_root" ;;
      esac
    done
    printf '%s\n' "$commands" | while IFS= read -r _fm_cmd; do
      [ -n "$_fm_cmd" ] || continue
      printf 'C\t%s\n' "$_fm_cmd"
    done
    cat
  } | awk -F '\t' -v mode="$mode" '
    function match_cmd(args,    i, cmd, rest, pos, start, abs, before, after) {
      for (i = 1; i <= ncmd; i++) {
        cmd = cmds[i]
        if (cmd == "") continue
        rest = args
        start = 1
        while ((pos = index(rest, cmd)) > 0) {
          abs = start + pos - 1
          before = (abs == 1) ? "" : substr(args, abs - 1, 1)
          after = substr(args, abs + length(cmd), 1)
          if ((abs == 1 || before ~ /[[:space:]]/) && (after == "" || after !~ /[[:alnum:]_]/))
            return 1
          if (pos >= length(rest)) break
          start = abs + 1
          rest = substr(args, start)
        }
      }
      return 0
    }
    $1 == "R" { if ($2 ~ /^[0-9]+$/) roots[$2] = 1; next }
    $1 == "C" {
      cmd = $2
      for (i = 3; i <= NF; i++) cmd = cmd "\t" $i
      if (cmd != "") cmds[++ncmd] = cmd
      next
    }
    $1 ~ /^[0-9]+$/ && NF >= 5 {
      pid = $1
      ppid = $2
      pgid = $3
      class = $4
      args = $5
      for (i = 6; i <= NF; i++) args = args "\t" $i
      ppid_of[pid] = ppid
      pgid_of[pid] = pgid
      class_of[pid] = class
      args_of[pid] = args
      kids[ppid] = kids[ppid] " " pid
      next
    }
    END {
      unsafe = 0
      for (r in roots) {
        if (!(r in class_of) || class_of[r] != "agent") continue
        root_pgid[pgid_of[r]] = 1
        n = split(kids[r], arr, " ")
        for (i = 1; i <= n; i++) if (arr[i] != "") queue[++qn] = arr[i]
      }
      qi = 1
      while (qi <= qn) {
        cur = queue[qi++]
        if (cur in seen) continue
        seen[cur] = 1
        desc[cur] = 1
        n = split(kids[cur], arr, " ")
        for (i = 1; i <= n; i++)
          if (arr[i] != "" && !(arr[i] in seen)) queue[++qn] = arr[i]
      }
      # A listed task that shares the agent process group cannot be stopped
      # without signaling the agent. Name that and select nothing.
      if (mode == "commands") {
        for (p in desc)
          if ((pgid_of[p] in root_pgid) && match_cmd(args_of[p])) unsafe = 1
      }
      for (p in desc)
        if (pgid_of[p] in root_pgid) delete desc[p]
      if (unsafe) {
        print "UNSAFE"
        exit
      }
      if (mode == "shells") {
        for (p in desc)
          if (class_of[p] == "shell") sel[p] = 1
      } else if (mode == "commands") {
        for (p in desc)
          if (match_cmd(args_of[p])) sel[p] = 1
        for (p in sel) {
          a = ppid_of[p]
          while (a != "" && (a in desc)) {
            if (class_of[a] == "shell") sel[a] = 1
            a = ppid_of[a]
          }
        }
      }
      changed = 1
      while (changed) {
        changed = 0
        for (p in desc) {
          if (p in sel) continue
          a = ppid_of[p]
          under = 0
          while (a != "" && (a in desc)) {
            if ((a in sel) && class_of[a] == "shell") { under = 1; break }
            a = ppid_of[a]
          }
          if (under) { sel[p] = 1; changed = 1 }
        }
      }
      for (p in sel) print p
    }
  '
}
