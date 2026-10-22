# Local ShellCheck option A measurement

The 2026-09-05 lint-cost audit measured the seven roots from the missed-reply incident at commit `f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19`:

```text
bin/fm-brief.sh
bin/fm-parent-channel-lib.sh
bin/fm-pending-reply-lib.sh
bin/fm-secondmate-report.sh
tests/fm-brief.test.sh
tests/fm-classify-corr-token.test.sh
tests/fm-pending-reply.test.sh
```

ShellCheck was the repository-pinned 0.11.0 Darwin arm64 build.
The baseline was one source-aware invocation containing all seven roots.
Option A used one process per root, omitted `--external-sources`, retained extended dataflow, and applied the local cross-file exclusion list.
Both variants were measured in the same quiet-host window:

| Variant | User + system CPU | Reduction | Worst-process RSS | Reduction |
| --- | ---: | ---: | ---: | ---: |
| source-aware baseline | 140.1 s | n/a | 8.30 GB | n/a |
| option A, per-root processes | 9.8 s | 93.0% | 0.56 GB | 93.3% |

## Current measurements

The table records historical measurements from before mandatory ShellCheck caps; it is not a current performance guarantee.
Use the capped [`bin/fm-lint.sh`](../../bin/fm-lint.sh) entry point for new measurements; its header and `--help` own analysis modes, file selection, caps, and `--telemetry` output, including the per-root lifecycle sidecar.
The historical baseline analyzed all seven roots in one source-aware process, and the current runner analyzes roots separately, so its telemetry does not reproduce that baseline's invocation shape.
Keep new evidence separate from the historical comparison and treat any cap failure as an incomplete measurement, never a successful sample.

CPU and RSS vary with host load, so percentage claims must compare runs from one measurement window.
When results must be compared across windows, use the reported `bytes_allocated` totals as the stable work proxy rather than quoting a CPU or RSS ratio.
