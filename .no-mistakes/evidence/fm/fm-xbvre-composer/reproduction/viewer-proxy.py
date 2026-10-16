import errno,fcntl,os,select,signal,struct,subprocess,sys,termios
from pathlib import Path
root=Path(__file__).resolve().parent
session=(root/'session').read_text().strip()
real='/Users/dalecarman/.local/bin/herdr'
if sys.argv[1:]!=['--session',session]:
    os.execv(real,[real,*sys.argv[1:]])
master,slave=os.openpty()
fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',60,140,0,0))
def setup():
    os.setsid()
    fcntl.ioctl(slave,termios.TIOCSCTTY,0)
p=subprocess.Popen([real,'--session',session],stdin=slave,stdout=slave,stderr=slave,preexec_fn=setup,env={**os.environ,'TERM':'xterm-256color'})
os.close(slave)
fifo=root/'viewer-input'
fd=os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
log=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4/viewer-output.ansi').open('wb')
def stop(sig,frame):
    p.send_signal(sig)
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
try:
    while p.poll() is None:
        ready,_,_=select.select([master,fd],[],[],0.5)
        if fd in ready:
            data=os.read(fd,65536)
            if data: os.write(master,data)
        if master in ready:
            try: data=os.read(master,65536)
            except OSError as exc:
                if exc.errno==errno.EIO: break
                raise
            if not data: break
            log.write(data); log.flush()
            os.write(1,data)
finally:
    if p.poll() is None:
        p.terminate()
    p.wait(timeout=5)
    os.close(master); os.close(fd); log.close()
