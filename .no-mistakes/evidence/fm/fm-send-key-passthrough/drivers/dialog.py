#!/usr/bin/env python3
"""Stand-in for Grok's weekly-limit dialog, used as the target pane program.

It puts its tty in raw mode and records every byte chunk it receives, so the
driver can prove exactly which bytes fm-send delivered. Like the Grok 1.0.70
dialog the captain reported, Escape only moves focus to scrollback and C-c
leaves it up; only Shift+x (the byte 'X') dismisses it back to an empty
composer.
"""
import os
import sys
import termios
import tty

log_path = sys.argv[1]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)

NAMES = {b"\x1b": "Escape", b"\r": "Enter", b"\x03": "C-c", b"\x15": "C-u", b"X": "X (Shift+x)"}


def say(text):
    os.write(1, (text + "\r\n").encode())


def dialog():
    say("+------------------------------------------+")
    say("| You hit your weekly limit                |")
    say("|   > Buy more credits                     |")
    say("|     Try Again                            |")
    say("| Esc:scrollback   Shift+x:dismiss         |")
    say("+------------------------------------------+")


dismissed = False
dialog()
with open(log_path, "a") as log:
    log.write("ready\n")
    log.flush()
    try:
        while True:
            chunk = os.read(fd, 64)
            if not chunk:
                break
            log.write("got " + chunk.hex() + "\n")
            log.flush()
            name = NAMES.get(chunk, "bytes " + chunk.hex())
            if dismissed:
                say("[composer] received %s" % name)
            elif chunk == b"X":
                dismissed = True
                say("[key %s] dialog dismissed -> empty composer" % name)
                say("> _")
            elif chunk == b"\x1b":
                say("[key %s] focus -> scrollback; dialog stays" % name)
            elif chunk == b"\x03":
                say("[key %s] dialog stays" % name)
            else:
                say("[key %s] dialog stays" % name)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
