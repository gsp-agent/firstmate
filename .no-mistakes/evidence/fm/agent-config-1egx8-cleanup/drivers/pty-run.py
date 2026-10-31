#!/usr/bin/env python3
"""Run one command line in an interactive bash on a real pty of a given size.

usage: pty-run.py <cols> <deadline-seconds> <command line>
The window size is set on the slave before the shell starts, and the master is
drained until the shell exits. Prints what the terminal showed.
"""
import fcntl
import os
import select
import struct
import sys
import termios
import time

cols, deadline, command = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, cols, 0, 0))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    if slave > 2:
        os.close(slave)
    os.environ["PS1"] = "pty$ "
    os.execvp("bash", ["bash", "--norc", "--noprofile", "-i"])
os.close(slave)
os.write(master, (command + "\nexit\n").encode())
end = time.time() + deadline
chunks = []
while time.time() < end:
    ready, _, _ = select.select([master], [], [], 1)
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
else:
    print("pty-run: deadline reached", flush=True)
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace").replace("\r", ""))
