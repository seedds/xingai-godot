"""Tiny concrete x86-32 emulator over wagan.wa's image (subset of instructions), used to
evaluate small pure-ish functions (range-shape builders etc.).  Not a general emulator.

usage (as module):
    from rd_emu import Emu
    e = Emu(); e.hooks[0x437a04] = callback(emu, args) -> retval   # stdcall/cdecl handled by caller pops
    e.call(func_va, [args...], ecx=..)  -> eax
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, struct
sys.path.append(_os.path.dirname(_os.path.abspath(__file__)))
from pe import PE
import capstone
from capstone import x86

MASK = 0xffffffff


class Stop(Exception):
    pass


class Emu:
    def __init__(self):
        self.p = PE()
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.md.detail = True
        self.mem = {}          # byte-addressed overrides
        self.r = dict(eax=0, ebx=0, ecx=0, edx=0, esi=0, edi=0, ebp=0, esp=0x7ff000)
        self.f = dict(cf=0, zf=0, sf=0, of=0)
        self.hooks = {}
        self.trace = False
        self.icache = {}
        self.steps = 0
        self.max_steps = 2_000_000

    # ---------------- memory
    def rb(self, a):
        a &= MASK
        if a in self.mem:
            return self.mem[a]
        o = self.p.off(a)
        if o is None:
            return 0
        return self.p.data[o]

    def rd(self, a, n):
        v = 0
        for i in range(n):
            v |= self.rb(a + i) << (8 * i)
        return v

    def wr(self, a, v, n):
        for i in range(n):
            self.mem[(a + i) & MASK] = (v >> (8 * i)) & 0xff

    # ---------------- registers
    REG32 = {'eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'ebp', 'esp'}

    def getreg(self, name):
        if name in self.REG32:
            return self.r[name]
        if name in ('ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp', 'sp'):
            return self.r['e' + name] & 0xffff
        if name in ('al', 'bl', 'cl', 'dl'):
            return self.r['e' + name[0] + 'x'] & 0xff
        if name in ('ah', 'bh', 'ch', 'dh'):
            return (self.r['e' + name[0] + 'x'] >> 8) & 0xff
        raise ValueError(name)

    def setreg(self, name, v):
        if name in self.REG32:
            self.r[name] = v & MASK; return
        if name in ('ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp', 'sp'):
            k = 'e' + name; self.r[k] = (self.r[k] & 0xffff0000) | (v & 0xffff); return
        if name in ('al', 'bl', 'cl', 'dl'):
            k = 'e' + name[0] + 'x'; self.r[k] = (self.r[k] & 0xffffff00) | (v & 0xff); return
        if name in ('ah', 'bh', 'ch', 'dh'):
            k = 'e' + name[0] + 'x'; self.r[k] = (self.r[k] & 0xffff00ff) | ((v & 0xff) << 8); return
        raise ValueError(name)

    def ea(self, ins, op):
        m = op.mem
        a = m.disp
        if m.base: a += self.getreg(ins.reg_name(m.base))
        if m.index: a += self.getreg(ins.reg_name(m.index)) * m.scale
        return a & MASK

    def get(self, ins, op):
        if op.type == x86.X86_OP_REG:
            return self.getreg(ins.reg_name(op.reg))
        if op.type == x86.X86_OP_IMM:
            return op.imm & ((1 << (op.size * 8)) - 1) if op.size else op.imm & MASK
        return self.rd(self.ea(ins, op), op.size)

    def put(self, ins, op, v):
        if op.type == x86.X86_OP_REG:
            self.setreg(ins.reg_name(op.reg), v)
        else:
            self.wr(self.ea(ins, op), v, op.size)

    def push(self, v):
        self.r['esp'] = (self.r['esp'] - 4) & MASK
        self.wr(self.r['esp'], v, 4)

    def pop(self):
        v = self.rd(self.r['esp'], 4)
        self.r['esp'] = (self.r['esp'] + 4) & MASK
        return v

    # ---------------- flags
    def flags_logic(self, res, bits):
        m = (1 << bits) - 1; res &= m
        self.f.update(cf=0, of=0, zf=int(res == 0), sf=(res >> (bits - 1)) & 1)

    def flags_add(self, a, b, bits, carry=0):
        m = (1 << bits) - 1
        res = a + b + carry
        self.f['cf'] = int(res > m)
        r = res & m
        sa, sb, sr = a >> (bits - 1) & 1, b >> (bits - 1) & 1, r >> (bits - 1) & 1
        self.f['of'] = int(sa == sb and sr != sa)
        self.f['zf'] = int(r == 0); self.f['sf'] = sr
        return r

    def flags_sub(self, a, b, bits, borrow=0):
        m = (1 << bits) - 1
        res = a - b - borrow
        self.f['cf'] = int(res < 0)
        r = res & m
        sa, sb, sr = a >> (bits - 1) & 1, b >> (bits - 1) & 1, r >> (bits - 1) & 1
        self.f['of'] = int(sa != sb and sr != sa)
        self.f['zf'] = int(r == 0); self.f['sf'] = sr
        return r

    def cond(self, cc):
        f = self.f
        return {
            'o': f['of'], 'no': not f['of'], 'b': f['cf'], 'ae': not f['cf'], 'e': f['zf'], 'ne': not f['zf'],
            'be': f['cf'] or f['zf'], 'a': not (f['cf'] or f['zf']), 's': f['sf'], 'ns': not f['sf'],
            'l': f['sf'] != f['of'], 'ge': f['sf'] == f['of'], 'le': f['zf'] or f['sf'] != f['of'],
            'g': (not f['zf']) and f['sf'] == f['of'],
        }[cc]

    def decode(self, va):
        if va in self.icache: return self.icache[va]
        code = bytes(self.rb(va + i) for i in range(16))
        ins = next(self.md.disasm(code, va))
        self.icache[va] = ins
        return ins

    # ---------------- run
    def call(self, va, args=(), ecx=None, edx=None, eax=None):
        RET = 0xdead0000
        for a in reversed(args): self.push(a)
        self.push(RET)
        if ecx is not None: self.r['ecx'] = ecx
        if edx is not None: self.r['edx'] = edx
        if eax is not None: self.r['eax'] = eax
        eip = va
        while eip != RET:
            eip = self.step(eip)
        return self.r['eax']

    def step(self, eip):
        self.steps += 1
        if self.steps > self.max_steps: raise Stop('step limit')
        if eip in self.hooks:
            # hook emulates the callee: called with return address on stack
            ret = self.pop()
            res = self.hooks[eip](self)
            if isinstance(res, tuple): v, popn = res
            else: v, popn = res, 0
            if v is not None: self.r['eax'] = v & MASK
            self.r['esp'] = (self.r['esp'] + popn) & MASK
            return ret
        ins = self.decode(eip)
        nxt = eip + ins.size
        m = ins.mnemonic; ops = ins.operands
        if self.trace: print('%08x %s %s' % (eip, m, ins.op_str))
        if m in ('nop', 'int3', 'wait'):  # int3 as padding
            return nxt
        if m == 'push':
            v = self.get(ins, ops[0]); self.push(v & MASK if ops[0].size == 4 or ops[0].type == x86.X86_OP_IMM else v); return nxt
        if m == 'pop':
            self.put(ins, ops[0], self.pop()); return nxt
        if m == 'mov':
            self.put(ins, ops[0], self.get(ins, ops[1])); return nxt
        if m == 'movzx':
            self.put(ins, ops[0], self.get(ins, ops[1])); return nxt
        if m == 'movsx':
            v = self.get(ins, ops[1]); b = ops[1].size * 8
            if v >> (b - 1) & 1: v -= 1 << b
            self.put(ins, ops[0], v & MASK); return nxt
        if m == 'lea':
            self.put(ins, ops[0], self.ea(ins, ops[1])); return nxt
        bits = ops[0].size * 8 if ops else 32
        if m in ('add', 'adc'):
            a, b = self.get(ins, ops[0]), self.get(ins, ops[1])
            if b < 0: b &= (1 << bits) - 1
            self.put(ins, ops[0], self.flags_add(a, b, bits, self.f['cf'] if m == 'adc' else 0)); return nxt
        if m in ('sub', 'sbb', 'cmp'):
            a, b = self.get(ins, ops[0]), self.get(ins, ops[1])
            if b < 0: b &= (1 << bits) - 1
            r = self.flags_sub(a, b, bits, self.f['cf'] if m == 'sbb' else 0)
            if m != 'cmp': self.put(ins, ops[0], r)
            return nxt
        if m in ('and', 'or', 'xor', 'test'):
            a, b = self.get(ins, ops[0]), self.get(ins, ops[1]) & ((1 << bits) - 1)
            r = a & b if m in ('and', 'test') else (a | b if m == 'or' else a ^ b)
            self.flags_logic(r, bits)
            if m != 'test': self.put(ins, ops[0], r)
            return nxt
        if m in ('inc', 'dec'):
            cf = self.f['cf']
            a = self.get(ins, ops[0])
            r = self.flags_add(a, 1, bits) if m == 'inc' else self.flags_sub(a, 1, bits)
            self.f['cf'] = cf
            self.put(ins, ops[0], r); return nxt
        if m == 'neg':
            a = self.get(ins, ops[0])
            r = self.flags_sub(0, a, bits); self.f['cf'] = int(a != 0)
            self.put(ins, ops[0], r); return nxt
        if m == 'not':
            self.put(ins, ops[0], ~self.get(ins, ops[0])); return nxt
        if m in ('shl', 'sal', 'shr', 'sar'):
            a = self.get(ins, ops[0]); c = (self.get(ins, ops[1]) if len(ops) > 1 else 1) & 31
            mk = (1 << bits) - 1
            if c == 0: return nxt
            if m in ('shl', 'sal'):
                r = (a << c) & mk; self.f['cf'] = (a >> (bits - c)) & 1
            elif m == 'shr':
                r = a >> c; self.f['cf'] = (a >> (c - 1)) & 1
            else:
                sa = a - (1 << bits) if a >> (bits - 1) & 1 else a
                r = (sa >> c) & mk; self.f['cf'] = (sa >> (c - 1)) & 1
            self.f['zf'] = int(r == 0); self.f['sf'] = (r >> (bits - 1)) & 1
            self.put(ins, ops[0], r); return nxt
        if m == 'imul':
            def s(v, b):
                return v - (1 << b) if v >> (b - 1) & 1 else v
            if len(ops) == 3:
                r = s(self.get(ins, ops[1]), bits) * s(ops[2].imm & ((1 << bits) - 1), bits)
                self.put(ins, ops[0], r & ((1 << bits) - 1))
            elif len(ops) == 2:
                r = s(self.get(ins, ops[0]), bits) * s(self.get(ins, ops[1]), bits)
                self.put(ins, ops[0], r & ((1 << bits) - 1))
            else:
                r = s(self.r['eax'], 32) * s(self.get(ins, ops[0]), 32)
                self.r['eax'] = r & MASK; self.r['edx'] = (r >> 32) & MASK
            return nxt
        if m == 'mul':
            r = self.r['eax'] * self.get(ins, ops[0])
            self.r['eax'] = r & MASK; self.r['edx'] = (r >> 32) & MASK; return nxt
        if m in ('div', 'idiv'):
            d = self.get(ins, ops[0])
            n = (self.r['edx'] << 32) | self.r['eax']
            if m == 'idiv':
                if n >> 63: n -= 1 << 64
                if d >> 31: d -= 1 << 32
                q = abs(n) // abs(d) * (1 if (n >= 0) == (d >= 0) else -1)
                rem = n - q * d
            else:
                q, rem = divmod(n, d)
            self.r['eax'] = q & MASK; self.r['edx'] = rem & MASK; return nxt
        if m == 'cdq':
            self.r['edx'] = MASK if self.r['eax'] >> 31 else 0; return nxt
        if m.startswith('set'):
            self.put(ins, ops[0], int(bool(self.cond(m[3:])))); return nxt
        if m == 'jmp':
            if ops[0].type == x86.X86_OP_IMM: return ops[0].imm & MASK
            return self.get(ins, ops[0])
        if m.startswith('j') and m != 'jmp':
            cc = m[1:]
            cc = {'z': 'e', 'nz': 'ne', 'c': 'b', 'nc': 'ae', 'nae': 'b', 'nb': 'ae', 'na': 'be', 'nbe': 'a',
                  'nge': 'l', 'nl': 'ge', 'ng': 'le', 'nle': 'g'}.get(cc, cc)
            return (ops[0].imm & MASK) if self.cond(cc) else nxt
        if m == 'call':
            tgt = ops[0].imm & MASK if ops[0].type == x86.X86_OP_IMM else self.get(ins, ops[0])
            self.push(nxt); return tgt
        if m == 'ret':
            ret = self.pop()
            if ops: self.r['esp'] = (self.r['esp'] + ops[0].imm) & MASK
            return ret
        if m == 'leave':
            self.r['esp'] = self.r['ebp']; self.r['ebp'] = self.pop(); return nxt
        if m == 'xchg':
            a, b = self.get(ins, ops[0]), self.get(ins, ops[1])
            self.put(ins, ops[0], b); self.put(ins, ops[1], a); return nxt
        if m == 'cmc':
            self.f['cf'] ^= 1; return nxt
        if m in ('stc', 'clc'):
            self.f['cf'] = int(m == 'stc'); return nxt
        raise Stop('unsupported %08x %s %s' % (eip, m, ins.op_str))
