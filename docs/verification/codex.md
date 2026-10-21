# Verification: Codex folder trust for crewmate and scout launches

Active empirical facts behind `bin/fm-codex-trust.sh` and the codex launch gate in `bin/fm-spawn.sh`.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/codex.md`](../../.agents/skills/harness-adapters/references/harness/codex.md); this record owns how they were established.

## Subject

| Field | Value |
|---|---|
| Version | `codex-cli 0.163.0` |
| Verified | 2026-10-20, rejected-launch cleanup 2026-10-21 |
| Platform | macOS 27.2 arm64 |
| Backend | tmux, on private sockets (`tmux -L <name>`); no fleet session was touched |
| Store | a throwaway `CODEX_HOME` per run, holding only a symlink to the operator's `auth.json`; the operator's own `config.toml` was never written |

## Trust is keyed by the repository root

A launch from a linked worktree whose project has no saved decision shows this full-screen prompt:

```
  Folder access
  /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/probe/r7/wt
  Note: You’re in a subdirectory of a Git project. Trusting will apply to the repository root:
  /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/probe/r7/proj
  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings can run code automatically, even without a
  model request. Continue only if you trust these files. Your trust decision will be saved.
› 1. Trust and continue
  2. Quit
  enter continue · esc quit
```

The root it names is the parent of the canonical `git rev-parse --git-common-dir`, which for a linked worktree is the project's primary checkout.
`--dangerously-bypass-approvals-and-sandbox` does not skip the prompt.
Answering "Trust and continue" appends `[projects."<root>"]` with `trust_level = "trusted"` to `${CODEX_HOME:-$HOME/.codex}/config.toml`.
An entry written there before launch is honoured: the same launch with that entry pre-written went straight to the session with no prompt.

A root saved as `trust_level = "untrusted"` parks on a second shape instead, and Escape leaves the saved decision unchanged:

```
  Folder access
  /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/probe/r9/wt
  Config, hooks, and exec policies from untrusted folders stay disabled. Trusted project folders can still contribute settings. Skills still load, and tools
  follow your permission settings. Opening will not change saved trust.
› 1. Open restricted
  2. Quit
  enter continue · esc quit
```

Without a credential in `CODEX_HOME`, the sign-in screen renders before either prompt.
`fm_busy_codex_launch_prompt_tail` in `bin/fm-busy-lib.sh` matches each shape by its own heading or question paired with its own option line.

## The welcome screen precedes the prompt

Codex draws its ordinary welcome screen before it checks folder trust.
Polling an unregistered launch every 0.25 seconds showed the welcome screen at the third poll and the prompt at the seventh:

```
=== frame at poll 3
  >_ OpenAI Codex (v0.163.0)
     ~/dev/firstmate-upstream/data/fm-fhzhp/probe/r7/wt
...
› Ask Codex to do anything
  ? for shortcuts
=== frame at poll 7
  Folder access
...
```

So the welcome screen, its `OpenAI Codex (v` header, and its `? for shortcuts` hint prove nothing about trust.
A pre-trusted launch with a positional prompt showed the in-turn footer within two seconds of the welcome screen, first while MCP servers start and then for the rest of the turn:

```
• Starting MCP servers (1/2): codex_apps (0s • esc to interrupt)
...
• Working (1s • esc to interrupt)
```

A finished turn leaves `Worked for <duration>` above the composer.
The prompt never shows either string, because Codex starts no session until trust is settled.
`bin/fm-spawn.sh`'s codex gate therefore fails the spawn as soon as a capture matches the folder-access signature, counts the launch as started only on `esc to interrupt` or `Worked for <digit>`, and fails it after about 60 seconds of neither, naming the installed codex version.

## End-to-end spawn proof

The real `bin/fm-spawn.sh` launched the real codex into a fresh linked worktree of a `groove-jones-ops` clone, under a throwaway Firstmate home, a private tmux server whose pane shell defined `treehouse` as a `cd` into the pre-made worktree, and a throwaway `CODEX_HOME` with no `config.toml`:

```sh
FM_HOME="$P/home" HOME="$P/user-home" CODEX_HOME="$P/fresh/codex-home" \
  FM_STATE_OVERRIDE="$P/home/state" FM_DATA_OVERRIDE="$P/home/data" \
  FM_PROJECTS_OVERRIDE="$P/home/projects" FM_CONFIG_OVERRIDE="$P/home/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="$socket,1,0" PATH="$P/fakebin:$PATH" \
  bin/fm-spawn.sh fhzhp-proof-fresh "$P/fresh/groove-jones-ops" --harness codex --mode no-mistakes --yolo off
```

```
spawned fhzhp-proof-fresh harness=codex kind=ship mode=no-mistakes yolo=off window=firstmate:fm-fhzhp-proof-fresh worktree=/Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/fresh/wt
exit=0
=== store after spawn (fresh)
[projects."/Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/fresh/groove-jones-ops"]
trust_level = "trusted"
...
=== worker pane right after the spawn returned (fresh)
  >_ OpenAI Codex (v0.163.0)
     /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/fresh/wt
  permissions: YOLO mode
› FIRSTMATE_OP: v1 launch-brief: # Current worker role contract
...
• Starting MCP servers (1/2): codex_apps (0s • esc to interrupt)
```

The same spawn against a second clone whose store records `trust_level = "untrusted"` for its root refused before launch and left the store unchanged:

```
error: /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/declined/codex-home/config.toml records trust_level = 'untrusted' for /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/declined/groove-jones-ops, an explicit decision this will not override
error: refusing to pre-register codex trust: could not record trust for '/Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/declined/groove-jones-ops' in '/Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/declined/codex-home/config.toml'
error: could not pre-register Codex folder trust for /Users/dalecarman/dev/firstmate-upstream/data/fm-fhzhp/proof/p2/declined/wt; refusing to launch a codex worker that would park on the trust prompt; inspect window firstmate:fm-fhzhp-proof-declined
exit=1
```

A direct codex launch into a third clone with no entry and no registration parked on the "Trust this folder?" prompt, and `fm_busy_launch_prompt_parked codex` matched that capture.

## A rejected launch can outlive its window

On 2026-10-21 the spawn above was rerun with a `codex` wrapper first on `PATH` that pointed the real CLI at a second throwaway `CODEX_HOME` holding no trust entry, so the launch parked on the prompt despite the registration and the gate rejected it before any turn started.
Each run used a private tmux server whose pane shell was the only variable, and listed every process naming the proof directory two seconds after the spawn returned.
Before the fix, the gate's window close ended codex under `zsh` 5.9 and GNU bash 5.3.20, but under macOS `/bin/bash` 3.2.57 the Node shim and the native binary kept running, the shim reparented to launchd:

```
error: codex parked on its folder-access prompt in window firstmate:fm-fhzhp-orphan-p10-before-bash32 despite the pre-registered trust, so the worker could not reach its brief; inspect window firstmate:fm-fhzhp-orphan-p10-before-bash32
exit=1
=== codex processes still running for this launch, 2 s after the spawn returned
77370     1 77370 S    node
78085 77370 77370 S    /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
```

SIGTERM stopped both.
The gate now reaps every process rooted in the task's worktree through `bin/fm-task-reap-lib.sh` before it closes the window, and the same `/bin/bash` 3.2.57 run leaves nothing behind:

```
error: codex parked on its folder-access prompt in window firstmate:fm-fhzhp-orphan-p13-after-bash32 despite the pre-registered trust, so the worker could not reach its brief; inspect window firstmate:fm-fhzhp-orphan-p13-after-bash32
spawn: reaping leaked worktree process(es) for fhzhp-orphan-p13-after-bash32: 68929 77541 78945
spawn: force-killing leaked worktree process(es) for fhzhp-orphan-p13-after-bash32: 68929
exit=1
=== codex processes still running for this launch, 2 s after the spawn returned
(none)
```

## Regression coverage

`tests/fm-codex-trust.test.sh` pins the helper's registration, byte preservation, refusals, and store selection against throwaway stores.
It also drives `bin/fm-spawn.sh` against a fake pane that draws the screens above: a pre-trusted root reaches a running turn, a set `CODEX_HOME` is forwarded to the launch, the prompt fails the spawn on sight after the welcome screen and closes the endpoint, a launch that never starts a turn fails at the bound naming the version, a rejected launch leaves no SIGHUP-ignoring worker process running in its worktree, and an unregistrable root refuses before launch.
`tests/fm-busy-state.test.sh` pins the classifier's `unknown launch-prompt` verdict for both prompt shapes.
`FM_LAUNCH_PROMPT_SIGNALS_LIVE=1 bash tests/fm-launch-prompt-signals-live-e2e.test.sh` re-checks the first prompt shape against the installed codex, as recorded in [runtime-backends.md](runtime-backends.md#launch-prompt-backstop-signatures); rerun it after a codex upgrade.
