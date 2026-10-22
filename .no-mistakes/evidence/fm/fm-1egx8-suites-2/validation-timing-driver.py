import json, os, subprocess, sys, time
from pathlib import Path
marker=Path(os.environ['FM_TEST_VALIDATION_MARKER'])
start=time.time()
proc=subprocess.Popen(sys.argv[1:])
seen=None
while proc.poll() is None:
    if seen is None and marker.exists():
        seen=marker.stat().st_mtime
    time.sleep(0.01)
end=time.time()
if seen is None and marker.exists(): seen=marker.stat().st_mtime
record={'command':sys.argv[1:], 'returncode':proc.returncode, 'start_epoch':start, 'marker_epoch':seen, 'end_epoch':end, 'before_marker_seconds':None if seen is None else seen-start, 'after_marker_seconds':None if seen is None else end-seen, 'total_seconds':end-start}
Path(os.environ['FM_PHASE_TIMING_JSON']).write_text(json.dumps(record, indent=2)+'\n')
print('VALIDATION_TIMING '+json.dumps(record), flush=True)
sys.exit(proc.returncode)
