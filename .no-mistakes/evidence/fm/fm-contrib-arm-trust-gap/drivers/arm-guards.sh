#!/usr/bin/env bash
# Live adversarial drives of the publish lock and the watcher's locked retry,
# against the real fm-contributions.sh / fm-pr-check.sh / fm-watch-checkpoint.sh
# in throwaway homes. Only the forge (gh) is a fixture; the TERM case adds a
# pausing mv seam to land the signal between the two publish renames.
# usage: arm-guards.sh <bin-root> <fixture-root> <scenario>
set -u
ROOT=$1 FIX_ROOT=$2 SCEN=$3
# shellcheck source=/dev/null
. "$(dirname "$0")/fixture.sh"
REAL_MV=$(command -v mv) REAL_SLEEP=$(command -v sleep) REAL_CP=$(command -v cp)

say() { printf '%s\n' "$*"; }
ino() { stat -f '%i' "$1"; }
authenticates() {
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$1/state" contributions ) && echo yes || echo no
}
rejections() {
  awk -F '\t' 'NF >= 5 && $4 == "unauthenticated-state-checks" { c++ } END { print c + 0 }' "$1/state/.wake-queue" 2>/dev/null || echo 0
}
checkpoint() {  # home secs out [env...]
  local home=$1 secs=$2 out=$3 rc=0 t0; shift 3
  t0=$SECONDS
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$secs" > "$out" 2> "$out.err" || rc=$?
  CP_RC=$rc CP_ELAPSED=$((SECONDS - t0))
}
show_out() { sed "s|$FIX_ROOT|<fixture>|g" "$1" | sed 's/^/    | /'; }
hold_lock() {  # lock marker seconds -> background holder pid in HOLDER
  ( FM_STATE_OVERRIDE=$(dirname "$1") . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$1"; : > "$2"; "$REAL_SLEEP" "$3"; fm_lock_release "$1" ) &
  HOLDER=$!
  for _ in $(seq 300); do [ -e "$2" ] && break; "$REAL_SLEEP" 0.1; done
}
fresh() {  # label -> HOME_DIR with an armed, authenticated contributions check
  HOME_DIR=$(new_home "$1")
  forge_home "$HOME_DIR"
  with_home "$HOME_DIR" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || { say "fixture: pr-check failed"; exit 1; }
  # Drop the PR poll check so each sweep only carries the contributions check
  # plus a stop-cycle check that ends every sweep with a wake.
  rm -f "$HOME_DIR/state/delivery.check.sh"
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$HOME_DIR/state/z-stop.check.sh"
  chmod 0700 "$HOME_DIR/state/z-stop.check.sh"
  with_home "$HOME_DIR" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || { say "fixture: z-stop"; exit 1; }
}

case "$SCEN" in
  unchanged-rearm)
    fresh unchanged
    h=$HOME_DIR
    say "== Re-arm with an unchanged shim through fm-pr-check.sh (the per-PR-record path)"
    i1=$(ino "$h/state/contributions.check.sh"); t1=$(ino "$h/state/contributions.check-trust")
    s1=$(shasum -a 256 "$h/state/contributions.check-trust" | cut -c1-16)
    with_home "$h" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null; rc=$?
    i2=$(ino "$h/state/contributions.check.sh"); t2=$(ino "$h/state/contributions.check-trust")
    s2=$(shasum -a 256 "$h/state/contributions.check-trust" | cut -c1-16)
    say "fm-pr-check.sh rc=$rc"
    say "check inode before/after: $i1 / $i2   trust inode before/after: $t1 / $t2   trust digest: $s1 / $s2"
    say "stage dirs left: $(find "$h/state" -maxdepth 1 -name '.contributions-arm.*' | wc -l | tr -d ' ')  publish lock left: $([ -e "$h/state/.check-publish-contributions.lock" ] && echo yes || echo no)"
    say "== Changed shim via arm (budget 20) then arm --if-owned (bootstrap path) with the same budget"
    with_home "$h" env FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" arm >/dev/null; rc=$?
    i3=$(ino "$h/state/contributions.check.sh")
    with_home "$h" env FM_CONTRIBUTIONS_BUDGET=20 "$ROOT/bin/fm-contributions.sh" arm --if-owned >/dev/null; rc2=$?
    i4=$(ino "$h/state/contributions.check.sh")
    say "changed arm rc=$rc new check inode=$i3 (was $i2); --if-owned rc=$rc2 inode after=$i4"
    say "budget line published: $(grep -c '^export FM_CONTRIBUTIONS_BUDGET=20$' "$h/state/contributions.check.sh")"
    say "pair authenticates: $(authenticates "$h")"
    checkpoint "$h" 90 "$h/w.out"
    say "watcher sweep rc=$CP_RC elapsed=${CP_ELAPSED}s rejection wakes=$(rejections "$h")"
    show_out "$h/w.out"
    ;;

  tamper-no-lock)
    fresh tamper
    h=$HOME_DIR
    say "== A check changed without the publish lock (tamper) is rejected, once"
    printf '# tampered\n' >> "$h/state/contributions.check.sh"
    checkpoint "$h" 90 "$h/w1.out"
    say "first sweep rc=$CP_RC elapsed=${CP_ELAPSED}s"
    show_out "$h/w1.out"
    checkpoint "$h" 90 "$h/w2.out" FM_WATCH_HANDLING_SUCCESSOR=1
    say "repeat sweep rc=$CP_RC elapsed=${CP_ELAPSED}s"
    show_out "$h/w2.out"
    say "queued rejection wakes total: $(rejections "$h")  marker: $([ -e "$h/state/.rejected-check-contributions" ] && echo present || echo absent)"
    ;;

  tamper-lock-busy)
    fresh busy
    h=$HOME_DIR
    lock="$h/state/.check-publish-contributions.lock"
    say "== Live writer holds the publish lock for 120s; the check is tampered"
    hold_lock "$lock" "$h/held" 120
    say "holder pid alive: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no); lock pid file: $([ "$(cat "$lock/pid" 2>/dev/null)" = "$HOLDER" ] && echo holder || echo other)"
    printf '# tampered\n' >> "$h/state/contributions.check.sh"
    cat > "$h/fakebin/sleep" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != 0.1 ] || printf x >> "$h/lockwait.count"
exec "$REAL_SLEEP" "\$@"
SH
    chmod +x "$h/fakebin/sleep"
    checkpoint "$h" 100 "$h/w.out"
    say "sweep rc=$CP_RC elapsed=${CP_ELAPSED}s (lock still held by live holder: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no))"
    say "watcher 0.1s lock-wait sleeps while the lock was busy: $(wc -c < "$h/lockwait.count" 2>/dev/null | tr -d ' ')"
    show_out "$h/w.out"
    say "queued rejection wakes: $(rejections "$h")"
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    ;;

  authentic-lock-busy)
    fresh authbusy
    h=$HOME_DIR
    lock="$h/state/.check-publish-contributions.lock"
    say "== Live writer holds the publish lock; the pair is authentic and a maintainer comment is waiting"
    jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
      body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
      updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$h/forge/comments.json"
    rm -f "$h/state/z-stop.check.sh" "$h/state/z-stop.check-trust"
    hold_lock "$lock" "$h/held" 120
    checkpoint "$h" 100 "$h/w.out"
    say "sweep rc=$CP_RC elapsed=${CP_ELAPSED}s (lock held by live holder throughout: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no))"
    show_out "$h/w.out"
    say "queued rejection wakes: $(rejections "$h")"
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    ;;

  stale-lock)
    fresh stale
    h=$HOME_DIR
    lock="$h/state/.check-publish-contributions.lock"
    say "== A crashed writer left the publish lock (owner killed -9); a changed arm follows"
    ( FM_STATE_OVERRIDE="$h/state" . "$ROOT/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$lock"; kill -9 "$BASHPID" )
    say "stale lock present: $([ -e "$lock" ] && echo yes || echo no)"
    t0=$SECONDS
    with_home "$h" env FM_CONTRIBUTIONS_BUDGET=21 "$ROOT/bin/fm-contributions.sh" arm >/dev/null 2>"$h/arm.err"; rc=$?
    say "arm rc=$rc elapsed=$((SECONDS - t0))s budget line published: $(grep -c '^export FM_CONTRIBUTIONS_BUDGET=21$' "$h/state/contributions.check.sh") pair authenticates: $(authenticates "$h")"
    say "publish lock left: $([ -e "$lock" ] && echo yes || echo no)"
    ;;

  term-mid-publish)
    fresh term
    h=$HOME_DIR
    lock="$h/state/.check-publish-contributions.lock"
    say "== TERM lands on arm between publishing the check and publishing its trust"
    old_trust=$(sed -n 2p "$h/state/contributions.check-trust")
    cat > "$h/fakebin/mv" <<SH
#!/usr/bin/env bash
"$REAL_MV" "\$@" || exit \$?
if [ -n "\${FM_TEST_PAUSE_ARM:-}" ] && [ "\${!#}" = "$h/state/contributions.check.sh" ]; then
  : > "$h/paused"
  for _ in \$(seq 600); do [ ! -e "$h/resume" ] || break; "$REAL_SLEEP" 0.1; done
fi
SH
    chmod +x "$h/fakebin/mv"
    with_home "$h" env FM_TEST_PAUSE_ARM=1 FM_CONTRIBUTIONS_BUDGET=22 "$ROOT/bin/fm-contributions.sh" arm >/dev/null 2>"$h/arm.err" &
    armpid=$!
    for _ in $(seq 600); do [ -e "$h/paused" ] && break; "$REAL_SLEEP" 0.1; done
    say "paused mid-publish: $([ -e "$h/paused" ] && echo yes || echo no); publish lock held: $([ -e "$lock" ] && echo yes || echo no)"
    kill -TERM "$armpid"; : > "$h/resume"
    wait "$armpid"; rc=$?
    rm -f "$h/fakebin/mv"
    say "arm exit after TERM: $rc"
    say "check present: $([ -f "$h/state/contributions.check.sh" ] && echo yes || echo no)  new shim published: $(grep -c '^export FM_CONTRIBUTIONS_BUDGET=22$' "$h/state/contributions.check.sh")  trust still old hash: $([ "$(sed -n 2p "$h/state/contributions.check-trust")" = "$old_trust" ] && echo yes || echo no)"
    say "publish lock left: $([ -e "$lock" ] && echo yes || echo no)  stage dirs left: $(find "$h/state" -maxdepth 1 -name '.contributions-arm.*' | wc -l | tr -d ' ')"
    checkpoint "$h" 90 "$h/w1.out"
    say "next sweep rc=$CP_RC elapsed=${CP_ELAPSED}s"
    show_out "$h/w1.out"
    with_home "$h" env FM_CONTRIBUTIONS_BUDGET=22 "$ROOT/bin/fm-contributions.sh" arm >/dev/null; rc=$?
    say "re-arm rc=$rc pair authenticates: $(authenticates "$h")"
    checkpoint "$h" 90 "$h/w2.out" FM_WATCH_HANDLING_SUCCESSOR=1
    say "sweep after re-arm rc=$CP_RC elapsed=${CP_ELAPSED}s marker: $([ -e "$h/state/.rejected-check-contributions" ] && echo present || echo absent)"
    show_out "$h/w2.out"
    say "queued rejection wakes total: $(rejections "$h")"
    ;;

  unregister-mid-sweep)
    fresh unreg
    h=$HOME_DIR
    say "== fm-check-unregister.sh retires the contributions check after the watcher read its trust"
    cat > "$h/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  "$h/state/contributions.check.sh":*/.fm-custom-check.*)
    if mkdir "$h/unregistered" 2>/dev/null; then
      FM_STATE_OVERRIDE="$h/state" "$ROOT/bin/fm-check-unregister.sh" contributions > "$h/unregister.out" 2>&1
    fi ;;
esac
exec "$REAL_CP" "\$@"
SH
    chmod +x "$h/fakebin/cp"
    checkpoint "$h" 90 "$h/w.out"
    say "sweep rc=$CP_RC elapsed=${CP_ELAPSED}s unregister ran mid-sweep: $([ -d "$h/unregistered" ] && cat "$h/unregister.out" || echo no)"
    show_out "$h/w.out"
    say "check present after: $([ -e "$h/state/contributions.check.sh" ] && echo yes || echo no)  queued rejection wakes: $(rejections "$h")  marker: $([ -e "$h/state/.rejected-check-contributions" ] && echo present || echo absent)"
    ;;
  *) say "unknown scenario $SCEN"; exit 2 ;;
esac
