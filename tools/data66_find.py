"""RE helper for the data track: find strings / xrefs / calls in orig/Ekd5.exe.
usage: data66_find.py str TEXT | x HEXVA | call HEXVA | bytes HEX"""
import os, sys, re, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE
p = PE()
cmd, arg = sys.argv[1], sys.argv[2]
if cmd == 'str':
    for enc in ('gbk', 'ascii'):
        try: pat = arg.encode(enc)
        except Exception: continue
        for m in re.finditer(re.escape(pat), p.data):
            print(enc, hex(p.va(m.start()) or 0), hex(m.start()))
        break
elif cmd == 'x':
    for a in p.xrefs(int(arg, 16)): print(hex(a))
elif cmd == 'call':
    for a in p.calls_to(int(arg, 16)): print(hex(a))
elif cmd == 'bytes':
    pat = bytes.fromhex(arg)
    for m in re.finditer(re.escape(pat), p.data): print(hex(p.va(m.start()) or 0))
