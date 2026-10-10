"""rawview.py archive idx[,idx..] width out.png [palette_archive:idx | gray] [offset]
Render raw 8bpp entries side by side (each as width x N)."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from ls12 import read_archive
from PIL import Image
arc, idxs, w, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
palspec = sys.argv[5] if len(sys.argv) > 5 else 'gray'
off = int(sys.argv[6]) if len(sys.argv) > 6 else 0
es = read_archive(arc) if not arc.lower().split('/')[-1].startswith('hm') else [open(arc, 'rb').read()]
if palspec == 'gray':
    pal = bytes(sum(([i, i, i] for i in range(256)), []))
else:
    pa, pi = palspec.rsplit(':', 1)
    pal = read_archive(pa)[int(pi)]
    pal = pal + bytes(768 - len(pal))
if '-' in idxs:
    a, b = idxs.split('-'); idl = list(range(int(a), int(b) + 1))
else:
    idl = [int(x) for x in idxs.split(',')]
ims = []
for i in idl:
    d = es[i][off:]
    h = len(d) // w
    im = Image.frombytes('P', (w, h), bytes(d[:w * h])); im.putpalette(pal)
    ims.append(im.convert('RGB'))
W = sum(im.width + 4 for im in ims); H = max(im.height for im in ims)
S = Image.new('RGB', (W, H), (255, 0, 255))
x = 0
for im in ims:
    S.paste(im, (x, 0)); x += im.width + 4
S.save(out); print(S.size)
