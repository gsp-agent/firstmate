#!/usr/bin/env bash
# Dump the final cleanup records of the scenario holds from each lab.
E=$(cd "$(dirname "$0")" && pwd)
dump() { local name=$1 dir=$2 id; shift 2; for id in "$@"; do printf '%s %s: ' "$name" "$id"; jq -c . "$dir/data/$id/record/data-cleanup.json" 2>/dev/null | sed "s#$dir#<lab>#g" || echo "(no record)"; done; }
dump lab1 "$(cat "$E/lab-path.txt")" t-agentcfg t-gsp t-project t-fallback t-unread t-unread-gsp t-route t-bigreport t-hugelog aa-slow bb-young
dump lab2 "$(cat "$E/lab2-path.txt")" zz-live yy-live cc-medium ee-medium
dump lab3-prefix "$(cat "$E/lab3-path.txt")" t-bigreport aa-slow
