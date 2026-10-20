## In flight

## Queued
- [ ] signin - Lab signin (repo: firstmate) (kind: captain) (since 2026-10-20)
  Resolution recorded by fm-captain-hold.
  Decision digest: 34e0a552ad445aa394eba600033fce932c30c311bcbb3f0a55888c4833024fdb
  Resolution mode: probe-released

  Reconciliation evidence:
  Probe passed for the Dale step this hold waits on: printf attempt\n >> "$FM_HOME/signin.attempts"; curl --fail --silent --max-time 2 http://127.0.0.1:62298/status

  Decision owner: dale
  Hold timeout seconds: 3600
  Hold reason: complete the isolated sign-in step
  Hold probe: printf attempt\n >> "$FM_HOME/signin.attempts"; curl --fail --silent --max-time 2 http://127.0.0.1:62298/status

- [ ] failed - Lab failed (repo: firstmate) (kind: captain) (since 2026-10-20) (hold: fm-hold-v1:Y29tcGxldGUgdGhlIGlzb2xhdGVkIHNpZ24taW4gc3RlcA==) (hold-kind: captain)
  Captain hold set: 2026-10-20T22:35:41Z
  Decision owner: dale
  Hold timeout seconds: 3600
  Hold reason: complete the isolated sign-in step
  Hold probe: printf attempt\n >> "$FM_HOME/failed.attempts"; false

- [ ] unknown - Lab unknown (repo: firstmate) (kind: captain) (since 2026-10-20) (hold: fm-hold-v1:Y29tcGxldGUgdGhlIGlzb2xhdGVkIHNpZ24taW4gc3RlcA==) (hold-kind: captain)
  Captain hold set: 2026-10-20T22:35:57Z
  Decision owner: dale
  Hold timeout seconds: 3600
  Hold reason: complete the isolated sign-in step
  Hold probe: printf attempt\n >> "$FM_HOME/unknown.attempts"; fm-lab-command-does-not-exist

- [ ] hung - Lab hung (repo: firstmate) (kind: captain) (since 2026-10-20) (hold: fm-hold-v1:Y29tcGxldGUgdGhlIGlzb2xhdGVkIHNpZ24taW4gc3RlcA==) (hold-kind: captain)
  Captain hold set: 2026-10-20T22:36:10Z
  Decision owner: dale
  Hold timeout seconds: 3600
  Hold reason: complete the isolated sign-in step
  Hold probe: bash "$FM_HOME/hung.sh"

- [ ] ordinary - Lab ordinary (repo: firstmate) (kind: captain) (since 2026-10-20) (hold: fm-hold-v1:Y29tcGxldGUgdGhlIGlzb2xhdGVkIHNpZ24taW4gc3RlcA==) (hold-kind: captain) (hold-until: 2099-01-01)
  Captain hold set: 2026-10-20T22:36:31Z
## Done
