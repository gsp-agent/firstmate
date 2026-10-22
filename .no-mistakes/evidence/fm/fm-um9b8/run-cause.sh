#!/usr/bin/env bash
set -u
export TMPDIR="$PWD/.gate-lint-validation/tmp"
export FM_LINT_ROOT_MEMORY_KIB=2097152
export FM_LINT_ROOT_SECONDS=120
export FM_LINT_ROOT_GRACE=1
export FM_LINT_JOBS=1
proof=/Users/dalecarman/.no-mistakes/evidence/01M5JE8ZBBW8CTJJHBYEAVZSNQ
bin/fm-lint.sh --telemetry "$proof/cause-full.tsv" .gate-lint-validation/repro-10x7/l7.sh > "$proof/cause-full.log" 2>&1
printf 'exit=%s\n' "$?" >> "$proof/cause-full.log"
bin/fm-lint.sh --fast --telemetry "$proof/cause-fast.tsv" .gate-lint-validation/repro-10x7/l7.sh > "$proof/cause-fast.log" 2>&1
printf 'exit=%s\n' "$?" >> "$proof/cause-fast.log"
