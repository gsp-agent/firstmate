#!/usr/bin/env bash
# The sweep keeps its bounded row processes, but must not revalidate its backlog
# address for every read or fork a pipeline for each scalar field. Count Bash processes
# (including command substitutions) with an inherited DEBUG trap, not ps polling
# which misses short-lived children. Native programs' internal forks are outside
# this budget. This counter needs Bash 4+; routing itself still supports Bash 3.2.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'skip: fork counting requires BASHPID (Bash 4+)'; exit 0; }
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi not found'; exit 0; }
unset FM_TASKS_AXI_COMPATIBLE FM_CAPTAIN_HOLD_CONTRACT
TMP_ROOT=$(fm_test_tmproot fm-route-due-fork-budget)

cat > "$TMP_ROOT/count.sh" <<'SH'
if [ "${1:-}" = route-due ] && [ "$#" -eq 2 ]; then
  printf '%s\n' "$2" >> "$FM_ROW_LOG"
fi
set -T
# Each child inherits its parent's last pid, so the first command in every
# Bash process writes once. The trap itself uses builtins and starts no process.
trap 'if [ "${fm_budget_pid:-}" != "$BASHPID" ]; then
  fm_budget_pid=$BASHPID
  printf "%s\n" "$BASHPID" >> "$FM_FORK_LOG"
fi' DEBUG
SH

empty=0
one=0
for n in 0 1 3; do
  home="$TMP_ROOT/home-$n"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # Live rows keep their old body below the hold fields, past the listing's cut.
  cat > "$home/body" <<'BODY'
Captain hold set: 2026-10-24T08:00:00Z
Decision owner: captain
Hold timeout seconds: 300
Hold reason: Should I spend money?

Previous task body:
BODY
  note=1
  while [ "$note" -le 40 ]; do
    printf 'Earlier note %s for this task.\n' "$note" >> "$home/body"
    note=$((note + 1))
  done
  cat > "$home/router.py" <<'PY'
import os
import sys
from pathlib import Path

with (Path(os.environ["FM_HOME"]) / "visited").open("a") as log:
    log.write(sys.argv[sys.argv.index("--task") + 1] + "\n")
print("kept")
PY
  i=0
  while [ "$i" -lt "$n" ]; do
    (
      cd "$home" || exit 1
      export HOME="$home" TASKS_AXI_BACKEND=markdown
      tasks-axi add "row-$i" "Budget row $i" --kind ship --repo fixture >/dev/null
      tasks-axi update "row-$i" --body-file "$home/body" >/dev/null
      tasks-axi hold "row-$i" --kind captain --reason 'Should I spend money?' >/dev/null
    )
    i=$((i + 1))
  done
  for sweep in first unchanged; do
  : > "$home/forks"
  : > "$home/rows"
  HOME="$home" TASKS_AXI_BACKEND=markdown FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_HOLD_DOMAIN_ROUTER="$home/router.py" \
    BASH_ENV="$TMP_ROOT/count.sh" FM_FORK_LOG="$home/forks" FM_ROW_LOG="$home/rows" \
    python3 - "$ROOT/bin/fm-captain-hold.sh" "$n" "$sweep" <<'PY'
import subprocess
import sys
import time

start = time.monotonic()
subprocess.run(["bash", sys.argv[1], "route-due"], check=True)
print(f"route-due rows={sys.argv[2]} sweep={sys.argv[3]} wall_seconds={time.monotonic() - start:.3f}")
PY
  count=$(LC_ALL=C sort -u "$home/forks" | wc -l | tr -d ' ')
  printf 'route-due rows=%s sweep=%s bash_processes=%s row_processes=%s\n' "$n" "$sweep" "$count" "$(wc -l < "$home/rows" | tr -d ' ')"
  if [ "$sweep" = unchanged ]; then
    # Measurement-only escape for rerunning the same fixture on the old commit.
    [ "${FM_ROUTE_SKIP_BASELINE:-0}" = 1 ] || [ ! -s "$home/rows" ] \
      || fail 'unchanged held rows started per-row processes on the second sweep'
    continue
  fi
  first_count=$count
  if [ "$n" -eq 0 ]; then
    empty=$count
  else
    [ "$(wc -l < "$home/visited" | tr -d ' ')" -eq "$n" ] || fail 'budget passed by skipping a held row'
    [ "$(cat "$home/state/hold-domain/sweep-cursor")" = "row-$((n - 1))" ] || fail 'sweep cursor did not advance'
    [ "$n" -ne 1 ] || one=$count
  fi
  done
done
count=$first_count
per_row=$(((count - one) / 2))
printf 'route-due fixed=%s marginal_bash_processes_per_row=%s\n' "$empty" "$per_row"
# Baseline 48a1a07a: 119 per row, 408 for three rows. Leave a little room for
# platform differences while preventing either repeated reads or pipelines
# from quietly restoring the old cost.
[ "$per_row" -le 90 ] || fail "route-due exceeds 90 Bash processes per row: $per_row"
[ "$count" -le 325 ] || fail "three-row route-due exceeds 325 Bash processes: $count"
pass 'routing sweep stays within its per-row fork budget and visits every hold'
