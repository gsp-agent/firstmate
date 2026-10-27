#!/usr/bin/env bash
# Probe: what makes real Treehouse 2.3.0 report a pool slot in-use after a
# lease is returned, and when a free claimed-clean slot is handed out.
set -u
real_th=$(command -v treehouse)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "${LAB:?}"' EXIT
G=(-c user.name=lab -c user.email=lab@example.invalid -c init.defaultBranch=main)
git "${G[@]}" init -q --bare "$LAB/o.git"
git "${G[@]}" clone -q "$LAB/o.git" "$LAB/proj" 2>/dev/null
echo a > "$LAB/proj/a"; git -C "$LAB/proj" add a; git "${G[@]}" -C "$LAB/proj" commit -qm a; git -C "$LAB/proj" push -q origin HEAD:main
git -C "$LAB/proj" remote set-head origin -a >/dev/null 2>&1
th() { (cd "$LAB/proj" && env HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool" "$real_th" "$@"); }
st() { th status --json 2>/dev/null | jq -c '.[] | {name, status}'; jq -c '.worktrees[] | {name, leased, lease_holder, owner_pid}' "$LAB"/pool/.treehouse/*/treehouse-state.json; }
slot=$(th get --lease --lease-holder setup --no-fetch 2>/dev/null)
echo "after get --lease (caller pid $$):"; st
th return --if-lease-holder setup "$slot" >/dev/null 2>&1
echo "after return:"; st
echo "processes with cwd in the slot:"
for p in $(lsof -t +D "$slot" 2>/dev/null | sort -u); do ps -p "$p" -o pid=,comm=; done
( cd "$slot" && nohup sleep 300 >/dev/null 2>&1 & echo $! > "$LAB/pid" )
sleep 1; echo "with a sleeper in it:"; th status --json 2>/dev/null | jq -c '.[] | {name, status}'
kill "$(cat "$LAB/pid")"; sleep 0.5
kill -0 "$(cat "$LAB/pid")" 2>/dev/null && echo "sleeper still alive" || echo "sleeper gone"
echo "processes holding the slot now:"; for p in $(lsof -t +D "$slot" 2>/dev/null | sort -u); do ps -p "$p" -o pid=,ppid=,stat=,comm=; done
echo "after the sleeper ended:"; th status --json 2>/dev/null | jq -c '.[] | {name, status}'
jq -c '.worktrees[] | {name, leased, owner_pid, owner_started_at}' "$LAB"/pool/.treehouse/*/treehouse-state.json
echo "get --lease now hands out: $(th get --lease --lease-holder probe --no-fetch 2>/dev/null | sed "s#$LAB/##")"
