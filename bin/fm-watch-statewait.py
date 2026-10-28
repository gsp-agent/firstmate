#!/usr/bin/env python3
"""Bounded kqueue wait for a Firstmate home's state/ writes.

This is the event half of bin/fm-watch.sh's terminal cycle wait
(state_wait_or_sleep). It deliberately does NOT know supervision policy: it
watches one home's state directory and returns as soon as a watched file
changes, so the watcher's next poll cycle - which re-reads everything -
starts sub-second after a worker appends its status instead of after the
FM_POLL backstop. The bash side owns capability memoization, failure
disable, and the plain fm_sleep fallback; a non-zero exit here never drops
work, it only hands the wait back to that fallback.

Watched, rebuilt on every change check so files created mid-wait join:
  <state_dir>/*.status and <state_dir>/*.meta (appends, rewrites, replaces),
  <state_dir>/.wake-queue when it exists, every file under
  <state_dir>/hold-domain when it exists, the state and hold-domain
  directories themselves (creations and removals), plus any extra files
  named on the command line (the home's data/backlog.md).
A change is a watched path appearing or disappearing, or its inode, size,
or mtime moving. Directory noise outside those classes (temp files, lock
directories, beacon touches) re-checks the watched set and keeps waiting.

Usage: fm-watch-statewait.py <timeout_seconds> <state_dir> [<file> ...]
A timeout of 0 sets the watches up and returns at once: the caller's
capability probe.

Exit status:
  0  a watched change was observed (including one between the baseline
     sample and the watches opening, and any failure after setup, which
     wakes the caller to re-scan rather than waiting blind).
  1  the timeout elapsed with no watched change - a clean bounded wait.
  2  this wait is unavailable: bad arguments, no kqueue on this platform,
     an unusable state directory, or a watch that could not be opened.
Prints nothing; the caller owns the watcher's stdout.
"""
import glob
import os
import resource
import select
import sys
import time

FFLAGS = 0  # filled in main once kqueue is proven present


def _sig(path):
    try:
        st = os.stat(path)
        return (st.st_ino, st.st_size, st.st_mtime_ns)
    except OSError:
        return None


def _snapshot(state_dir, extras):
    """Map every watched file to its signature; missing files are absent."""
    snap = {}
    paths = sorted(
        glob.glob(os.path.join(state_dir, "*.status"))
        + glob.glob(os.path.join(state_dir, "*.meta"))
    )
    queue = os.path.join(state_dir, ".wake-queue")
    paths += [queue] + list(extras)
    hold = os.path.join(state_dir, "hold-domain")
    if os.path.isdir(hold):
        for root, _subdirs, files in os.walk(hold):
            for name in files:
                paths.append(os.path.join(root, name))
    for path in paths:
        sig = _sig(path)
        if sig is not None:
            snap[path] = sig
    return snap


def _dirs(state_dir):
    dirs = [state_dir]
    hold = os.path.join(state_dir, "hold-domain")
    if os.path.isdir(hold):
        dirs.append(hold)
        for root, subdirs, _files in os.walk(hold):
            for name in subdirs:
                dirs.append(os.path.join(root, name))
    return dirs


def main(argv):
    if len(argv) < 3:
        return 2
    try:
        timeout = float(argv[1])
    except ValueError:
        return 2
    if timeout < 0:
        return 2
    state_dir = argv[2]
    extras = argv[3:]
    if not os.path.isdir(state_dir):
        return 2
    if not hasattr(select, "kqueue"):
        return 2
    global FFLAGS
    FFLAGS = (
        select.KQ_NOTE_WRITE
        | select.KQ_NOTE_EXTEND
        | select.KQ_NOTE_ATTRIB
        | select.KQ_NOTE_DELETE
        | select.KQ_NOTE_RENAME
    )
    # A busy home holds hundreds of status logs; raise the soft fd limit
    # toward the hard one so every watched file can hold an event fd.
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < hard:
            resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    except (OSError, ValueError):
        pass
    baseline = _snapshot(state_dir, extras)
    kq = None
    fds = []
    try:
        try:
            kq = select.kqueue()
            for path in list(baseline) + _dirs(state_dir):
                fd = os.open(path, os.O_EVTONLY if hasattr(os, "O_EVTONLY") else os.O_RDONLY)
                fds.append(fd)
                kq.control(
                    [select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                   flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                   fflags=FFLAGS)],
                    0,
                )
        except (OSError, ValueError):
            return 2
        # A change between the baseline and the watches queues no event, so
        # re-sample once here and report it instead of waiting it out.
        if _snapshot(state_dir, extras) != baseline:
            return 0
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return 1
            events = kq.control(None, 16, remaining)
            if not events:
                return 1
            if _snapshot(state_dir, extras) != baseline:
                return 0
            # Noise outside the watched classes: keep waiting on the same
            # baseline until the deadline.
    except (OSError, ValueError):
        # Setup already proved out; a mid-wait failure wakes the caller to
        # re-scan (its poll is the backstop), never a silent blind wait.
        return 0
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
        if kq is not None:
            try:
                kq.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
