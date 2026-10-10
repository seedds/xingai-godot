"""jmpsto.py lo hi : find E8/E9 rel32 (and 0F 8x jcc rel32) branches whose target is in [lo,hi)"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, struct
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
lo, hi = int(sys.argv[1], 16), int(sys.argv[2], 16)
for v, vs, ro, rs, n in p.secs:
    if 'text' not in n: continue
    seg = p.data[ro:ro + rs]
    for i in range(len(seg) - 6):
        b = seg[i]
        if b in (0xE8, 0xE9):
            t = v + i + 5 + struct.unpack('<i', seg[i+1:i+5])[0]
            if lo <= t < hi: print('%08x %s -> %08x' % (v + i, 'call' if b == 0xE8 else 'jmp', t))
        elif b == 0x0F and 0x80 <= seg[i+1] <= 0x8F:
            t = v + i + 6 + struct.unpack('<i', seg[i+2:i+6])[0]
            if lo <= t < hi: print('%08x jcc -> %08x' % (v + i, t))
