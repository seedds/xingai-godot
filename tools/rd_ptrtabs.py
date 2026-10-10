"""find tables of consecutive dword pointers to GBK strings in .data of wagan.wa"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, struct
sys.path.append(_os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
lo, hi = int(sys.argv[1], 16), int(sys.argv[2], 16)
def isstr(va):
    o = p.off(va)
    if o is None: return None
    try:
        e = p.data.index(b'\0', o)
    except ValueError: return None
    s = p.data[o:e]
    if not (1 <= len(s) < 80): return None
    try: t = s.decode('gbk')
    except: return None
    if not any(ord(c) > 0x2e80 for c in t): return None
    return t
va = lo
while va < hi:
    run = []
    v = va
    while True:
        ptr = p.u32(v)
        t = isstr(ptr)
        if t is None: break
        run.append((v, ptr, t)); v += 4
    if len(run) >= 3:
        xr = p.xrefs(va)
        print('TABLE %08x n=%d xrefs=%s' % (va, len(run), [hex(x) for x in xr][:8]))
        print('   ' + ' | '.join('%d:%s' % (i, t) for i, (a, pp, t) in enumerate(run)))
        va = v
    else:
        va += 4
