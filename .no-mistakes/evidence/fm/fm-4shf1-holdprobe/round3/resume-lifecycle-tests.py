import os, subprocess, json, time, signal
from pathlib import Path
root=Path.cwd(); out=Path(__file__).parent
env=dict(os.environ)
for k in list(env):
    if k.startswith(("FM_","TASKS_AXI_")): env.pop(k)
tmp=root/".test-phase/resume-tmp"; tmp.mkdir(parents=True,exist_ok=True)
env.update(TMPDIR=str(tmp), PYTHONDONTWRITEBYTECODE="1", FM_BACKLOG_ROW_TIMEOUT_SECS="60")
results=[]
for name in ("test_reprobe_release_retries_finalize_one_occurrence", "test_failed_and_unknown_probes_do_not_notify_the_parent"):
    start=time.monotonic()
    with (out/(name+".log")).open("w") as log:
        log.write("$ FM_TEST_ONLY="+name+" bash tests/.validation-lifecycle-selection.test.sh\n"); log.flush()
        child=subprocess.Popen(["bash","tests/.validation-lifecycle-selection.test.sh"],env=dict(env,FM_TEST_ONLY=name),cwd=root,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try: rc=child.wait(timeout=1800)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGTERM); child.wait(timeout=20); rc=124
    row={"name":name,"status":rc,"seconds":round(time.monotonic()-start,2)}
    results.append(row); print(json.dumps(row),flush=True)
(out/"resumed-lifecycle-results.json").write_text(json.dumps(results,indent=2)+"\n")
