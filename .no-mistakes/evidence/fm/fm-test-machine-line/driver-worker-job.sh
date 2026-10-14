#!/usr/bin/env bash
set -eu
cd /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4WN4HWS9WNQ0STXQVSD1KF2/.live-machine-line/candidate-repo
exec /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4WN4HWS9WNQ0STXQVSD1KF2/.live-machine-line/candidate-repo/bin/fm-test-run.sh --jobs 4 --json /Users/dalecarman/.no-mistakes/evidence/01M4WN4HWS9WNQ0STXQVSD1KF2/worker-suite.json tests/fm-dod-lib.test.sh tests/fm-forge-detect.test.sh tests/fm-project-mode.test.sh tests/fm-trace-context-lib.test.sh
