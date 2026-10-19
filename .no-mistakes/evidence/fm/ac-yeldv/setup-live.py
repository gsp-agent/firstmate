from pathlib import Path
import json, os, subprocess, sqlite3, time
root=Path.cwd()
scratch=root/".nm-live-yeldv"
evidence=Path("/Users/dalecarman/.no-mistakes/evidence/01M5AP7AKEK9SQ3DD71N7F0RCH")
env=os.environ.copy()
for k in list(env):
    if k.startswith(("FM_","GIT_","TASKS_AXI_")):
        env.pop(k)
env.update(json.loads((evidence/"isolated-env.json").read_text()))
def run(args,cwd=root,extra=None):
    p=subprocess.run(args,cwd=cwd,env=env|dict(extra or {}),text=True,capture_output=True,timeout=30)
    if p.returncode:
        raise RuntimeError(str(args)+"\n"+p.stdout+p.stderr)
    return p.stdout.strip()
seed=scratch/"seed"
remote=scratch/"origin.git"
slot=scratch/"slot"
run(["git","clone","-q","--bare",str(seed),str(remote)])
run(["git","-C",str(remote),"config","uploadpack.allowFilter","true"])
run(["git","clone","-q","--filter=blob:none",remote.as_uri(),str(slot)])
run(["git","-C",str(slot),"switch","-qc","fm/lab-yeldv"])
submitted=run(["git","-C",str(slot),"rev-parse","HEAD"])
run(["git","-C",str(seed),"switch","-qc","fm/lab-yeldv"])
(seed/"pipeline-only.txt").write_text("pipeline fix not pushed to origin\n")
run(["git","-C",str(seed),"add","pipeline-only.txt"])
run(["git","-C",str(seed),"-c","user.name=gsp-agent","-c","user.email=gsp-agent@users.noreply.github.com","commit","-qm","pipeline-only fix"])
head=run(["git","-C",str(seed),"rev-parse","HEAD"])
repo_id="f1ab00000001"
run(["git","clone","-q","--bare",str(seed),str(scratch/"nm-home"/"repos"/(repo_id+".git"))])
run(["git","-C",str(slot),"remote","add","no-mistakes",str(scratch/"nm-home"/"repos"/(repo_id+".git"))])
now=int(time.time()*1000)
run_id="01M5APP0000000000000000001"
finding={"id":"LAB1","severity":"warning","file":"payload.txt","line":1,"description":"Disposable review decision retained for missing-head proof","action":"ask-user"}
with sqlite3.connect(scratch/"nm-home"/"state.sqlite") as db:
    db.execute("INSERT INTO repos(id,working_path,upstream_url,default_branch,created_at) VALUES (?,?,?,?,?)",(repo_id,str(slot),remote.as_uri(),"main",now))
    db.execute("INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,submitted_head_sha,worktree_dir,status,awaiting_agent_since,created_at,updated_at,intent) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",(run_id,repo_id,"fm/lab-yeldv",head,submitted,submitted,str(seed),"running",now,now,now,"Disposable live validation record; no pipeline was started"))
    db.execute("INSERT INTO step_results(id,run_id,step_name,step_order,status,findings_json,started_at) VALUES (?,?,?,?,?,?,?)",("lab-review",run_id,"review",1,"awaiting_approval",json.dumps([finding]),now))
run([str(root/"bin/fm-lab-home.sh"),"create",env["FM_HOME"]])
meta=Path(env["FM_HOME"])/"state"/"lab-yeldv.meta"
meta.write_text("worktree="+str(slot)+"\nproject="+str(slot)+"\nkind=ship\nbranch=fm/lab-yeldv\nmode=no-mistakes\n")
config={"scratch":str(scratch),"slot":str(slot),"seed":str(seed),"remote":str(remote),"head":head,"submitted":submitted,"run_id":run_id,"repo_id":repo_id}
(evidence/"fixture.json").write_text(json.dumps(config,indent=2))
print(json.dumps(config,indent=2))
p=subprocess.run(["no-mistakes","axi","status"],cwd=slot,env=env|{"GIT_NO_LAZY_FETCH":"1"},text=True,capture_output=True,timeout=25)
print("status exit="+str(p.returncode)+"\n"+p.stdout+p.stderr)
(evidence/"initial-status.toon").write_text(p.stdout+p.stderr)
