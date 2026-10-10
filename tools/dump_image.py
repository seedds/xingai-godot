"""Dump Ekd5.exe (the 6.6 engine) into one flat little-endian memory image starting at 0x400000, the way the
Windows loader maps it: PE header page at 0x400000, then every section at its virtual address, its raw data copied
and the rest of its virtual size zero-filled. The Godot port's emulated memory (game/src/core/mem.gd) loads it.

usage: tools/venv/bin/python -I tools/dump_image.py [EXE] [OUT]
  EXE defaults to <repo>/orig/Ekd5.exe (read-only input; only parsed, never executed)
  OUT defaults to <repo>/game/assets/data/exe_image.bin

Extent (Ekd5.exe of 新改曹操傳 6.6 修正版): 0x400000 .. 0x542800 (0x142800 bytes)
  .code  0x401000 vsz 0x85000   raw 0x84e00   original CCZ code, ~83% rewritten in place by the 6.6 engine
  .text1 0x486000 vsz 0x5000    raw 0x4800    imports / constant data (CCZ .rdata)
  .text2 0x48b000 vsz 0x33000   raw 0x6800    CCZ .data + BSS (everything from 0x491800 on is zero-filled BSS)
  .api   0x4be000 vsz 0x10000   raw 0xf600    6.6: new imports, option strings, effect / skill name tables
  .text3 0x4ce000 vsz 0x64000   raw 0x64000   6.6: heap pointers, extension tables, EV/PT, sprite tables
  .rsrc  0x532000 vsz 0x10764   raw 0x10800   resources (the image keeps the full raw size, up to 0x542800)
See docs/memory.md for what lives where.
"""
import os
import struct
import sys

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else _REPO + '/orig/Ekd5.exe'
DST = sys.argv[2] if len(sys.argv) > 2 else _REPO + '/game/assets/data/exe_image.bin'


def sections(data):
    """Image base, header size and (name, rva, vsize, raw_off, raw_size) of each section."""
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0'
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    optsz = struct.unpack_from('<H', data, pe + 20)[0]
    opt = pe + 24
    base = struct.unpack_from('<I', data, opt + 28)[0]
    hdrsz = struct.unpack_from('<I', data, opt + 60)[0]
    out = []
    for i in range(nsec):
        o = opt + optsz + 40 * i
        name = data[o:o + 8].split(b'\0')[0].decode('latin-1')
        vsz, va, rsz, roff = struct.unpack_from('<IIII', data, o + 8)
        out.append((name, va, vsz, roff, rsz))
    return base, hdrsz, out


def main():
    data = open(SRC, 'rb').read()
    base, hdrsz, secs = sections(data)
    assert base == 0x400000, hex(base)
    end = max(va + max(vsz, rsz) for _, va, vsz, _, rsz in secs)
    img = bytearray(end)
    img[0:hdrsz] = data[0:hdrsz]
    for name, va, vsz, roff, rsz in secs:
        img[va:va + rsz] = data[roff:roff + rsz]
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, 'wb') as f:
        f.write(bytes(img))
    for name, va, vsz, roff, rsz in secs:
        print('%-6s %08x vsz %06x raw %06x' % (name, base + va, vsz, rsz))
    print('image %08x .. %08x (%d bytes) -> %s' % (base, base + end, end, DST))


if __name__ == '__main__':
    main()
