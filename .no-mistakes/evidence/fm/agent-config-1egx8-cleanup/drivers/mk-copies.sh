#!/usr/bin/env bash
# Build two disposable copies of the target commit under the scratch dir:
# fixed (as committed) and nosweep (the exit sweep's call removed from suite_cleanup).
set -eu
worktree=$1
scratch=$2
drivers=$3
for name in fixed nosweep; do
  mkdir -p "$scratch/$name"
  git -C "$worktree" archive HEAD | tar -x -C "$scratch/$name"
  cp "$drivers/probe-held.test.sh" "$scratch/$name/tests/zz-probe-held.test.sh"
done
perl -0pi -e 's/\n  stop_own_processes "\$listed"\n/\n  : sweep-removed\n/' "$scratch/nosweep/tests/fm-supervision-host.test.sh"
diff "$scratch/fixed/tests/fm-supervision-host.test.sh" "$scratch/nosweep/tests/fm-supervision-host.test.sh" || true
