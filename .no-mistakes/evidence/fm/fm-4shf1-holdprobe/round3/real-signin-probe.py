import os, subprocess, json, importlib.util
from pathlib import Path
root=Path.cwd(); out=Path(__file__).parent
lab=root/".test-phase/real-signin"
env=dict(os.environ)
for k in list(env):
    if k.startswith(("FM_","TASKS_AXI_")): env.pop(k)
env.update(FM_HOME=str(lab), REVIEW_PAGE_HOME=str(lab/"pages"), DALE_RECORDS_DIR=str(lab/"records"), TMPDIR=str(root/".test-phase/real-signin-tmp"), PYTHONDONTWRITEBYTECODE="1")
Path(env["TMPDIR"]).mkdir(parents=True,exist_ok=True)
def run(*a):
    p=subprocess.run(list(map(str,a)),env=env,cwd=root,text=True,capture_output=True,check=True)
    return p.stdout
run(root/"bin/fm-lab-home.sh","create",lab)
(lab/".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
(lab/"data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
run(root/"bin/fm-captain-hold.sh","hold","signin","--title","Sign into disposable lab","--reason","sign in to the disposable service","--dale-step","sign-in","--probe",'claude auth status >/dev/null 2>&1')
shown=run(root/"bin/fm-tasks-axi.sh","show","signin","--full")
body=json.loads(next(l[len("  body: "):] for l in shown.splitlines() if l.startswith("  body: ")))
spec=importlib.util.spec_from_file_location("hold_domain", "/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py")
consumer=importlib.util.module_from_spec(spec); spec.loader.exec_module(consumer)
parsed=consumer.parse_body(body)
assert isinstance(parsed,dict), parsed
assert parsed["owner"]=="dale" and parsed["timeout_s"]==3600 and parsed["reason"]=="sign in to the disposable service"
assert 'Hold probe: claude auth status >/dev/null 2>&1' in body
(out/"real-signin-hold-contract.json").write_text(json.dumps({"command":"bin/fm-captain-hold.sh hold signin --dale-step sign-in -> bin/fm-tasks-axi.sh show signin --full -> real hold-domain.parse_body", "body":body,"parsed":parsed},default=str,indent=2)+"\n")
print("Real hold-domain consumer accepted the hold created at this head.")

release=run(root/"bin/fm-captain-hold.sh","reprobe","signin")
final=run(root/"bin/fm-tasks-axi.sh","show","signin","--full")
(out/"real-signin-probe-transcript.txt").write_text("Before reprobe:\n"+shown+"\nProbe command: claude auth status >/dev/null 2>&1\n"+release+"\nAfter reprobe:\n"+final)
assert release.strip()=="released: signin", release
assert "held: no" in final and "Resolution mode: probe-released" in final
print("Real installed Claude authentication probe released the disposable sign-in hold; no credential changes.")
