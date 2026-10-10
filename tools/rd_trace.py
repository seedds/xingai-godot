"""Recursive-descent listing of a code path in wagan.wa that follows jmp chains across .text/.text2.
usage: rd_trace.py VA [maxins]   -- prints basic blocks in DFS order (fallthrough/jmp-target first)."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, re
sys.path.append(_os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
start = int(sys.argv[1], 16); maxins = int(sys.argv[2]) if len(sys.argv) > 2 else 600
seen = set(); out = []; pending = [start]; count = 0
def dis1(va):
    code = p.read(va, 16)
    for ins in p.md.disasm(code, va):
        return ins
    return None
while pending and count < maxins:
    va = pending.pop()
    if va in seen: continue
    out.append('L_%x:' % va)
    while count < maxins:
        if va in seen:
            out.append('    -> goto L_%x' % va); break
        seen.add(va)
        ins = dis1(va)
        if ins is None:
            out.append('    ?? %x' % va); break
        count += 1
        m, o = ins.mnemonic, ins.op_str
        if m == 'nop':
            va += ins.size; continue
        out.append('  %08x  %-6s %s' % (va, m, o))
        nxt = va + ins.size
        if m == 'jmp':
            if re.fullmatch(r'0x[0-9a-f]+', o):
                va = int(o, 16); continue
            break
        if m.startswith('j') or m == 'loop':
            if re.fullmatch(r'0x[0-9a-f]+', o):
                pending.append(int(o, 16))
            va = nxt; continue
        if m in ('ret', 'retf', 'int3'):
            break
        va = nxt
print('\n'.join(out))
