from pathlib import Path
import hashlib, json, os, shlex, subprocess, sys, tempfile

ROOT = Path("/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M4WGSNXGZXHFRVE1HA865TSN")
EVIDENCE = Path("/Users/dalecarman/.no-mistakes/evidence/01M4WGSNXGZXHFRVE1HA865TSN")
STATE = EVIDENCE / "promote-live-state.json"
LOG = EVIDENCE / "promote-live-transcript.txt"
BASE_ENV = os.environ.copy()
for k in ("FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "FM_GATE_REFUSE_BYPASS", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND", "CLAUDECODE", "PI_CODING_AGENT", "GROK_AGENT", "HERDR_ENV", "HERDR_SESSION", "HERDR_SOCKET_PATH", "FM_TASK_ID"):
    BASE_ENV.pop(k, None)
BASE_ENV.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")

def note(s):
    print(s, flush=True)
    with LOG.open("a") as f: f.write(s + "\n")

def run(args, cwd=ROOT, env=None, check=True):
    note("$ " + shlex.join(map(str,args)))
    cp = subprocess.run(list(map(str,args)), cwd=cwd, env=env or BASE_ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if cp.stdout: note(cp.stdout.rstrip())
    note("exit=" + str(cp.returncode))
    if check and cp.returncode: raise RuntimeError("command failed")
    return cp

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None

def observe(s, label):
    slot, repo = Path(s["slot"]), Path(s["repo"])
    obs = {"label":label,
        "slot_branch":run(["git","branch","--show-current"],cwd=slot).stdout.strip(),
        "slot_head":run(["git","rev-parse","HEAD"],cwd=slot).stdout.strip(),
        "slot_root":run(["git","rev-parse","--show-toplevel"],cwd=slot).stdout.strip(),
        "slot_status":run(["git","status","--porcelain"],cwd=slot).stdout.strip(),
        "primary_branch":run(["git","branch","--show-current"],cwd=repo).stdout.strip(),
        "primary_head":run(["git","rev-parse","HEAD"],cwd=repo).stdout.strip(),
        "primary_status":run(["git","status","--porcelain"],cwd=repo).stdout.strip(),
        "global_guard_unchanged":sha(Path("/Users/dalecarman/.claude/settings.json")) == s["guard_hash"],
        "global_cursor_config_unchanged":sha(Path("/Users/dalecarman/.cursor/cli-config.json")) == s.get("cursor_config_hash_before_isolation",s["cursor_config_hash"])}
    s.setdefault("observations",[]).append(obs)
    STATE.write_text(json.dumps(s,indent=2))
    note(json.dumps(obs,indent=2))
    return obs

phase=sys.argv[1]
if phase == "prepare":
    if STATE.exists(): raise RuntimeError("refusing to overwrite an existing lab record")
    lab=Path(tempfile.mkdtemp(prefix=".fm-promote-lab.",dir=ROOT))
    env=BASE_ENV.copy(); env["FM_HOME"]=str(lab)
    run([ROOT/"bin/fm-lab-home.sh","create",lab],env=env)
    repo=lab/"projects/promotion-fixture"; slot=lab/"slots/scout"
    run(["git","init","-q","--initial-branch=main",repo])
    run(["git","config","user.name","test"],cwd=repo)
    run(["git","config","user.email","test@example.com"],cwd=repo)
    run(["git","config","commit.gpgsign","false"],cwd=repo)
    (repo/"base.txt").write_text("Disposable promotion verification fixture.\n")
    (repo/"AGENTS.md").write_text("This is a disposable branch-promotion test fixture. Execute only the supplied branch and isolation checks. Do not edit files, publish, use no-mistakes, access other projects, change settings, or change credentials.\n")
    run(["git","add","base.txt","AGENTS.md"],cwd=repo)
    run(["git","-c","core.hooksPath=/dev/null","commit","-qm","fixture baseline"],cwd=repo)
    run(["git","worktree","add","--detach",slot,"HEAD"],cwd=repo)
    id="promote-live-pr9"
    run([ROOT/"bin/fm-brief.sh",id,"promotion-fixture","--scout"],env=env)
    brief=lab/"data"/id/"brief.md"
    text=brief.read_text().replace("{TASK}","Verify branch creation after promoting this disposable scout.").replace("{FIRSTMATE_SPEC}","Stay inside the disposable scout slot and report branch state. No implementation or delivery is requested in this fixture.")
    brief.write_text(text)
    (lab/"state"/(id+".meta")).write_text("window=fm-"+id+"\nkind=scout\nproject="+str(repo)+"\nworktree="+str(slot)+"\nharness=cursor\n")
    settings=Path("/Users/dalecarman/.claude/settings.json")
    rules=json.loads(settings.read_text()).get("permissions",{}).get("deny",[])
    relevant=[r for r in rules if any(t in r for t in ("git checkout", "git branch -c", "git branch -C"))]
    assert "Bash(git checkout -b *)" in relevant, "PR9 guard not enabled"
    s={"lab":str(lab),"repo":str(repo),"slot":str(slot),"id":id,"guard_hash":sha(settings),"cursor_config_hash":sha(Path("/Users/dalecarman/.cursor/cli-config.json")),"branch_creation_denies":relevant}
    STATE.write_text(json.dumps(s,indent=2))
    note("PR9 guard: "+json.dumps(relevant))
    observe(s,"before promotion")
else:
    s=json.loads(STATE.read_text()); lab=Path(s["lab"]); slot=Path(s["slot"]); id=s["id"]
    env=BASE_ENV.copy(); env["FM_HOME"]=str(lab)
    if s.get("isolated_cursor_config"):
        env["CURSOR_CONFIG_DIR"]=s["isolated_cursor_config"]
        env["CURSOR_DATA_DIR"]=str(lab/"cursor-data")
    if phase in ("deny","promote","relaunch"):
        if phase == "deny":
            prompt="Development-only permission-guard test in a disposable git slot. Invoke exactly one Shell tool call, command `git checkout -b fm/pr9-denied --`, with working_directory `"+str(slot)+"`. The existing deny policy should refuse it. Request the call; do not merely predict its result. Do not substitute any other command, change permissions, read other files, or create the branch another way. Report the tool outcome and stop."
        else:
            if phase == "promote":
                run([ROOT/"bin/fm-promote.sh",id,"--mode","no-mistakes","--yolo","off"],env=env)
                instructions=(lab/"data"/id/"ship-instructions.md").read_text()
                (EVIDENCE/"emitted-promotion-instructions.md").write_text(instructions)
            else:
                instructions=(lab/"data"/id/"brief.md").read_text()
                (EVIDENCE/"emitted-relaunch-brief.md").write_text(instructions)
            assert "git checkout -b" not in instructions, "generated contract names forbidden command"
            prompt="Development-only promotion evaluation. Your disposable task slot is `"+str(slot)+"`. Treat the generated instructions below as the promotion contract. Execute only the isolation checks, scratch inventory, and branch transition described by promotion steps 1 through 3, then report pwd, repository top level, current branch, HEAD, and git status. Preserve an already existing correct ship branch and its work. This run ends at branch verification: do not implement a change, invoke no-mistakes or any pipeline, publish, push, open PRs, contact others, change any settings or credentials, access any other project, or perform destructive operations. Explicitly set the Shell working_directory to the task slot on every call. Stop after reporting verification.\n\n"+instructions
        (EVIDENCE/(phase+"-cursor-prompt.txt")).write_text(prompt)
        args=["cursor-agent","--print","--output-format","stream-json","--trust","--force","--workspace",str(slot),"--",prompt]
        note("$ cursor-agent --print --output-format stream-json --trust --force --workspace "+shlex.quote(str(slot))+" -- <"+phase+"-cursor-prompt.txt>")
        outfile=EVIDENCE/(phase+"-cursor-stream.jsonl")
        with outfile.open("w") as f:
            try:
                cp=subprocess.run(args,cwd=slot,env=env,stdout=f,stderr=subprocess.STDOUT,text=True,timeout=180)
                s.setdefault("cursor_runs",{})[phase]={"exit":cp.returncode,"stream":str(outfile)}
            except subprocess.TimeoutExpired:
                s.setdefault("cursor_runs",{})[phase]={"exit":"timeout","stream":str(outfile)}
        STATE.write_text(json.dumps(s,indent=2))
        note("Cursor "+phase+" result: "+json.dumps(s["cursor_runs"][phase]))
        observe(s,"after "+phase)
    elif phase == "observe": observe(s,"final verification")
    else: raise RuntimeError("unknown phase")
