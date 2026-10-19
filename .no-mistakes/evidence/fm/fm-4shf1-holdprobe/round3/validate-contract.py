import os, subprocess, json, importlib.util
from pathlib import Path
root=Path.cwd(); out=Path(__file__).parent
lab=root/".test-phase/contract"
env=dict(os.environ)
for k in list(env):
    if k.startswith(("FM_","TASKS_AXI_")): env.pop(k)
env.update(FM_HOME=str(lab), REVIEW_PAGE_HOME=str(lab/"pages"), DALE_RECORDS_DIR=str(lab/"records"), TMPDIR=str(root/".test-phase/contract-tmp"), PYTHONDONTWRITEBYTECODE="1")
Path(env["TMPDIR"]).mkdir(parents=True,exist_ok=True)
def run(*a):
    p=subprocess.run(list(map(str,a)),env=env,cwd=root,text=True,capture_output=True,check=True)
    return p.stdout
run(root/"bin/fm-lab-home.sh","create",lab)
(lab/".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
(lab/"data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
run(root/"bin/fm-captain-hold.sh","hold","signin","--title","Sign into disposable lab","--reason","sign in to the disposable service","--dale-step","sign-in","--probe",'test -f "$FM_HOME/signed-in"')
shown=run(root/"bin/fm-tasks-axi.sh","show","signin","--full")
body=json.loads(next(l[len("  body: "):] for l in shown.splitlines() if l.startswith("  body: ")))
spec=importlib.util.spec_from_file_location("hold_domain", "/Users/dalecarman/.agent-config/configs/claude/hooks/hold-domain.py")
consumer=importlib.util.module_from_spec(spec); spec.loader.exec_module(consumer)
parsed=consumer.parse_body(body)
assert isinstance(parsed,dict), parsed
assert parsed["owner"]=="dale" and parsed["timeout_s"]==3600 and parsed["reason"]=="sign in to the disposable service"
assert 'Hold probe: test -f "$FM_HOME/signed-in"' in body
(out/"current-hold-domain-contract.json").write_text(json.dumps({"command":"bin/fm-captain-hold.sh hold signin --dale-step sign-in -> bin/fm-tasks-axi.sh show signin --full -> real hold-domain.parse_body", "body":body,"parsed":parsed},default=str,indent=2)+"\n")
print("Real hold-domain consumer accepted the hold created at this head.")
