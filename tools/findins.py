"""linear-sweep disassemble .text and .text2, print instructions matching a regex. usage: findins.py REGEX [ctx]"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, re, pickle, os
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
CACHE = _REPO + '/extract/ins_cache.pkl'
def load():
    if os.path.exists(CACHE):
        return pickle.load(open(CACHE, 'rb'))
    p = PE()
    out = []
    for base, size in ((0x401000, 0x84e00), (0x4d0000, 0x58400)):
        code = p.read(base, size)
        off = 0
        while off < size:
            got = False
            for ins in p.md.disasm(code[off:], base + off):
                out.append((ins.address, ins.mnemonic, ins.op_str))
                off = ins.address - base + ins.size
                got = True
            if off < size:
                out.append((base + off, 'db', '%02x' % code[off])); off += 1
    pickle.dump(out, open(CACHE, 'wb'))
    return out
if __name__ == '__main__':
    ins = load()
    rx = re.compile(sys.argv[1]); ctx = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    for i, (a, m, o) in enumerate(ins):
        if rx.search(m + ' ' + o):
            if ctx:
                for j in range(max(0, i - ctx), min(len(ins), i + ctx + 1)):
                    print('%08x  %-6s %s%s' % (ins[j][0], ins[j][1], ins[j][2], '   <==' if j == i else ''))
                print('--')
            else:
                print('%08x  %-6s %s' % (a, m, o))
