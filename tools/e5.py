"""Reading the 6.6 engine's .e5 files: lazy Ls12 archives and the picture formats stored in their entries.

Ls12 = Koei's LS11-family archive (see ls12.py for the bit-level decompressor). The 6.6 files are plain Ls12 at
offset 0; Unit_*.e5 use the header variant "Ls12\\0\\0\\0\\0". Mmap.e5 is ~490 MB, so entries are read on demand.

Entries hold one of: a BMP (24-bit, bottom-up or top-down), a JPEG, a PNG, or raw 8-bit pixels in the original
CCZ layout (size known from context). 24-bit pictures use the colour key (247,0,255) for transparency.
"""
import io, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ls12 import decompress
import numpy as np
from PIL import Image

KEY = (247, 0, 255)          # transparent colour of the 24-bit pictures


class Archive:
    """Lazy Ls12 reader: len(a), a[i] -> bytes (decompressed)."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        head = self.f.read(0x110)
        assert head[:4] in (b'Ls12', b'LS11', b'LS12'), (path, head[:4])
        self.dic = head[16:16 + 256]
        self.entries = []                      # (csize, usize, offset)
        while True:
            cs, us, o = struct.unpack('>III', self.f.read(12))
            if cs == 0:
                break
            self.entries.append((cs, us, o))

    def __len__(self):
        return len(self.entries)

    def size(self, i):
        return self.entries[i][1]

    def __getitem__(self, i):
        cs, us, o = self.entries[i]
        self.f.seek(o)
        raw = self.f.read(cs)
        return decompress(raw, self.dic, 0, cs, us)

    def __iter__(self):
        for i in range(len(self)):
            yield self[i]


def kind(b):
    """'bmp' | 'jpg' | 'png' | 'raw' for an entry's bytes."""
    if b[:2] == b'BM':
        return 'bmp'
    if b[:3] == b'\xff\xd8\xff':
        return 'jpg'
    if b[:8] == b'\x89PNG\r\n\x1a\n':
        return 'png'
    return 'raw'


def open_image(b):
    """PIL image of a BMP/JPEG/PNG entry (None for raw 8-bit data). Trailing bytes are ignored."""
    k = kind(b)
    if k == 'raw':
        return None
    im = Image.open(io.BytesIO(b))
    im.load()
    return im


def keyed(im, key=KEY):
    """RGBA copy with the colour key made transparent."""
    a = np.array(im.convert('RGBA'))
    hit = (a[:, :, 0] == key[0]) & (a[:, :, 1] == key[1]) & (a[:, :, 2] == key[2])
    a[hit] = (0, 0, 0, 0)
    return Image.fromarray(a, 'RGBA')


def raw8(b, w, h, palette, transparent0=True, offset=0):
    """RGBA image of raw 8-bit pixels (row-major) with a 256-entry [(r,g,b)] palette; index 0 transparent."""
    im = Image.frombytes('P', (w, h), bytes(b[offset:offset + w * h]).ljust(w * h, b'\0'))
    flat = []
    for r, g, b_ in palette:
        flat += [r, g, b_]
    im.putpalette(flat)
    out = im.convert('RGBA')
    if transparent0:
        mask = im.point(lambda v: 0 if v == 0 else 255)
        out.putalpha(mask)
    return out


def exe_palette(exe_path, file_offset=0x9D3C0):
    """The engine's standard 256-colour palette stored in Ekd5.exe as 256 RGBQUADs (B,G,R,0). Entry 10 is
    (255,140,99), the same colour as wg2025's Fei.WA[0] entry 10 (stored there as B,R,G). Returns [(r,g,b)]."""
    with open(exe_path, 'rb') as f:
        f.seek(file_offset)
        d = f.read(1024)
    return [(d[4 * i + 2], d[4 * i + 1], d[4 * i]) for i in range(256)]


if __name__ == '__main__':
    # usage: e5.py FILE [FIRST N]   -- list entries: index, size, kind, picture size
    a = Archive(sys.argv[1])
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    n = int(sys.argv[3]) if len(sys.argv) > 3 else len(a)
    print(sys.argv[1], len(a), 'entries')
    for i in range(first, min(len(a), first + n)):
        b = a[i]
        k = kind(b)
        im = open_image(b) if k != 'raw' else None
        print('%4d %9d %s %s' % (i, len(b), k, '%dx%d %s' % (im.width, im.height, im.mode) if im else ''))
