#!/usr/bin/env bash
# equivalence.sh <out-dir> - run old (433c7b85) and new producers against the
# lab home with a pinned clock, two rounds each, in every output mode; then diff.
set -u
. /Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK/lab-paths.env
E=/Users/dalecarman/.no-mistakes/evidence/01M5518WCKZCZZKKA1AW7FWEMK
W=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M5518WCKZCZZKKA1AW7FWEMK
OUT=$1; mkdir -p "$OUT"
for round in 1 2; do
  for ver in before after; do
    case $ver in before) tree=$SCR/before ;; *) tree=$W ;; esac
    for mode in json secondmate-home-summary contribution-input; do
      FM_LAB_PIN_NOW=1 "$E/scripts/run-lab.sh" "$tree" fm-fleet-snapshot.sh "--$mode" \
        > "$OUT/$ver-$mode-$round.json" 2> "$OUT/$ver-$mode-$round.err"
      printf '%s %s round%s rc=%s bytes=%s\n' "$ver" "$mode" "$round" "$?" "$(wc -c < "$OUT/$ver-$mode-$round.json" | tr -d ' ')"
    done
  done
done
# The --json document names its own root (the bin tree it ran from); normalize
# only that path so code location is not counted as a content difference.
for f in "$OUT"/*-json-*.json; do
  sed -e "s#$SCR/before#<ROOT>#g" -e "s#$W#<ROOT>#g" "$f" > "${f%.json}.norm"
done
for mode in secondmate-home-summary contribution-input; do
  for round in 1 2; do
    if cmp -s "$OUT/before-$mode-$round.json" "$OUT/after-$mode-$round.json"; then echo "IDENTICAL $mode round$round"; else echo "DIFFERENT $mode round$round"; diff <(jq -S . "$OUT/before-$mode-$round.json") <(jq -S . "$OUT/after-$mode-$round.json") | head -40; fi
  done
done
for round in 1 2; do
  if cmp -s "$OUT/before-json-$round.norm" "$OUT/after-json-$round.norm"; then echo "IDENTICAL json round$round"; else echo "DIFFERENT json round$round"; diff <(jq -S . "$OUT/before-json-$round.norm") <(jq -S . "$OUT/after-json-$round.norm") | head -60; fi
done
