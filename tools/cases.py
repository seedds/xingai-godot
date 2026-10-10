"""usage: cases.py TABLE_VA N [maxins] -- disassemble each target of a jump table (stops at jmp-out/ret)."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.append(_os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
p = PE()
tab = int(sys.argv[1], 16); n = int(sys.argv[2]); mx = int(sys.argv[3]) if len(sys.argv) > 3 else 40
for i in range(n):
    t = p.u32(tab + 4 * i)
    print('== case %d -> %x' % (i, t))
    k = 0
    for ins in p.md.disasm(p.read(t, mx * 15), t):
        print('  %08x  %-6s %s' % (ins.address, ins.mnemonic, ins.op_str))
        k += 1
        if ins.mnemonic in ('ret',) or (ins.mnemonic == 'jmp') or k >= mx: break
