#!/usr/bin/env bash
# Live Herdr scenario: real bin/fm-send.sh --key against a real pane in a named
# non-default fm-lab-* Herdr session. Every Herdr call, including the ones the
# production adapter makes, goes through bin/fm-herdr-lab.sh. The pane runs
# dialog.py, which records the exact bytes it receives.
# Usage: drive-herdr.sh <worktree-root> <scratch-dir> <lab-home>
set -u
ROOT=$1 SCRATCH=$2 LAB=$3
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LOG="$SCRATCH/herdr-bytes.log"
FAKEBIN="$SCRATCH/fakebin"
ORIGINAL_PATH=$PATH
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
: > "$LOG"
mkdir -p "$FAKEBIN"

SESSION=$("$LAB_HELPER" name sendkey-x)
cleanup() {
  if "$LAB_HELPER" teardown "$SESSION"; then
    echo "lab teardown: $SESSION removed, default-session tripwire unchanged"
  else
    echo "lab teardown FAILED for $SESSION"
  fi
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "$SESSION" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;; esac
  done
fi
PATH="$ORIGINAL_PATH" exec "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
SEND() {
  env -u TMUX -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$LAB" \
    "$ROOT/bin/fm-send.sh" "$@"
}

echo "herdr version: $(herdr --version 2>/dev/null | head -1)"
"$LAB_HELPER" provision "$SESSION" || { echo "could not provision $SESSION"; exit 1; }
echo "lab session: $SESSION (non-default, provisioned by bin/fm-herdr-lab.sh)"
WS_JSON=$(lab workspace create --cwd "$SCRATCH" --label fm-sendkeylab --no-focus) || { echo "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || { echo "no pane id"; exit 1; }
TARGET="$SESSION:$PANE"
echo "lab pane: $PANE"
lab pane run "$PANE" "python3 $SCRATCH/dialog.py $LOG" >/dev/null || { echo "pane run failed"; exit 1; }
for _ in $(seq 1 100); do grep -q '^ready$' "$LOG" && break; sleep 0.1; done
grep -q '^ready$' "$LOG" || { echo "dialog never became ready"; exit 1; }
sleep 0.5
echo
echo "--- pane before any key ---"
lab pane read "$PANE" --source visible | sed '/^[[:space:]]*$/d' | tail -n 8

failures=0
# Escape, C-c, X, Enter are the incident sequence. Esc, ctrl+c and C-u check
# the header's "in any listed spelling" normalization claim.
for k in Escape C-c X Enter Esc ctrl+c C-u; do
  before=$(wc -l < "$LOG")
  start=$(python3 -c 'import time; print(time.time())')
  out=$(SEND "$TARGET" --key "$k" 2>&1); rc=$?
  end=$(python3 -c 'import time; print(time.time())')
  for _ in $(seq 1 30); do [ "$(wc -l < "$LOG")" -gt "$before" ] && break; sleep 0.1; done
  sleep 0.3
  got=$(tail -n +"$((before + 1))" "$LOG" | sed 's/^got //' | tr '\n' ' ')
  printf '\n$ fm-send.sh %s --key %s\n  exit=%s elapsed=%.2fs output=%s\n  pane received bytes (hex): %s\n' \
    "$TARGET" "$k" "$rc" "$(python3 -c "print($end-$start)")" "${out:-<none>}" "${got:-<nothing>}"
  case "$k" in
    Escape|Esc) want=1b ;; C-c|ctrl+c) want=03 ;; X) want=58 ;; Enter) want=0d ;; C-u) want=15 ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$got" = "$want " ]; then
    echo "  PASS: exactly 0x$want reached the pane"
  else
    echo "  FAIL: expected exactly 0x$want and exit 0"
    failures=$((failures + 1))
  fi
done

echo
echo "--- pane after the keys ---"
lab pane read "$PANE" --source visible | sed '/^[[:space:]]*$/d' | tail -n 16

echo
echo "--- adversarial: --key X to a pane id that does not exist in the lab ---"
start=$(python3 -c 'import time; print(time.time())')
out=$(SEND "$SESSION:w999:p999" --key X 2>&1); rc=$?
end=$(python3 -c 'import time; print(time.time())')
printf '$ fm-send.sh %s --key X\n  exit=%s elapsed=%.2fs\n  stderr: %s\n' "$SESSION:w999:p999" "$rc" "$(python3 -c "print($end-$start)")" "$out"
if [ "$rc" -ne 0 ]; then echo "  PASS: refused loudly, nothing reported delivered"; else echo "  FAIL: a dead endpoint reported success"; failures=$((failures + 1)); fi

echo
echo "herdr scenario failures: $failures"
[ "$failures" -eq 0 ]
