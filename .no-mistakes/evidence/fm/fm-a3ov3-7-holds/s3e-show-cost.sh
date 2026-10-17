#!/usr/bin/env bash
# s3e: direct tasks-axi show cost per captain row in the live-home-scale lab.
set -u
LAB=$1
cd "$LAB" || exit 1
now_s() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
echo "host: $(uptime | sed 's/.*load/load/')"
for id in human taste mixed human; do
  s=$(now_s); tasks-axi show "$id" --full > "$LAB/show-$id.out" 2>&1; rc=$?; e=$(now_s)
  echo "tasks-axi show $id --full: exit $rc, $(echo "$e - $s" | bc)s, $(wc -c < "$LAB/show-$id.out" | tr -d ' ') bytes"
done
