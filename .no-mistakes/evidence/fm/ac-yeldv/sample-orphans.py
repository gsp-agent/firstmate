from pathlib import Path
import json, os, subprocess, threading, time
root=Path.cwd()
evidence=Path("/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH")
f=json.loads((evidence/"fixture.json").read_text())
env=os.environ.copy()
for k in list(env):
    if k.startswith(("FM_","GIT_","TASKS_AXI_")):
        env.pop(k)
env.update(json.loads((evidence/"isolated-env.json").read_text()))
started=time.monotonic()
deadline=started+600
reads=[]
orphans=[]
observed=[]
stop=threading.Event()
def crew_reads():
    while time.monotonic()<deadline:
        began=time.monotonic()
        try:
            p=subprocess.run(["bash","bin/fm-crew-state.sh","lab-yeldv"],cwd=root,env=env,capture_output=True,text=True,timeout=90)
            row={"at_seconds":round(began-started,3),"elapsed_seconds":round(time.monotonic()-began,3),"exit":p.returncode,"stdout":p.stdout.strip(),"stderr":p.stderr.strip()}
        except subprocess.TimeoutExpired as ex:
            row={"at_seconds":round(began-started,3),"error":"outer 90s timeout","stdout":str(ex.stdout)}
        reads.append(row)
        with (evidence/"ten-minute-crew-reads.jsonl").open("a") as log:
            log.write(json.dumps(row)+"\n")
        print(json.dumps(row),flush=True)
        stop.wait(max(0,30-(time.monotonic()-began)))
t=threading.Thread(target=crew_reads)
t.start()
samples=0
with (evidence/"ten-minute-orphan-samples.jsonl").open("w") as log:
    while time.monotonic()<deadline:
        tick=time.monotonic()
        ps=subprocess.run(["ps","-axo","pid=,ppid=,pgid=,comm=,args="],capture_output=True,text=True,check=True).stdout
        matches=[]
        for line in ps.splitlines():
            if "cat-file" not in line or f["head"][:8] not in line:
                continue
            parts=line.split(None,4)
            if len(parts)!=5:
                continue
            pid,ppid,pgid,comm,args=parts
            if "git" not in comm:
                continue
            row={"pid":int(pid),"ppid":int(ppid),"pgid":int(pgid),"command":args}
            matches.append(row)
            if int(ppid)==1:
                orphans.append(row)
        observed.extend(matches)
        samples+=1
        log.write(json.dumps({"at_seconds":round(tick-started,3),"cat_file":matches})+"\n")
        log.flush()
        stop.wait(max(0,min(1-(time.monotonic()-tick),deadline-time.monotonic())))
t.join(timeout=95)
summary={"elapsed_seconds":round(time.monotonic()-started,3),"samples":samples,"crew_reads":len(reads),"all_reads_show_review_gate":all(r.get("exit")==0 and "state: parked" in r.get("stdout","") and "parked at review: 1 finding(s)" in r.get("stdout","") for r in reads),"observed_cat_file_instances":len(observed),"orphan_cat_file_instances":len(orphans),"scope":"Only the disposable lab head; operator fleet untouched","orphans":orphans}
(evidence/"ten-minute-summary.json").write_text(json.dumps(summary,indent=2))
print(json.dumps(summary),flush=True)
