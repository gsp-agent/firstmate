#!/usr/bin/env bash
set -eu
. "$1/bin/fm-wake-lib.sh"
fm_lock_try_acquire "$STATE/.control-sm1.lock"
lock=$(fm_meta_lock_path "$STATE/sm1.meta")
fm_lock_try_acquire "$lock"
printf 'kind=secondmate
harness=codex
backend=tmux
window=primary:fm-sm1
' > "$STATE/sm1.meta.next"
mv "$STATE/sm1.meta.next" "$STATE/sm1.meta"
fm_lock_release "$lock"
fm_lock_release "$STATE/.control-sm1.lock"
