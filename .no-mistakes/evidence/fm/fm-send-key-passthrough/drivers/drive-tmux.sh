#!/usr/bin/env bash
# Live tmux scenario: real bin/fm-send.sh --key against a real tmux pane on a
# private socket owned by a disposable lab home. The pane runs dialog.py, which
# records the exact bytes it receives.
# Usage: drive-tmux.sh <worktree-root> <scratch-dir> <lab-home>
set -u
ROOT=$1 SCRATCH=$2 LAB=$3
TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || { echo "no lab tmux dir"; exit 1; }
LOG="$SCRATCH/tmux-bytes.log"
: > "$LOG"

T() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux "$@"; }
SEND() {
  env -u TMUX -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$TMUXDIR" FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$@"
}

cleanup() {
  T kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || echo "lab tmux teardown refused"
}
trap cleanup EXIT

echo "tmux version: $(tmux -V)"
T -f /dev/null new-session -d -s keylab -n dlg -x 120 -y 30 "python3 $SCRATCH/dialog.py $LOG" \
  || { echo "could not start the lab tmux pane"; exit 1; }
for _ in $(seq 1 50); do grep -q '^ready$' "$LOG" && break; sleep 0.1; done
grep -q '^ready$' "$LOG" || { echo "dialog never became ready"; exit 1; }
echo "lab pane: keylab:dlg (private socket under the lab home's tmux dir)"
echo
echo "--- pane before any key ---"
T capture-pane -p -t keylab:dlg | sed '/^$/d'

failures=0
for k in Escape C-c X Enter; do
  before=$(wc -l < "$LOG")
  start=$(python3 -c 'import time; print(time.time())')
  out=$(SEND keylab:dlg --key "$k" 2>&1); rc=$?
  end=$(python3 -c 'import time; print(time.time())')
  for _ in $(seq 1 30); do [ "$(wc -l < "$LOG")" -gt "$before" ] && break; sleep 0.1; done
  sleep 0.2
  got=$(tail -n +"$((before + 1))" "$LOG" | sed 's/^got //' | tr '\n' ' ')
  printf '\n$ fm-send.sh keylab:dlg --key %s\n  exit=%s elapsed=%.2fs output=%s\n  pane received bytes (hex): %s\n' \
    "$k" "$rc" "$(python3 -c "print($end-$start)")" "${out:-<none>}" "${got:-<nothing>}"
  case "$k" in
    Escape) want=1b ;; C-c) want=03 ;; X) want=58 ;; Enter) want=0d ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$got" = "$want " ]; then
    echo "  PASS: exactly 0x$want reached the pane"
  else
    echo "  FAIL: expected exactly 0x$want and exit 0"
    failures=$((failures + 1))
  fi
done

echo
echo "--- pane after Escape, C-c, X, Enter ---"
T capture-pane -p -t keylab:dlg | sed '/^$/d'

echo
echo "--- adversarial: --key X to a window that does not exist ---"
start=$(python3 -c 'import time; print(time.time())')
out=$(SEND keylab:nope --key X 2>&1); rc=$?
end=$(python3 -c 'import time; print(time.time())')
printf '$ fm-send.sh keylab:nope --key X\n  exit=%s elapsed=%.2fs\n  stderr: %s\n' "$rc" "$(python3 -c "print($end-$start)")" "$out"
if [ "$rc" -ne 0 ]; then echo "  PASS: refused loudly, nothing reported delivered"; else echo "  FAIL: a dead endpoint reported success"; failures=$((failures + 1)); fi

echo
echo "tmux scenario failures: $failures"
[ "$failures" -eq 0 ]
