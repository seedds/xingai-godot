"""Write game/assets/data/gbk.bin, the GBK (code page 936) table the game decodes and encodes text with at run time
(core/gbk.gd): Godot's own multibyte conversion needs the OS's iconv, which Android does not have.

Layout: for lead byte 0x81..0xFE and trail byte 0x40..0xFE (126 × 191 cells) a little-endian u16 Unicode code point,
0 where the pair is not a GBK character. Single bytes below 0x80 are ASCII.
usage: gbk_table.py
"""
import os, struct
_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = bytearray()
n = 0
for lead in range(0x81, 0xff):
    for trail in range(0x40, 0xff):
        try:
            c = bytes([lead, trail]).decode('gbk')
            cp = ord(c) if len(c) == 1 and ord(c) < 0x10000 else 0
        except UnicodeDecodeError:
            cp = 0
        n += cp != 0
        out += struct.pack('<H', cp)
path = os.path.join(_REPO, 'game/assets/data/gbk.bin')
with open(path, 'wb') as f:
    f.write(out)
with open(path + '.import', 'w') as f:
    f.write('[remap]\n\nimporter="keep"\n')
print(path, len(out), 'bytes,', n, 'characters')
