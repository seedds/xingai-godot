"""Linear-sweep instruction grep over Ekd5.exe's code (.code 0x401000.. and the 6.6 code in .text1/.text3).
usage: data66_ins.py REGEX [ctx]       (cache: $DATA66_CACHE or /tmp/data66_ins.pkl)
The sweep also decodes data inside those sections as junk; check hits with tools/disx.py."""
import os, sys, re, pickle
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE
CACHE = os.environ.get('DATA66_CACHE', '/tmp/data66_ins.pkl')
RANGES = ((0x401000, 0x84e00), (0x486000, 0x4800), (0x4be000, 0xf600), (0x4ce000, 0x64000))


def load():
    if os.path.exists(CACHE):
        return pickle.load(open(CACHE, 'rb'))
    p = PE()
    out = []
    for base, size in RANGES:
        code = p.read(base, size)
        off = 0
        while off < size:
            for ins in p.md.disasm(code[off:], base + off):
                out.append((ins.address, ins.mnemonic, ins.op_str))
                off = ins.address - base + ins.size
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
                    print('%s%08x  %-6s %s' % ('>' if j == i else ' ', *ins[j]))
                print('--')
            else:
                print('%08x  %-6s %s' % (a, m, o))
