#!/usr/bin/env bash
# Drives bin/fm-test-run.sh --list --changed: on the real branch, then in a
# disposable copy of HEAD with one change set at a time, and reports how many
# times the supervision-host cases would run (subject = every case; each
# lane wrapper = its half).
set -u
wt=$1 scratch=$2
R=bin/fm-test-run.sh
sh_files() { grep -x -e tests/fm-supervision-host.test.sh -e 'tests/fm-supervision-host-lane-[ab].test.sh' || true; }
report() { # <listed>
  local listed=$1 subj a b
  subj=$(printf '%s\n' "$listed" | grep -cx tests/fm-supervision-host.test.sh)
  a=$(printf '%s\n' "$listed" | grep -cx tests/fm-supervision-host-lane-a.test.sh)
  b=$(printf '%s\n' "$listed" | grep -cx tests/fm-supervision-host-lane-b.test.sh)
  printf '  supervision-host files selected: %s\n' "$(printf '%s\n' "$listed" | sh_files | tr '\n' ' ')"
  printf '  afk family members selected: %s\n' "$(printf '%s\n' "$listed" | grep -c -e fm-afk-contract.test.sh -e fm-afk-inject-e2e.test.sh -e fm-afk-return.test.sh -e fm-host-mirror.test.sh)"
  printf '  lane-a cases run %s time(s), lane-b cases run %s time(s)\n' "$((subj + a))" "$((subj + b))"
}
echo "== real branch: --changed --base 9ed80766 (this PR's own diff)"
listed=$(cd "$wt" && $R --list --changed --base 9ed80766 2>/dev/null)
echo "  total selected: $(printf '%s\n' "$listed" | grep -c .)"
report "$listed"

repo="$scratch/repo"
mkdir -p "$repo"
git -C "$wt" archive HEAD | tar -x -C "$repo"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
case_run() { # <label> <paths...>
  local label=$1; shift
  git -C "$repo" checkout -q -- .
  local p; for p in "$@"; do printf '\n# probe\n' >>"$repo/$p"; done
  echo "== disposable copy: changed $label ($*)"
  listed=$(cd "$repo" && $R --list --changed --base HEAD 2>/dev/null)
  report "$listed"
}
case_run "host source only" bin/fm-supervision-host.sh
case_run "afk lib only" bin/fm-afk-contract.sh
case_run "host source + subject test" bin/fm-supervision-host.sh tests/fm-supervision-host.test.sh
case_run "subject test only" tests/fm-supervision-host.test.sh
case_run "lane-b wrapper only" tests/fm-supervision-host-lane-b.test.sh
case_run "lane-a wrapper + subject" tests/fm-supervision-host-lane-a.test.sh tests/fm-supervision-host.test.sh
case_run "branch dispatch + subject" bin/fm-branch-dispatch.mjs tests/fm-supervision-host.test.sh
git -C "$repo" checkout -q -- .
