# Parses .github/workflows/ci.yml at the base (upstream-lean 9ed80766) and at
# HEAD into job models and compares the check names, timeouts, and serial shard
# matrix. Usage: python3 -I ci-jobs-compare.py <base.yml> <head.yml>
import sys, yaml
def jobs(path):
    doc = yaml.safe_load(open(path))
    out = {}
    for jid, j in doc["jobs"].items():
        name = j.get("name", jid)
        matrix = (j.get("strategy") or {}).get("matrix") or {}
        names = [name]
        if "${{" in name and matrix:
            # expand single-key matrix include lists for the rendered check names
            inc = matrix.get("include")
            keys = [k for k in matrix if k != "include"]
            rows = []
            if keys:
                import itertools
                for combo in itertools.product(*[matrix[k] for k in keys]):
                    rows.append(dict(zip(keys, combo)))
            if inc:
                rows += inc
            names = []
            for r in rows:
                n = name
                for k, v in r.items():
                    n = n.replace("${{ matrix.%s }}" % k, str(v))
                names.append(n)
        for n in names:
            out[n] = j.get("timeout-minutes")
    return out
b, h = jobs(sys.argv[1]), jobs(sys.argv[2])
print(f"base checks: {len(b)}  head checks: {len(h)}")
print("names identical:", sorted(b) == sorted(h))
print("timeouts identical:", b == h)
serial = sorted(n for n in h if n.startswith("Behavior portable serial"))
print(f"portable serial checks at head: {len(serial)} -> {serial}")
for n in sorted(h):
    print(f"  {h[n]!s:>4} min  {n}")
