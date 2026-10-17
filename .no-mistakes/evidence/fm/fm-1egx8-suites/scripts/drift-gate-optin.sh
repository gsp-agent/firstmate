#!/usr/bin/env bash
# Feed the CI lane's value through the real fm_live_gate the drift guard opens with.
. /Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M55Y5XKTJTJD73274HVHFNG1/tests/lib.sh
fm_live_gate opt-in FM_HARNESS_LIVENESS_DRIFT tmux
echo "gate open: the drift guard body would run"
