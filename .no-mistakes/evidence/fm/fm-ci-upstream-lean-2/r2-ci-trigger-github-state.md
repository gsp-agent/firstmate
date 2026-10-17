# GitHub Actions state for gsp-agent/firstmate, queried 2026-10-17T03:59:39Z

## Upstream-lean PRs whose head lacks the ci.yml trigger: check counts
PR 33: 0 checks
PR 32: 0 checks
PR 31: 0 checks

## CI runs for branch fm/fm-ci-upstream-lean (PR 20, base upstream-lean)
CI pull_request head=382524da conclusion=success pr=#20 base=upstream-lean https://github.com/gsp-agent/firstmate/actions/runs/38602523486
CI pull_request head=f0d2d738 conclusion=failure pr=#20 base=upstream-lean https://github.com/gsp-agent/firstmate/actions/runs/38588954767
CI pull_request head=f546c1e4 conclusion=failure pr=#20 base=upstream-lean https://github.com/gsp-agent/firstmate/actions/runs/38537137444

## ci.yml at 382524da vs this run's head 4c3bd8dc
(empty diff above = byte-identical workflow)

## Trigger block at head
name: CI

on:
  push:
    branches: [main, upstream-lean]
  pull_request:
    branches: [main, upstream-lean]


## Open PR from fm/fm-ci-upstream-lean-2
none yet (PR phase has not run)
