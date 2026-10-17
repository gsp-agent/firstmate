#!/usr/bin/env bash
# Run the four suites alone, one after another, with a short cooldown.
set -u
S=/Users/dalecarman/.no-mistakes/evidence/01M55Y5XKTJTJD73274HVHFNG1/scripts/alone-run.sh
for suite in tests/fm-wake-queue.test.sh tests/fm-host-mirror.test.sh \
  tests/fm-watch-triage.test.sh tests/fm-supervision-host.test.sh; do
  bash "$S" "$suite"
  echo "=========="
  sleep 10
done
