from pathlib import Path
import re
from PIL import Image,ImageDraw,ImageFont
base=Path('/Users/dalecarman/.no-mistakes/evidence/01M539H80Q1AK9PQ932W6F81V4')
font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',14)
ansi=re.compile(r'(\x1b\[[0-?]*[ -/]*[@-~])')
plain=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
colors=['#161b22','#f85149','#7ee787','#e3b341','#79c0ff','#d2a8ff','#76e3ea','#c9d1d9','#6e7681','#ffa198','#aff5b4','#f8e3a1','#a5d6ff','#d2a8ff','#a5f3fc','#ffffff']
for name,path in [('empty-scrolled-terminal','empty-scrolled-visible-ansi.txt'),('empty-current-terminal','empty-scrolled-capture.txt'),('draft-current-terminal','draft-scrolled-capture.txt'),('exit-popup-terminal','exit-popup-capture.txt'),('slash-popup-terminal','slash-popup-capture.txt')]:
    s=(base/path).read_text()
    lines=s.splitlines()
    cols=max(len(plain.sub('',line)) for line in lines)
    cw=float(font.getlength('M')); lh=20
    im=Image.new('RGB',(round(cw*cols)+32,len(lines)*lh+32),'#0c0c0c')
    d=ImageDraw.Draw(im)
    fg='#dddddd'; bg='#0c0c0c'; dim=False; inverse=False
    for y,line in enumerate(lines):
        x=16
        for seg in ansi.split(line):
            if seg.startswith('\x1b['):
                if not seg.endswith('m'): continue
                codes=[int(x or 0) for x in seg[2:-1].split(';')]; i=0
                while i<len(codes):
                    c=codes[i]
                    if c==0: fg='#dddddd'; bg='#0c0c0c'; dim=False; inverse=False
                    elif c==2: dim=True
                    elif c==22: dim=False
                    elif c==7: inverse=True
                    elif c==27: inverse=False
                    elif 30<=c<=37: fg=colors[c-30]
                    elif 90<=c<=97: fg=colors[c-90+8]
                    elif c==39: fg='#dddddd'
                    elif c in (38,48) and i+4<len(codes) and codes[i+1]==2:
                        value=tuple(codes[i+2:i+5]); i+=4
                        if c==38: fg=value
                        else: bg=value
                    i+=1
                continue
            if not seg: continue
            color=fg; back=bg
            if inverse: color,back=back,color
            if isinstance(color,str): color=tuple(int(color.lstrip('#')[j:j+2],16) for j in (0,2,4))
            if dim: color=tuple(int(v*.55) for v in color)
            width=float(font.getlength(seg))
            d.rectangle((x,16+y*lh,x+width,16+(y+1)*lh),fill=back)
            d.text((x,16+y*lh),seg,font=font,fill=color,anchor='lt')
            x+=width
    im.save(base/(name+'.png'))
    print(name+'.png',im.size)
