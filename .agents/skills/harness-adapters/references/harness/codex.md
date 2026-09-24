# Codex

Verified on 2026-09-12 with codex-cli 0.153.2 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh\|max>"'`, verified on codex-cli 0.153.2; `max` is forwarded only for catalog-proven models `gpt-6-astra`, `gpt-6-luna`, `gpt-reserve`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, and `codex-auto-review`. The 2026-09-23 codex-cli 0.156.0 catalog reports `max` for `gpt-6-luna`; other or unproven entries keep the record-and-omit behavior. |
| Model discovery | Open the current interactive session's `/model` picker. |

## Canonical task launch

As of 2026-09-23, Firstmate's canonical Codex adapter sets the resolved task worktree with `--cd`, selects `--sandbox workspace-write` and `--ask-for-approval never`, enables `sandbox_workspace_write.network_access=true`, and passes the resolved worktree Git directory and common directory with `--add-dir`. If either Git administration root cannot be resolved, the canonical launch is refused; it does not fall back to the raw-launch escape hatch.

For non-secondmate canonical workers, it also pre-creates the exact task `.status` file and the task's `.inbox/handled` directory, then adds only that status file and that inbox directory as further writable roots. The selected `FM_HOME` is set inside the launch command so a stale value inherited from a long-lived pane cannot redirect task-state helpers. This uses codex-cli 0.156.0's `--add-dir` `PathBuf` option; its macOS Seatbelt policy treats an existing non-directory writable root as a literal path rather than a recursive directory grant ([CLI option](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/utils/cli/src/shared_options.rs), [Seatbelt root handling](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/sandboxing/src/seatbelt.rs)).

These flags describe the launch request, not proven sandbox behavior. Codex documents that `workspace-write` protects `<writable_root>/.git` and, for a Git-pointer worktree, its resolved Git directory as read-only. Adding those paths does not by itself prove Git metadata is writable or establish outside-root denial. No live Firstmate Codex launch or Git mutation is claimed here. See [Codex agent approvals and security](https://learn.chatgpt.com/docs/agent-approvals-security) and the [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
