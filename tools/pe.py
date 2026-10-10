"""Tiny PE helper: VA<->offset, xref scan, disassembly via capstone."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import pefile, struct, sys, capstone, re
EXE = _REPO + '/wg2025/wagan.wa'
class PE:
    def __init__(self, path=EXE):
        self.pe = pefile.PE(path, fast_load=True)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.data = open(path, 'rb').read()
        self.secs = [(self.base + s.VirtualAddress, s.Misc_VirtualSize, s.PointerToRawData, s.SizeOfRawData, s.Name.rstrip(b'\0').decode(errors='replace')) for s in self.pe.sections]
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.md.detail = False
    def off(self, va):
        for v, vs, ro, rs, n in self.secs:
            if v <= va < v + max(vs, rs):
                if va - v < rs: return ro + va - v
                return None
        return None
    def va(self, off):
        for v, vs, ro, rs, n in self.secs:
            if ro <= off < ro + rs: return v + off - ro
    def read(self, va, n):
        o = self.off(va); return self.data[o:o + n]
    def u32(self, va): return struct.unpack('<I', self.read(va, 4))[0]
    def cstr(self, va, enc='gbk'):
        o = self.off(va); e = self.data.index(b'\0', o); return self.data[o:e].decode(enc, errors='replace')
    def xrefs(self, target):
        """find imm32/disp32 occurrences of target in code sections"""
        pat = struct.pack('<I', target); res = []
        for v, vs, ro, rs, n in self.secs:
            seg = self.data[ro:ro + rs]
            for m in re.finditer(re.escape(pat), seg):
                res.append(v + m.start())
        return res
    def calls_to(self, target):
        """find E8 rel32 calls to target"""
        res = []
        for v, vs, ro, rs, n in self.secs:
            if 'text' not in n: continue
            seg = self.data[ro:ro + rs]
            for i in range(len(seg) - 5):
                if seg[i] == 0xE8:
                    rel = struct.unpack('<i', seg[i+1:i+5])[0]
                    if v + i + 5 + rel == target: res.append(v + i)
        return res
    def dis(self, va, n=60, stop_ret=True):
        out = []
        code = self.read(va, n * 15)
        for i, ins in enumerate(self.md.disasm(code, va)):
            out.append('%08x  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str))
            if len(out) >= n or (stop_ret and ins.mnemonic == 'ret'): break
        return '\n'.join(out)
    def func_start(self, va, maxback=0x4000):
        """heuristic: scan back for common prologue 55 8b ec / after cc/c3 padding"""
        o = self.off(va)
        for k in range(o, o - maxback, -1):
            if self.data[k:k+3] == b'\x55\x8b\xec' and self.data[k-1] in (0xcc, 0xc3, 0x90, 0xc2, 0x00):
                return self.va(k)
            if self.data[k-1] in (0xcc,) and self.data[k-2] in (0xcc, 0xc3):
                return self.va(k)
if __name__ == '__main__':
    p = PE()
    for s in p.secs: print('%08x %08x %08x %08x %s' % s)
