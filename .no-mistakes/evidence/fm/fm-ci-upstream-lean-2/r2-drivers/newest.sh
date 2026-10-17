#!/usr/bin/env bash
# fm-cursor-guard.sh fallback picks the newest spending file by mtime and ages it.
set -u
WT=$1 OUT=$2
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
U="$LAB/cursor-usage"; mkdir -p "$U" "$LAB/pstack/.cursor-plugin"
printf '{"version":"0.15.21"}\n' > "$LAB/pstack/.cursor-plugin/plugin.json"
g() { FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_CURSOR_USAGE_DIR="$U" FM_PSTACK_DIR="$LAB/pstack" bin/fm-cursor-guard.sh fallback lab-bead 2>&1; }
{
echo "lab: $LAB; default limits 85% / 26 h"
echo
echo "=== 1. older file says 90%, newer file (alphabetically first) says 10%"
printf 'cursor_models_pct=90\n' > "$U/zz-old-spending.txt"; touch -t "$(date -v-2H +%Y%m%d%H%M)" "$U/zz-old-spending.txt"
printf 'cursor_models_pct=10\n' > "$U/aa-new-spending.txt"
ls -lT "$U" | sed 's/^/  /'
echo "\$ fm-cursor-guard.sh fallback lab-bead -> $(g)"
echo
echo "=== 2. newer file says 90%, older says 10%"
printf 'cursor_models_pct=90\n' > "$U/aa-new-spending.txt"; printf 'cursor_models_pct=10\n' > "$U/zz-old-spending.txt"; touch -t "$(date -v-2H +%Y%m%d%H%M)" "$U/zz-old-spending.txt"
echo "\$ fm-cursor-guard.sh fallback lab-bead -> $(g)"
echo
echo "=== 3. only file is 30 h old (limit 26 h)"
rm -f "$U/aa-new-spending.txt"; printf 'cursor_models_pct=10\n' > "$U/zz-old-spending.txt"; touch -t "$(date -v-30H +%Y%m%d%H%M)" "$U/zz-old-spending.txt"
echo "\$ fm-cursor-guard.sh fallback lab-bead -> $(g)"
echo
echo "=== 4. no spending file"
rm -f "$U/zz-old-spending.txt"
echo "\$ fm-cursor-guard.sh fallback lab-bead -> $(g)"
} > "$OUT" 2>&1
