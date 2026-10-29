---
name: firstmate-self-repo
description: The firstmate-repository publication boundary. Load before dispatching, promoting, relaunching, or delivering any task whose project is the firstmate repository itself, when a firstmate bug or improvement idea surfaces in ordinary use, before granting or revoking upstream publication authority, and before deciding whether any push, pull request, issue, comment, or fork may reach firstmate's own upstream.
user-invocable: false
metadata:
  internal: true
---

# firstmate-self-repo

Every firstmate home clones the same public repository and runs from it, which makes firstmate's own upstream the one repository a running home can always reach.
Most homes belong to people who simply use firstmate, not to the people who maintain it, and a running agent that treats "I can see the repo" as "I may publish to it" is how a user's firstmate opens surprise pull requests upstream.
This skill owns the boundary between the two relationships.

## The default: user/operator

Absent any explicit grant, a home runs as firstmate **user/operator**.
It may install, run, update, reconfigure, and locally repair firstmate, and its ordinary project work flows through the registered delivery modes unchanged.
What it may never do on its own is publish to firstmate's upstream: no pushed branch, no pull request, no issue, no comment, no fork, no review.

Role is **never inferred**.
GitHub identity, forge permissions, the name or URL of `origin` or any other remote, repository ownership, authentication state, environment variables, and CI context all say nothing about role; the only inputs are the explicit local grants below.

## When a firstmate bug surfaces in ordinary use

A user/operator home that hits a firstmate bug does local work only:

1. Diagnose privately - reproduce, isolate, and root-cause inside the home and its task records.
2. Apply a local workaround when one exists - a config change, a pinned local edit, a different invocation.
3. Optionally prepare a sanitized local issue draft or a proposed local patch under the task's data directory, for the operator to review and submit by hand.
4. Report to the captain what happened and what was produced.

A local patch or workaround may touch the gitignored operational surface and a task's own worktree; nothing reaches upstream without the authority below.
This posture covers firstmate self-repair exactly the same way it covers a dispatched task: the boundary is about publication, not about which surface holds the fix.

## The two explicit grants

### Maintainer opt-in (standing)

Only the operator may opt the primary home in; follow the [Firstmate role schema and resolution policy](../../../docs/configuration.md#firstmate-role-configfirstmate-role), rather than creating a grant on the operator's behalf.

### One-task contribution consent (bounded)

When the captain explicitly approves one specific upstream contribution, record it on that task only: `--upstream-consent <host>/<owner>/<repo>` on `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh`.
Consent renders as an `upstream-consent=` token on the brief's `Delivery contract:` line, is recorded in `state/<id>.meta`, and a relaunch reuses the recorded value.
It changes the home's persistent role in no way; the next task is gated fresh.
The captain's approval must be a current explicit instruction naming the contribution - never an inference from the task resembling maintainer work.

## Where the boundary is enforced

The gate is code, not memory: `bin/fm-role-lib.sh`'s `fm_role_gate_self_publish` applies the [lineage and publication-target policy](../../../docs/configuration.md#firstmate-role-configfirstmate-role) to publishing contracts.

- `bin/fm-brief.sh --project <dir>` refuses to scaffold a publishing ship brief the home cannot authorize.
- `bin/fm-spawn.sh` refuses to launch a ship task on this repository without a maintainer scope or matching task consent, and refuses a brief whose `upstream-consent=` disagrees with the flag.
- `bin/fm-promote.sh` applies the same gate to scout promotion so the in-place path grants no more than a fresh spawn.
- `local-only` publishes nothing, so it never needs authority and never takes consent.

An authorized contribution then flows through the task's normal delivery contract - usually no-mistakes - like any other project; the grant answers only "may this publish", never "how".
Every PR to `upstream-lean` adds its own file `drift-proof/<N>.proof` holding a `pr: <N>` line, after a `#` comment naming its failing-first test or measurement, and leaves the squash subject's `(#N)` unedited.
A PR that adds or changes behavior names a test measured red on the current upstream main files and green on the PR, and the nightly replay of its patch on current upstream must be clean.
A cut PR instead names its archive branch and the callers outside this repository of what it removes, keeps the suite green, and does not merge while one of those callers would break.
The cutover PR is held to its own live check.
No PR merges to `upstream-lean` while its proof is pending.
No direct pushes to `upstream-lean` are allowed.
Every PR names its series: spawn-dispatch, teardown-taskdata, runtime-core, watcher-budgets, pr-merge, holds-inbox-wake, drift-guard, herdr-backend, session-fleet or docs-skills; a PR that fits none of them names a new series with its reason, and a PR that names no series does not merge.
`drift-proof.txt` closed at PR 167 and takes no new line, so two open PRs never edit the same file.

A gate refusal names the exact remedy: write `maintainer <scope>` into `config/firstmate-role`, or pass `--upstream-consent <scope>` for that one task with the captain's explicit approval.
Never work around a refusal by pointing the task at a second checkout, fork, or parent clone; `fm_role_self_repo` treats every repository sharing firstmate's lineage as firstmate's own.

## Updating is not contributing

`/updatefirstmate` and every guarded sync pull **from** upstream, which is consumption, not publication, and stays allowed for every role.
The boundary covers only traffic that writes to the upstream repository.

## Secondmates

Follow the [role inheritance and receipt limits](../../../docs/configuration.md#firstmate-role-configfirstmate-role); supported propagation must never grant a child a role the primary does not resolve.
Deliberately forged local records are outside this accidental-publication safeguard, not a provenance guarantee.
