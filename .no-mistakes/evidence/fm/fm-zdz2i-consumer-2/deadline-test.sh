#!/bin/bash
set -u
export TMPDIR="$PWD/.test-phase-tmp"
. tests/fm-watch-arm.test.sh
test_covering_startup_clean_closes_share_one_deadline
