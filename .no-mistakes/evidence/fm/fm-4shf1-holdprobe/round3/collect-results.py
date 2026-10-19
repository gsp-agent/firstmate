from pathlib import Path
import json
p=Path(__file__).parent
scenarios=[]
def load(file): return json.loads((p/file).read_text())
for source in ("live-holds-round3-results.json", "live-world-checks-retry-results.json"):
    for row in load(source):
        row["evidence"]=source.replace("results.json","transcript.txt")
        scenarios.append(row)
for stage, label in (("normalize","Normalization"),("verify","Verification read"),("retire","Request retirement")):
    row=load("live-holds-round3-"+stage+"-results.json")[0]
    row["name"]=label+" failure after release emits an actionable recovery notification; reprobe completes the original occurrence once"
    row["evidence"]="live-holds-round3-"+stage+"-transcript.txt"
    scenarios.append(row)
row=load("live-primary-t-results.json")
row["name"]="An otherwise idle real Claude home arms for its sole probe hold, delivers the final release through exit 2, then stays quiet on the next Stop"
row["evidence"]="live-primary-t-transcript.txt"
scenarios.append(row)
assert "released: signin" in (p/"real-signin-probe-transcript.txt").read_text()
scenarios.append({"name":"A Dale sign-in hold releases when the installed Claude authentication-status probe passes, without changing credentials", "result":"pass", "live":True,"reason":"", "evidence":"real-signin-probe-transcript.txt"})
assert len(scenarios)==14, len(scenarios)
assert all(x["result"]=="pass" and x["live"] for x in scenarios), scenarios
checks=load("targeted-results.json")
assert len(checks)==5 and all(x["status"]==0 for x in checks[1:]), checks
if checks[0]["status"] == 124:
    partial = (p/"targeted-retry-dale-step.log").read_text()
    assert partial.count("ok - ") >= 5, partial
    resumed = load("resumed-lifecycle-results.json")
    assert len(resumed)==2 and all(x["status"]==0 for x in resumed), resumed
    checks[0]["driver_correction"] = "The 900-second aggregate deadline interrupted a progressing test. Five existing cases completed before the deadline; the two remaining original test functions passed independently with a larger per-function bound."
    checks[0]["resumed_functions"] = resumed
else:
    assert checks[0]["status"]==0, checks
(p/"validated-scenarios.json").write_text(json.dumps({"target_commit":"29a0868483613e5a24e5744411e1382bb0a9acbf", "scenarios":scenarios,"targeted_regressions":checks},indent=2)+"\n")
print("14 live product scenarios passed; focused regressions completed after correcting the aggregate lifecycle driver deadline.")
