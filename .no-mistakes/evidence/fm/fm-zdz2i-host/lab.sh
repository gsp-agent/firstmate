#!/usr/bin/env bash
# Lab driver for the zdz2i live checks. The primary runs from a disposable
# plain-git snapshot of the commit under test (ROOT), with FM_HOME set to a
# marked lab home (LAB); every tmux call goes through the lab's private socket.
# ROOT/bin/fm-inbox-base.sh is bin/fm-inbox.sh from the parent commit 9ed80766,
# for a before/after reading of the same live state.
set -u
T=${TMPDIR%/}
LAB=$(cat "$T/fm-lab-zdz2i-current")
ROOT=$(cd -P "$(cat "$T/fm-root-zdz2i-current")" && pwd -P)
clean_env() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PID -u CLAUDE_CODE_CHILD_SESSION \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT "$@"; }
tm() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && echo yes || echo no; }
case "${1:-}" in
  start) shift; cd "$ROOT" && clean_env TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$ROOT" -e FM_HOME="$LAB" "$@" /Users/dalecarman/.local/bin/claude ;;
  tm) shift; tm "$@" ;;
  cap) tm capture-pane -p -t primary | grep -v '^[[:space:]]*$' | tail -"${2:-25}" ;;
  keys) shift; tm send-keys -t primary "$@" ;;
  ready) cd "$ROOT" && clean_env FM_HOME="$LAB" "$ROOT/bin/fm-inbox.sh" ready ;;
  ready-old) cd "$ROOT" && clean_env FM_HOME="$LAB" "$ROOT/bin/fm-inbox-base.sh" ready ;;
  watchers)
    w=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
    echo "watcher pid: ${w:-none} alive=$(alive "$w")"
    l=$(head -1 "$LAB/state/.lock" 2>/dev/null || true)
    echo "session lock pid: ${l:-none} alive=$(alive "$l")"
    echo "host record: $(tr '\n' ' ' < "$LAB/state/.supervision-host" 2>/dev/null || echo none)"
    if [ -e "$LAB/state/.last-watcher-beat" ]; then echo "beacon age: $(( $(date +%s) - $(stat -f %m "$LAB/state/.last-watcher-beat") ))s"; else echo "beacon: none"; fi ;;
  kill) tm kill-server ;;
  *) echo "usage: lab.sh start|cap|keys|ready|ready-old|watchers|kill" >&2; exit 2 ;;
esac
