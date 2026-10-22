import os, subprocess, time, json
from pathlib import Path
root=Path.cwd()
evidence=Path("/Users/dalecarman/.no-mistakes/evidence/01M5H6NCKQJM2YC31BBNGTSVQQ")
env=dict(os.environ, TMPDIR=str(root/".test-phase-r6/tmp"), TMP=str(root/".test-phase-r6/tmp"), FM_TEST_SKIP_ORPHAN_REAP="1", FM_TEST_MACHINE_GATE="")
for key in ("FM_HOME", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "FM_TEST_ONLY", "FM_TEST_MACHINE_LINE_HELD"):
    env.pop(key,None)
cases=[("summary",["bash","tests/fm-home-summary-refresh.test.sh"],{}),
       ("proof-owner",["bash","tests/fm-test-isolation-proof.test.sh"],{}),
       ("timeout",["bash","tests/fm-timeout-lib.test.sh"],{})]
for name in ("test_provably_working_signal_absorbed", "test_turn_ended_not_working_surfaced", "test_actionable_signal_surfaced", "test_actionable_signal_survives_a_later_routine_append", "test_term_stops_a_watcher_blocked_inside_a_poll", "test_term_stops_a_watcher_whose_cleanup_marker_lock_is_held", "test_check_sweep_reprobes_captain_holds"):
    cases.append((name,["bash","tests/fm-watch-triage.test.sh"],{"FM_TEST_ONLY":name}))
results=[]
for name,cmd,extra in cases:
    print("START "+name,flush=True)
    started=time.monotonic()
    with (evidence/(name+"-r6.log")).open("w") as out:
        r=subprocess.run(cmd,env=dict(env,**extra),stdout=out,stderr=subprocess.STDOUT)
    result=dict(name=name,command=cmd,env=extra,rc=r.returncode,elapsed=round(time.monotonic()-started,3))
    results.append(result)
    (evidence/"targeted-results-r6.json").write_text(json.dumps(results,indent=2)+"\n")
    print(json.dumps(result),flush=True)
print("DONE",flush=True)
