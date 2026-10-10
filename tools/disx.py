"""usage: dis.py VA [n] [noret]  -- disassemble wagan.wa with simple annotations"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
a = sys.argv[1]
def sync_start(t, back=0x60):
    # earliest start in [t-back, t) whose linear decode lands exactly on t
    for st in range(t - back, t):
        addrs = set(); ok = False
        for ins in p.md.disasm(p.read(st, t - st + 16), st):
            if ins.address <= t < ins.address + ins.size: ok = True; break
            if ins.address > t: break
        if ok: return st
    return t
if a.startswith('f:'): va = p.func_start(int(a[2:], 16))
elif a.startswith('a:'): va = sync_start(int(a[2:], 16))
else: va = int(a, 16)
print('; start %x' % va); n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
stop = not (len(sys.argv) > 3 and sys.argv[3] == 'noret')
code = p.read(va, n * 15)
cnt = 0
for ins in p.md.disasm(code, va):
    s = '%08x  %-6s %s' % (ins.address, ins.mnemonic, ins.op_str)
    print(s)
    cnt += 1
    if cnt >= n or (stop and ins.mnemonic == 'ret'): break
