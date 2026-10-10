"""Koei Ls12 (LS11-family) archive reader used by Cao Cao Zhuan .e5 files."""
import struct, sys

class BitReader:
    __slots__ = ('d', 'pos', 'bit', 'end')
    def __init__(self, d, start, end):
        self.d = d; self.pos = start; self.bit = 7; self.end = end
    def get(self):
        b = (self.d[self.pos] >> self.bit) & 1
        self.bit -= 1
        if self.bit < 0:
            self.bit = 7; self.pos += 1
        return b
    def code(self):
        c1 = 0; n = 0
        while True:
            b = self.get()
            c1 = (c1 << 1) | b
            n += 1
            if b == 0:
                break
        c2 = 0
        for _ in range(n):
            c2 = (c2 << 1) | self.get()
        return c1 + c2

def decompress(d, dic, start, csize, usize):
    if csize == usize:
        return bytes(d[start:start + csize])
    br = BitReader(d, start, start + csize)
    out = bytearray()
    while len(out) < usize:
        c = br.code()
        if c < 256:
            out.append(dic[c])
        else:
            off = c - 256
            ln = br.code() + 3
            p = len(out) - off
            for i in range(ln):
                out.append(out[p + i])
    return bytes(out[:usize])

# The mod's seek hook (wagan.wa 0x4d2600) adds a fixed offset to every seek when a file does
# not start with 'Ls12': Yueyue.wa +0x500, ~zl1g.dat +0x7cc, ~kvr.db +0x2130, ~gtl.dll +0x18c,
# Buha +0x1f0, Giji +0x510, Ghai +0x4000, Nao +0x4000.
HIDDEN_OFFSETS = (0, 0x500, 0x7cc, 0x2130, 0x18c, 0x1f0, 0x510, 0x4000)

def read_archive(path_or_bytes):
    d = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else open(path_or_bytes, 'rb').read()
    if d[:4] not in (b'Ls12', b'LS11', b'LS12'):
        for o in HIDDEN_OFFSETS:
            if d[o:o + 4] == b'Ls12':
                d = d[o:]; break
    assert d[:4] in (b'Ls12', b'LS11', b'LS12'), d[:4]
    dic = d[16:16 + 256]
    off = 0x110
    entries = []
    while True:
        cs, us, o = struct.unpack('>III', d[off:off + 12])
        if cs == 0:
            break
        entries.append((cs, us, o))
        off += 12
    return [decompress(d, dic, o, cs, us) for cs, us, o in entries]

if __name__ == '__main__':
    for p in sys.argv[1:]:
        es = read_archive(p)
        print(p, len(es), [len(e) for e in es[:10]])
