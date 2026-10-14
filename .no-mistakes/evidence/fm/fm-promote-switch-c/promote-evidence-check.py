from pathlib import Path
import hashlib,json,subprocess

EVIDENCE=Path("/Users/dalecarman/.no-mistakes/evidence/01M4WGSNXGZXHFRVE1HA865TSN")
s=json.loads((EVIDENCE/"promote-live-state.json").read_text())
observations=s["observations"]
expected="fm/"+s["id"]
results={}
lines=[]
for phase,title in (("deny","PR 9 guard rejects checkout under the private Cursor configuration"),("promote","Promoted scout creates its ship branch"),("relaunch","Saved promoted brief preserves an existing branch and uncommitted work")):
    events=[]
    for raw in (EVIDENCE/(phase+"-cursor-stream.jsonl")).read_text().splitlines():
        try:e=json.loads(raw)
        except ValueError:continue
        events.append(e)
    completed=[]
    lines.append(title)
    for e in events:
        if e.get("type")=="tool_call" and e.get("subtype")=="completed":
            for kind,call in e.get("tool_call",{}).items():
                if not isinstance(call,dict) or "args" not in call:continue
                rec={"tool":kind,"command":call["args"].get("command"),"working_directory":call["args"].get("workingDirectory"),"result":call.get("result")}
                completed.append(rec)
                lines.append("$ "+str(rec["command"]))
                lines.append("cwd: "+str(rec["working_directory"]))
                result=rec["result"] or {}
                if "permissionDenied" in result:
                    lines.append("DENIED: "+result["permissionDenied"].get("error",""))
                elif "success" in result:
                    outcome=result["success"]
                    lines.append("exit="+str(outcome.get("exitCode")))
                    lines.append(outcome.get("stdout","").rstrip())
                    if outcome.get("stderr"):lines.append(outcome["stderr"].rstrip())
                else:lines.append(json.dumps(result))
        if e.get("type")=="result":
            assert not e.get("is_error"), phase+" agent reported an error"
            lines.append("Cursor report: "+e.get("result",""))
    assert completed, phase+" has no completed real tool calls"
    assert any(e.get("type")=="result" for e in events),phase+" has no final result"
    if phase=="deny":
        assert len(completed)==1
        assert completed[0]["command"]=="git checkout -b fm/pr9-denied --"
        assert "permissionDenied" in completed[0]["result"]
    else:
        assert all("success" in c["result"] for c in completed),phase+" had a failed tool call"
        assert all(c["result"]["success"].get("exitCode")==0 for c in completed)
    results[phase]={"completed_tool_calls":completed,"agent_exit":s["cursor_runs"][phase]["exit"]}
    assert results[phase]["agent_exit"]==0
    lines.append("")

promoted=next(o for o in observations if o["label"]=="after promote")
resumed=next(o for o in observations if o["label"]=="after relaunch")
assert promoted["slot_branch"]==expected
assert promoted["slot_status"]==""
assert promoted["slot_root"]==s["slot"]
assert resumed["slot_branch"]==expected
assert resumed["slot_head"]==s["expected_existing_work"]["head"]
work=Path(s["slot"])/s["expected_existing_work"]["path"]
assert hashlib.sha256(work.read_bytes()).hexdigest()==s["expected_existing_work"]["sha256"]
assert all(o["primary_branch"]=="main" and o["primary_status"]=="" and o["primary_head"]==observations[0]["primary_head"] for o in observations)
assert all(o["global_guard_unchanged"] for o in observations)
assert hashlib.sha256(Path("/Users/dalecarman/.claude/settings.json").read_bytes()).hexdigest()==s["guard_hash"]
assert observations[-1]["slot_branch"]==expected
assert observations[-1]["slot_status"]=="M base.txt"
for name in ("emitted-promotion-instructions.md","emitted-relaunch-brief.md"):
    # These are emitted, delivered prompt contracts, not implementation source.
    assert "git checkout -b" not in (EVIDENCE/name).read_text()
(EVIDENCE/"retained-fixture-work.txt").write_bytes(work.read_bytes())
(EVIDENCE/"cursor-replay-transcript.txt").write_text("\n".join(lines)+"\n")
meta=Path(s["lab"])/"state"/(s["id"]+".meta")
(EVIDENCE/"promoted-task-state.meta").write_text(meta.read_text())
final={"guard_denies":s["branch_creation_denies"],"observed_states":observations,"retained_work_sha256":s["expected_existing_work"]["sha256"],"cursor_results":results,"normal_config_initial_launch_side_effect":s["normal_config_initial_launch_side_effect"],"assertions":"All three live replay scenarios passed; primary fixture and PR9 settings were unchanged."}
(EVIDENCE/"promotion-observed-state.json").write_text(json.dumps(final,indent=2))
print("Verified real permission denial, promotion branch/root, unchanged primary, retained HEAD and work, and unchanged PR9 settings.")
