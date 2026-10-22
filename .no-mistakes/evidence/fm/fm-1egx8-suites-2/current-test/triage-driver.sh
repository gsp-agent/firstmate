#!/usr/bin/env bash
set -u
SCENARIO=$1
export FM_TEST_ONLY=drive_and_record
drive_and_record() {
  "$SCENARIO"
  python3 - "$TMP_ROOT" "$EVIDENCE_ROOT/$SCENARIO-state.json" <<'CAPTURE'
from pathlib import Path
import json, sys
root=Path(sys.argv[1]); records={}
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    if path.name in ('.wake-queue','.watch-triage.log','watch.out','watch.err','out','backlog.md') or path.name.startswith('.seen-'):
        if path.stat().st_size < 200000: records[str(path.relative_to(root))]=path.read_text(errors='replace')
Path(sys.argv[2]).write_text(json.dumps(records,indent=2)+'\n')
CAPTURE
}
. "$PWD/tests/fm-watch-triage.test.sh"
