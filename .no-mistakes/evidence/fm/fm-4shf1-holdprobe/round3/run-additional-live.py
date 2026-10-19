import os, subprocess, json
from pathlib import Path
p=Path(__file__).parent
for stage in ("normalize", "verify", "retire"):
    env=dict(os.environ, LIVE_CASE_NAME="round3-"+stage, LIVE_FAILURE_STAGE=stage)
    r=subprocess.run(["python3", str(p/"live-holds.py"), "interrupted_publish"], env=env)
    print(json.dumps({"stage":stage, "driver_exit":r.returncode}),flush=True)
