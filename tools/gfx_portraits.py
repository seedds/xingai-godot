"""Portraits -> gfx/portraits/{large,small,classic}/FFF.png + index.json

* large   = sge.wa RT_BITMAP 301+f (120x120, 24-bit, black = transparent via TransparentBlt)
* small   = sge.wa RT_BITMAP 2301+f (80x80, sparse)
* classic = Nao.wa entry f (64x80 8bpp, palette DeDe.WA[0]) - original CCZ Face.e5 code paths
f is the *resolved* face index from GetFace (0x4075a7): pid 0 -> person.face, others person.face+7,
with story-dependent overrides for persons 1/4/8/35 (see docs/gfx.md section 4).
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import os, sys, json
sys.path.append(_os.path.dirname(_os.path.abspath(__file__)))
from dllbmp import bitmaps, to_image
import ls12, gfxpal
from PIL import Image, ImageFile

ROOT = _REPO + '/wg2025/'


def _black_to_alpha(im):
    im = im.convert('RGBA')
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if r == 0 and g == 0 and b == 0:
                px[x, y] = (0, 0, 0, 0)
    return im


def convert(out, quantize=False):
    out = out.rstrip('/') + '/portraits'
    for sub in ('large', 'small', 'classic'):
        os.makedirs(out + '/' + sub, exist_ok=True)
    large, small, classic = [], [], []
    for name, raw in bitmaps(ROOT + 'sge.wa'):
        rid = int(name)
        ImageFile.LOAD_TRUNCATED_IMAGES = True   # bitmap 780 is truncated inside the DLL
        im = to_image(raw); im.load()
        ImageFile.LOAD_TRUNCATED_IMAGES = False
        im = _black_to_alpha(im.convert('RGB'))
        if 301 <= rid < 2301:
            f = rid - 301; im.save('%s/large/%03d.png' % (out, f)); large.append(f)
        elif rid >= 2301:
            f = rid - 2301; im.save('%s/small/%03d.png' % (out, f)); small.append(f)
    pal = gfxpal.flat(gfxpal.load('DeDe.WA', 0, quantize))
    for f, e in enumerate(ls12.read_archive(ROOT + 'Nao.wa')):
        im = Image.frombytes('P', (64, 80), e[:5120])
        im.putpalette(pal)
        im.convert('RGB').save('%s/classic/%03d.png' % (out, f)); classic.append(f)
    faces = {}
    for f in sorted(set(large) | set(small) | set(classic)):
        faces[str(f)] = [('large/%03d.png' if f in large else 'small/%03d.png' if f in small else 'classic/%03d.png') % f]
    json.dump({'large': 'large/%03d.png', 'small': 'small/%03d.png', 'classic': 'classic/%03d.png',
               'sizes': {'large': [120, 120], 'small': [80, 80], 'classic': [64, 80]},
               'large_faces': sorted(large), 'small_faces': sorted(small), 'classic_count': len(classic),
               'faces': faces,
               'face_index_rule': 'f = GetFace(person) 0x4075a7: pid0 -> face; pid1/4/8/35 story overrides; else face+7'},
              open(out + '/index.json', 'w'), indent=0)
    return {'large': len(large), 'small': len(small), 'classic': len(classic)}


if __name__ == '__main__':
    print(convert(sys.argv[1] if len(sys.argv) > 1 else _REPO + '/game/assets/gfx'))
