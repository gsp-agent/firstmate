import json
import os
from pathlib import Path
import subprocess

out = Path(__file__).parent
auth = subprocess.run(["gh", "auth", "token", "--user", "gsp-agent"], text=True, capture_output=True)
if auth.returncode or not auth.stdout.strip():
    (out / "github-access.txt").write_text("gsp-agent GitHub login unavailable; read-only event replay could not be fetched.\n")
    raise SystemExit(1)
env = dict(os.environ, GH_TOKEN=auth.stdout.strip())
numbers = [3941, 3950, 3939, 4006, 4017, 4111, 4172, 4183, 4200, 4308]
fields = " ".join(
    f"p{n}:pullRequest(number:{n}){{number url state merged isInMergeQueue headRefOid "
    "timelineItems(last:100,itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT,ADDED_TO_MERGE_QUEUE_EVENT])"
    "{pageInfo{hasPreviousPage startCursor}nodes{__typename "
    "... on RemovedFromMergeQueueEvent{id reason createdAt}"
    "... on AddedToMergeQueueEvent{id createdAt}}}}"
    for n in numbers
)
query = 'query{repository(owner:"groovejones",name:"groove-sight-platform"){' + fields + '}}'
result = subprocess.run(["gh", "api", "graphql", "--hostname", "github.com", "-f", "query=" + query], env=env, text=True, capture_output=True)
(out / "github-events.stderr.txt").write_text(result.stderr)
if result.returncode:
    (out / "github-access.txt").write_text("Read-only GitHub GraphQL request failed: " + result.stderr)
    raise SystemExit(result.returncode)
data = json.loads(result.stdout)
(out / "github-events.json").write_text(json.dumps(data, indent=2) + "\n")
for pr in data["data"]["repository"].values():
    events = pr["timelineItems"]["nodes"]
    print(json.dumps({"number": pr["number"], "state": pr["state"], "merged": pr["merged"], "queued": pr["isInMergeQueue"], "latest_queue_event": events[-1] if events else None}, ensure_ascii=False))
