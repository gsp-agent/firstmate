#!/bin/bash
# fm_run_cpu_timed 1 over a busy loop that ignores SIGXCPU; run under a probe wall bound.
. /Users/dalecarman/.agent-scratch/nm-runs/a5e67f4ea77f/01M5SW87YP0RGKBE86WKN1RSHF/bin/fm-timeout-lib.sh
fm_run_cpu_timed 1 /bin/bash -c 'trap "" XCPU; while :; do :; done'
