#!/usr/bin/env bash
# alone-run.sh <tests/suite.test.sh>: run one suite alone through the real
# bin/fm-test-run.sh, ungated (FM_TEST_MACHINE_GATE='') because another
# session held the machine turn for up to 90 minutes, sampling 1-min load, swap and
# swapouts every 2s and process RSS every 10s, then checking for test-spawned
# survivors and Claude store writes. Writes a summary into the evidence dir.
set -u
suite=$1
EV=/Users/dalecarman/.no-mistakes/evidence/01M55Y5XKTJTJD73274HVHFNG1
WT=/Users/dalecarman/.no-mistakes/worktrees/a5e67f4ea77f/01M55Y5XKTJTJD73274HVHFNG1
name=$(basename "$suite" .test.sh)
out="$EV/$name"
mkdir -p "$out"
RUNTMP=$(mktemp -d "/tmp/fm-alone-$name.XXXXXX")
RUNTMP=$(cd "$RUNTMP" && pwd -P)
SCRATCH=$(mktemp -d "/tmp/fm-alone-scratch-$name.XXXXXX")

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
swapused() { sysctl -n vm.swapusage | awk '{print $6}'; }
swapouts() { vm_stat | awk '/Swapouts/ {gsub(/\./,"",$2); print $2}'; }
store_sum() { [ -f "$1" ] && shasum "$1" | awk '{print $1}' || echo absent; }
procs() {
  ps -axo pid=,pgid=,ppid=,etime=,command= \
    | grep -E 'fm-watch\.sh|fm-watch-arm\.sh|fm-home-summary|fm-fleet-snapshot|fm-crew-state' \
    | grep -v -E 'grep -E' \
    | grep -E "$WT|$RUNTMP|fm-alone-$name" || true
}

HOME_STORE="$HOME/.claude.json"
CONF_STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
pre_load=$(load1); pre_swap=$(swapused); pre_so=$(swapouts)
pre_home=$(store_sum "$HOME_STORE"); pre_conf=$(store_sum "$CONF_STORE")
procs >"$out/procs-before.txt"

(
  n=0
  while :; do
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(load1)" "$(swapused)" "$(swapouts)" >>"$out/samples.tsv"
    if [ $((n % 5)) -eq 0 ]; then
      { echo "@@ $(date +%s)"; ps -axo rss=,pid=,comm= ; } >>"$SCRATCH/rss.log"
    fi
    n=$((n + 1))
    sleep 2
  done
) &
sampler=$!

start=$(date +%s)
echo "start $(date -u +%FT%TZ) load1=$pre_load swap_used=$pre_swap swapouts=$pre_so" >"$out/summary.txt"
cd "$WT" || exit 2
FM_TEST_MACHINE_GATE= TMPDIR="$RUNTMP" bin/fm-test-run.sh "$suite" --json "$out/run.json" >"$out/run.log" 2>&1
rc=$?
end=$(date +%s)
sleep 3
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null

post_load=$(load1); post_swap=$(swapused); post_so=$(swapouts)
post_home=$(store_sum "$HOME_STORE"); post_conf=$(store_sum "$CONF_STORE")
procs >"$out/procs-after.txt"
peak=$(awk -F'\t' 'BEGIN{m=0} {if ($2+0>m) m=$2+0} END{print m}' "$out/samples.tsv")
leak_home=$(grep -c -F "fm-alone-$name" "$HOME_STORE" 2>/dev/null || true)
leak_conf=$(grep -c -F "fm-alone-$name" "$CONF_STORE" 2>/dev/null || true)
killed=$(grep -c -E 'Killed: 9|watcher-exit timeout|did not exit' "$out/run.log" || true)
left=$(find "$RUNTMP" -mindepth 1 -maxdepth 1 2>/dev/null | sed "s|$RUNTMP/||" | sort | sed -E 's/\.[A-Za-z0-9]{6,}$/.*/' | uniq -c | tr '\n' ';')

python3 -I - "$SCRATCH/rss.log" "$out/samples.tsv" >"$out/rss-growers.txt" <<'PY'
import sys
snaps = []
cur = None
for line in open(sys.argv[1]):
    if line.startswith("@@ "):
        cur = (int(line.split()[1]), {})
        snaps.append(cur)
        continue
    p = line.split(None, 2)
    if len(p) == 3 and cur is not None:
        cur[1][p[1]] = (int(p[0]), p[2].strip())
samples = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip()]
windows = []
for a, b in zip(samples, samples[1:]):
    if int(b[3]) > int(a[3]):
        windows.append((int(a[0]), int(b[0]), int(b[3]) - int(a[3])))
print("swapout windows (start end delta_pages):", len(windows))
for w in windows[:20]:
    print("  ", *w)
def growers(t0, t1):
    s0 = max([s for s in snaps if s[0] <= t0] or snaps[:1], key=lambda s: s[0])
    s1 = min([s for s in snaps if s[0] >= t1] or snaps[-1:], key=lambda s: s[0])
    g = []
    for pid, (rss, comm) in s1[1].items():
        before = s0[1].get(pid, (0, comm))[0]
        g.append((rss - before, pid, comm, rss))
    g.sort(reverse=True)
    return s0[0], s1[0], g[:10]
if snaps:
    spans = [(w[0], w[1]) for w in windows] or [(snaps[0][0], snaps[-1][0])]
    t0 = min(s[0] for s in spans); t1 = max(s[1] for s in spans)
    a, b, g = growers(t0, t1)
    print(f"top RSS growers between snapshots {a} and {b} ({'swap window' if windows else 'whole run'}):")
    for d, pid, comm, rss in g:
        print(f"  +{d/1024:.0f} MiB  pid {pid}  now {rss/1024:.0f} MiB  {comm}")
PY
echo "$SCRATCH" >>/tmp/fm-alone-cleanup.list

{
  echo "suite=$suite rc=$rc wall=$((end - start))s"
  echo "load1: pre=$pre_load peak=$peak post=$post_load limit=$(awk -v p="$pre_load" 'BEGIN{print p+100}') ok=$(awk -v p="$pre_load" -v k="$peak" 'BEGIN{print (k<=p+100)?"yes":"no"}')"
  echo "swap used: pre=$pre_swap post=$post_swap ; swapouts: pre=$pre_so post=$post_so delta=$((post_so - pre_so))"
  echo "~/.claude.json sha: pre=$pre_home post=$post_home same=$([ "$pre_home" = "$post_home" ] && echo yes || echo no) ; fixture-path keys=$leak_home"
  echo "\$CLAUDE_CONFIG_DIR/.claude.json sha: pre=$pre_conf post=$post_conf same=$([ "$pre_conf" = "$post_conf" ] && echo yes || echo no) ; fixture-path keys=$leak_conf"
  echo "test-spawned watcher/summary/snapshot survivors after run: $(grep -c . "$out/procs-after.txt" || true) (before: $(grep -c . "$out/procs-before.txt" || true))"
  echo "Killed:9 / watcher-exit-timeout lines in run.log: $killed"
  echo "runner tail: $(grep -E 'FM_TEST_END|passed=|failed=' "$out/run.log" | tail -2 | tr '\n' ' ')"
  echo "TMPDIR top-level leftovers: ${left:-none}"
} >>"$out/summary.txt"
echo "$RUNTMP" >>/tmp/fm-alone-cleanup.list
cat "$out/summary.txt"
