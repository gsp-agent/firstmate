"""Print every waker/Stop-hook wake banner a Claude session transcript shows
delivered to the model, with its timestamp.
Usage: python3 -I extract-wake-banners.py <session.jsonl>"""
import json
import sys


def texts(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from texts(item)
    elif isinstance(node, dict):
        for key in ("content", "text"):
            if key in node:
                yield from texts(node[key])


seen = set()
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") not in ("user", "attachment", "system"):
            continue
        blob = entry.get("message", entry.get("attachment", entry))
        for text in texts(blob):
            if "firstmate watcher wake" not in text:
                continue
            start = text.find("firstmate watcher wake")
            end = text.find("after an ordinary wake.", start)
            body = text[start:end + len("after an ordinary wake.")] if end != -1 else text[start:]
            if body in seen:
                continue
            seen.add(body)
            print("=== delivered to main at %s (%s)" % (entry.get("timestamp", "?"), entry.get("type")))
            print(body)
