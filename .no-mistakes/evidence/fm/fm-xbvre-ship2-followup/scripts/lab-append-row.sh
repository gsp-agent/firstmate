#!/usr/bin/env bash
# Append one check row for main to a lab home's wake queue through the
# production writer (fm_wake_append), the way a watcher lands a row. The lab
# Claude primary's FileChanged hook on state/.wake-queue then fires the waker.
# Usage: lab-append-row.sh <lab-root-copy> <lab-home> <key> <row text>
set -u
root=$1 lab=$2 key=$3 text=$4
export FM_HOME="$lab"
# shellcheck source=/dev/null
. "$root/bin/fm-wake-lib.sh"
fm_wake_append check "$key" "$text"
