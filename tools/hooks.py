"""list E8/E9 rel32 branches from .text into .text2 (mod hooks) and non-zero code runs in .text2"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, struct
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
t = p.read(0x401000, 0x84e00)
hooks = []
for i in range(len(t) - 5):
    if t[i] in (0xE8, 0xE9):
        rel = struct.unpack('<i', t[i+1:i+5])[0]
        tgt = 0x401000 + i + 5 + rel
        if 0x4d0000 <= tgt < 0x555000:
            hooks.append((0x401000 + i, 'call' if t[i] == 0xE8 else 'jmp', tgt))
for h in hooks: print('%08x %s %08x' % h)
print(len(hooks), 'hooks;', len(set(h[2] for h in hooks)), 'targets')
