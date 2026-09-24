# Firstmate Codex 6 Phase 0 launch proof

The supervised Codex worker ran through the maintained Firstmate adapter.

- Adapter source: `b6ff90ef81318e8c7b3fd6c910819e2c7203181b`.
- Task branch content base: `35761484e9f0a692ebec86532ff4dd252b224cf9`.
- Backend and mode: tmux, no-mistakes, with yolo enabled.
- Model and effort: `gpt-6-luna` and `max`.
- Runtime policy: `workspace-write`, approval `never`, and network enabled.
- Explicit workspace roots: the isolated task worktree and the required Git administration roots.
- The managed host profile also exposed standard temporary directories; no files were written there.
- One outside-root `O_CREAT|O_EXCL` probe was denied with `EPERM`.
