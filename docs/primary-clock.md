# Firstmate primary clock

`com.firstmate.primary-clock` is an optional per-user LaunchAgent example. It is not installed by this change. Its single `StartInterval=900` job runs `bin/fm-primary-tick.sh`; it is a bounded liveness/reconciliation bridge, not a task dispatcher or replacement watcher.

Every quiet 15-minute interval may prompt the existing primary when its pinned Codex process and tmux pane are verified, Codex's native rollout proves that the current turn is idle, the composer is positively empty, and the named tmux session has no attached clients.
Lifecycle proof comes from exactly one non-symlink rollout whose filename carries the pinned session UUID and whose first `session_meta` record matches that UUID.
Lifecycle events are reduced in their native JSONL record order, not sorted or filtered by wall-clock time; each event timestamp must still be a valid UTC value.
The Codex session protocol permits at most one task at a time, and a later user turn aborts the prior task before starting the next.
Accordingly, a valid later `task_started` replaces an unmatched earlier task as the current task, without claiming that the earlier task completed; only a terminal event matching the current task can establish idle.
A bare resume with orphaned task A therefore remains busy. The confirmed-dead recovery path resumes the same UUID with the normal reconciliation prompt, producing native task B; B remains busy until B's own matching completion is recorded.
A rollout with no lifecycle history remains unknown, as do missing, malformed, duplicate, mismatched, or unsupported lifecycle events and unreadable timestamps.
Because event order rather than timestamp comparison defines the transitions, a backward wall-clock adjustment cannot demote a later native start to stale history.
Rendered busy/idle text is not used as worker-state proof.
The prompt asks that primary to inspect the existing authorized backlog and durable wake queue, decide eligibility under Firstmate's existing rules, and create no tasks when nothing is eligible.
The clock script itself never creates Firstmate tasks or queue records.
The event names follow Codex's [protocol](https://github.com/openai/codex/blob/main/codex-rs/docs/protocol_v1.md) and [rollout persistence](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/policy.rs); this remains a clock-local proof and does not change Firstmate's shared Codex supervision contract.

A current-owner unmatched native turn start or the primary's foreground checkpoint keeps the tick from sending terminal input; the next primary checkpoint owns reconciliation.
If a human has typed into the composer, a tmux client is attached, process/session evidence is ambiguous, or the state cannot be read, the tick preserves the current state and defers.
It rechecks native lifecycle immediately before submission.
On a safe idle prompt it uses Firstmate's existing verified tmux submit helper: text is entered once, only Enter may be retried, and a newly observed native turn-start event is required before reporting consumption.
Unconfirmed text is never typed again by the tick.

Recovery requires all of the following: the PID in the existing `state/.lock` is not signalable, a PID-specific process-table query confirms it is absent, and a process-wide scan finds no Codex process carrying the pinned native UUID. A live away-mode marker or ambiguous held watcher lock also prevents replacement. If one exact marked or deterministic-name recovery candidate exists and its sole pane is confirmed dead with no tmux client attached, the clock re-pins and respawns that same pane without killing it. With no candidate, it resumes the same UUID in a detached, named tmux window. Both paths pass the existing normal reconciliation prompt as Codex's resume prompt, so the replacement emits a native task start rather than relying on rendered UI state to clear an orphan. A live or ambiguous candidate is preserved and recovery refuses; an existing window name alone is not proof of a running owner. Both paths keep the pinned home/code root, `gpt-6-luna/max`, `danger-full-access`, and `approval=never`, and set detect-only startup mode so startup mutation sweeps do not repeat. Recovery is not reported as active until the normal lock and exact-process checks succeed. The startup `--reemit` hook remains a digest/verification path, not a launcher.

The example uses Apple's native `launchd` `StartInterval` facility. The local `launchd.plist(5)` page documents that a firing is missed when the job is already running, so interval ticks do not overlap; the implementation adds no parallel lock or lease system. Sleep can also delay an interval. A single installed label is the scheduler owner; do not copy the plist under another label or run the mutating tick manually while it is loaded.

## Configure and install

Replace every `/absolute/path/...` value in [`com.firstmate.primary-clock.plist.example`](launchd/com.firstmate.primary-clock.plist.example) with the actual Firstmate home, maintained checkout, Codex home, native session UUID, tmux server socket/session, executable paths, and log paths for one primary. `FM_HOME` must be the operational home; `FM_ROOT_OVERRIDE` must be a checkout in that same Git repository. Keep the approval, sandbox, model, effort, and 900-second interval unchanged. Create the LaunchAgents and log directories first.

Then install only this label:

```sh
PLIST="$HOME/Library/LaunchAgents/com.firstmate.primary-clock.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp docs/launchd/com.firstmate.primary-clock.plist.example "$PLIST"
open -t "$PLIST"
plutil -lint "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/com.firstmate.primary-clock"
```

Before loading, `bin/fm-primary-tick.sh --check` is the read-only identity/endpoint probe; pass it the exact environment values from the plist. It neither sends a prompt nor launches recovery. `launchctl print` verifies that this one job is loaded. With `RunAtLoad=false`, the first scheduled action is an interval firing, not installation itself. Review its stdout/stderr logs after the first interval; source checks and fake-boundary tests are not live delivery or recovery proof.

## Uninstall

Unload and remove only this LaunchAgent plist:

```sh
PLIST="$HOME/Library/LaunchAgents/com.firstmate.primary-clock.plist"
launchctl bootout "gui/$(id -u)" "$PLIST"
rm "$PLIST"
```

Do not unload or edit any Observer, watcher, or other Firstmate job. Leave the clock logs, home locks/queue, tmux session, and any already-created recovery window untouched; the installer does not own those resources.
