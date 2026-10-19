#!/usr/bin/env bash
# Drives the real tests/fm-supervision-host.test.sh dispatch under each lane
# setting (directly and through the real lane wrappers) with the
# dispatch-recorder BASH_ENV hook, then compares what ran with the real
# function table. Usage: lane-dispatch-drive.sh <worktree> <evidence-dir> <record-dir>
set -u
wt=$1 ev=$2 rec=$3
cd "$wt" || exit 1
hook="$ev/dispatch-recorder.bash_env"
labels="unset-direct empty-direct all-direct a-direct b-direct lane-a-wrapper lane-b-wrapper lane-a-wrapper-env-all bogus-direct uppercase-direct"
run() { # <label> <env assignments...> -- <script>
  local label=$1; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : >"$rec/$label"
  : >"$rec/$label.defined"
  env -u FM_SUPERVISION_HOST_LANE ${envs[@]+"${envs[@]}"} FM_DISPATCH_RECORD="$rec/$label" BASH_ENV="$hook" bash "$1" >"$rec/$label.out" 2>&1
  echo $? >"$rec/$label.rc"
}
run unset-direct -- tests/fm-supervision-host.test.sh
run empty-direct FM_SUPERVISION_HOST_LANE= -- tests/fm-supervision-host.test.sh
run all-direct FM_SUPERVISION_HOST_LANE=all -- tests/fm-supervision-host.test.sh
run a-direct FM_SUPERVISION_HOST_LANE=a -- tests/fm-supervision-host.test.sh
run b-direct FM_SUPERVISION_HOST_LANE=b -- tests/fm-supervision-host.test.sh
run lane-a-wrapper -- tests/fm-supervision-host-lane-a.test.sh
run lane-b-wrapper -- tests/fm-supervision-host-lane-b.test.sh
run lane-a-wrapper-env-all FM_SUPERVISION_HOST_LANE=all -- tests/fm-supervision-host-lane-a.test.sh
run bogus-direct FM_SUPERVISION_HOST_LANE=bogus -- tests/fm-supervision-host.test.sh
run uppercase-direct FM_SUPERVISION_HOST_LANE=A -- tests/fm-supervision-host.test.sh

defined="$rec/unset-direct.defined"
total=$(grep -c . "$defined")
echo "real function table: $total test_* cases (compgen -A function inside the running file)"
printf '%-24s %4s %6s %5s %s\n' run exit cases dups equals
for label in $labels; do
  n=0 d=0 eq=-
  if [ -s "$rec/$label" ]; then
    n=$(grep -c . "$rec/$label")
    d=$(cut -f2 "$rec/$label" | LC_ALL=C sort | uniq -d | grep -c .)
    [ "$(cut -f2 "$rec/$label" | LC_ALL=C sort)" = "$(cat "$defined")" ] && eq=all-defined
  fi
  printf '%-24s %4s %6s %5s %s\n' "$label" "$(cat "$rec/$label.rc")" "$n" "$d" "$eq"
done
echo
a=$(cut -f2 "$rec/lane-a-wrapper" | LC_ALL=C sort)
b=$(cut -f2 "$rec/lane-b-wrapper" | LC_ALL=C sort)
echo "lane-a wrapper and lane-b wrapper share $(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | grep -c .) cases"
if [ "$(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort)" = "$(cat "$defined")" ]; then
  echo "lane-a wrapper + lane-b wrapper = every defined case, each exactly once"
else
  echo "MISMATCH: lane union differs from the function table"
fi
if [ "$(cut -f2 "$rec/unset-direct")" = "$(cut -f2 "$rec/lane-a-wrapper"; cut -f2 "$rec/lane-b-wrapper")" ]; then
  echo "unset-direct runs lane a's cases then lane b's, in file order"
else
  echo "unset-direct order differs from lane a then lane b"
fi
echo
echo "bogus-direct output:"; cat "$rec/bogus-direct.out"
echo "uppercase-direct output:"; cat "$rec/uppercase-direct.out"
