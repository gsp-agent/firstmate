Live validation: fm-pr-merge.sh accepts a reviewer's approval at head only when
the head commit already existed when the review was submitted, and reads every
review page.

Setup (lab-setup.txt): a disposable fake GitHub API (fakegh.py) on a local port.
The real gh 2.103.0 binary reaches it through GH_HOST=github.localhost plus
HTTP_PROXY. A thin route rewrites github.com to github.localhost in gh's
arguments. gh-axi is replaced by a refusal, so nothing reaches real GitHub.
Each case runs the real bin/fm-pr-merge.sh with FM_HOME set to a marked lab
home from bin/fm-lab-home.sh create. Real gh does the pagination (Link
headers), the GraphQL pr view, and the gh pr merge --match-head-commit
mutation. The fake server logs every request, so a transcript shows whether
the merge mutation was sent.

PR 4246 data is replayed from the investigation report
(data/fm-review-commit-rebind/report.md). The client repository was not read.

live-00-summary.txt     one line per case: exit code, expectation, merge mutation sent or not
live-NN-<root>-<case>   full transcript; root "change" is this branch, "base" is d6b8de4d
tests-focused-*         the new approval tests and the two captain-hold merge tests, against this change
tests-failing-first-*   the new tests against the base commit's script (they fail as expected)
