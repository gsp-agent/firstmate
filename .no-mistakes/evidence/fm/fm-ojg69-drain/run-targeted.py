import json, os, pathlib, shlex, subprocess, tempfile, time
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path("/Users/dalecarman/.no-mistakes/evidence/01M5BV5GQB0KD20X4J2BKKMYVX")
WORK=pathlib.Path(tempfile.mkdtemp(prefix=".phase-targeted-", dir=ROOT))
(WORK/"tmp").mkdir()
env=os.environ.copy()
for key in list(env):
    if key.endswith("_OVERRIDE") and key.startswith("FM_") or key in ("FM_HOME", "FM_TASK_ID", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND", "BEADS_DIR", "BEADS_DB", "BR_DB"):
        env.pop(key,None)
env["TMPDIR"]=str(WORK/"tmp")
commands=[("cleanup-regressions", ["bin/fm-test-run.sh", "--per-script-timeout-secs", "600", "tests/fm-teardown.test.sh"], {"FM_TEARDOWN_TEST_GROUP":"task-data-review"}), ("accepted-runtime-fixes", ["bin/fm-test-run.sh", "--per-script-timeout-secs", "600", "tests/fm-drift-nightly.test.sh", "tests/fm-dispatch-resolve.test.sh", "tests/fm-secondmate-liveness.test.sh"], {})]
results=[]
for name,cmd,extra in commands:
    started=time.monotonic()
    with (EVID/(name+".log")).open("w") as log:
        log.write("$ "+shlex.join(cmd)+"\n"); log.flush()
        done=subprocess.run(cmd,cwd=ROOT,env={**env,**extra},stdout=log,stderr=subprocess.STDOUT)
    row={"name":name,"command":shlex.join(cmd),"env":extra,"exit":done.returncode,"seconds":round(time.monotonic()-started,2)}
    results.append(row)
    print(json.dumps(row),flush=True)
(EVID/"targeted-results.json").write_text(json.dumps({"work":str(WORK),"results":results},indent=2)+"\n")
