"""Convert wg2025 game data tables to JSON for the Godot port.

usage: tools/venv/bin/python -I tools/conv_data.py [GAME_DIR] [OUT_DIR]
  GAME_DIR defaults to <repo>/wg2025 (read-only input)
  OUT_DIR  defaults to <repo>/game/assets/data

Sources (see docs/rules.md for field evidence / exe addresses):
  data.wa  (Ls12 archive, 10 entries)
    e0 persons     1024 x 32  (parser 0x408be3)
    e1 items        104 x 25  (parser 0x40c537)
    e2 shops        128 x 36  (parser 0x40dcce, exe loads first 58)
    e3 classes       53 x 27  (parser 0x4093ef)
    e4 class families (terrain tables) 27 x 60 (parser 0x40948a)
    e5 strategies    73 x 70  (parser 0x40ddaf, exe loads first 68)
    e6..e9 name tables filled with the placeholder "终端" (not loaded by the exe)
  Fhua.wa  1946 x 200-byte GBK text records (reader 0x40bf56)
  person.wa 1024 bytes: per-person custom battle-sprite selector (0x406a75)
  wagan.wa  name tables in .data (class / family / terrain / effect names)
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(HERE)
from ls12 import read_archive  # noqa: E402

GAME = sys.argv[1] if len(sys.argv) > 1 else _REPO + '/wg2025'
OUT = sys.argv[2] if len(sys.argv) > 2 else _REPO + '/game/assets/data'


def gbk(b):
    b = b.split(b'\0')[0]
    return b.decode('gbk', errors='replace')


def ff(v):
    """0xff -> None (empty slot)"""
    return None if v == 0xff else v


# ---------------------------------------------------------------- exe tables
class Exe:
    def __init__(self, path):
        import pefile
        pe = pefile.PE(path, fast_load=True)
        self.base = pe.OPTIONAL_HEADER.ImageBase
        self.secs = [(self.base + s.VirtualAddress, s.PointerToRawData, s.SizeOfRawData) for s in pe.sections]
        self.data = open(path, 'rb').read()

    def off(self, va):
        for v, ro, rs in self.secs:
            if v <= va < v + rs:
                return ro + va - v
        raise ValueError(hex(va))

    def u32(self, va):
        return struct.unpack_from('<I', self.data, self.off(va))[0]

    def u8(self, va):
        return self.data[self.off(va)]

    def cstr(self, va):
        o = self.off(va)
        return gbk(self.data[o:self.data.index(b'\0', o)])

    def ptr_table(self, va, n):
        return [self.cstr(self.u32(va + 4 * i)) for i in range(n)]


TERRAIN_COUNT = 30


# ---------------------------------------------------------------- shapes
# Range / area shapes recovered by emulating 0x436586 (range codes) and 0x435d6c (area codes) with
# tools/rd_emu.py (see docs/rules.md §6). Offsets are (dx, dy) relative to the origin.
def _man(lo, hi, r=6):
    return [[x, y] for y in range(-r, r + 1) for x in range(-r, r + 1) if lo <= abs(x) + abs(y) <= hi]


def _cheb(n, r=6):
    return [[x, y] for y in range(-r, r + 1) for x in range(-r, r + 1) if max(abs(x), abs(y)) == n]


RANGE_SHAPES = {   # attack range (class byte 1) and strategy cast range (strategy byte 0x0d) share these codes
    0: {'desc': 'adjacent 4 (manhattan 1)', 'cells': _man(1, 1)},
    1: {'desc': '8 surrounding (chebyshev 1)', 'cells': _cheb(1)},
    2: {'desc': 'manhattan 2 ring', 'cells': _man(2, 2)},
    3: {'desc': 'manhattan 2..3', 'cells': _man(2, 3)},
    4: {'desc': 'manhattan 2..4', 'cells': _man(2, 4)},
    5: {'desc': 'straight lines length 1..2 (8 cells)', 'cells': [[x, y] for y in range(-2, 3) for x in range(-2, 3) if (x == 0) != (y == 0)]},
    6: {'desc': 'manhattan 1..2', 'cells': _man(1, 2)},
    7: {'desc': 'manhattan 3..4', 'cells': _man(3, 4)},
    8: {'desc': 'manhattan 3..5', 'cells': _man(3, 5)},
    9: {'desc': 'manhattan 3 ring', 'cells': _man(3, 3)},
    10: {'desc': 'whole map', 'cells': 'all'},
    11: {'desc': 'none (cannot attack) / self only for strategies', 'cells': []},
    12: {'desc': 'manhattan 1..3', 'cells': _man(1, 3)},
    13: {'desc': 'manhattan 1..4', 'cells': _man(1, 4)},
    14: {'desc': '3 cells wide bars at distance 3 (12 cells)', 'cells': [[s * 3, t] for s in (-1, 1) for t in (-1, 0, 1)] + [[t, s * 3] for s in (-1, 1) for t in (-1, 0, 1)]},
    15: {'desc': 'chebyshev-3 ring without corners (20 cells)', 'cells': [c for c in _cheb(3) if abs(c[0]) != abs(c[1])]},
}
AREA_SHAPES = {    # strategy effect area (strategy byte 0x0e); origin = target cell (always included)
    0: {'desc': 'target only', 'cells': []},
    1: {'desc': 'target + adjacent 4', 'cells': _man(1, 1)},
    2: {'desc': 'target + 8 surrounding (3x3)', 'cells': _cheb(1)},
    3: {'desc': 'target + 8 surrounding (3x3) (separate case 0x435f85)', 'cells': _cheb(1)},
    4: {'desc': 'line: 1 cell beyond the target, away from caster', 'cells': 'line', 'length': 1},
    5: {'desc': 'line: 5 cells beyond the target, away from caster', 'cells': 'line', 'length': 5},
    6: {'desc': 'line: 2 cells beyond the target, away from caster', 'cells': 'line', 'length': 2},
    7: {'desc': 'target + 8 surrounding (case 0x436012)', 'cells': _cheb(1)},
    8: {'desc': 'target + 9x9 square', 'cells': [c for c in [[x, y] for y in range(-4, 5) for x in range(-4, 5)] if c != [0, 0]]},
    9: {'desc': 'target + 5x5 square', 'cells': [c for c in [[x, y] for y in range(-2, 3) for x in range(-2, 3)] if c != [0, 0]]},
    10: {'desc': 'sweep: only when target adjacent (8-dir) to caster; adds the 2 cells adjacent to the target '
                 'perpendicular to the caster->target direction (diagonal: the 2 cells adjacent to both)', 'cells': 'sweep'},
    11: {'desc': '8 cells around the CASTER (target ignored)', 'cells': 'caster_ring'},
    12: {'desc': 'line from target away from caster to the map edge', 'cells': 'line', 'length': 255},
}


def main():
    os.makedirs(OUT, exist_ok=True)
    exe = Exe(os.path.join(GAME, 'wagan.wa'))
    # name tables (pointer tables in .data, see docs/rules.md)
    item_groups = exe.ptr_table(0x48bc20, 11)        # 近战系..道具 (xref 0x40c978)
    item_effects = exe.ptr_table(0x48bc50, 59)       # 每回合恢复HP..兵种上升, index = effect_id-18
    strat_effects = exe.ptr_table(0x48bd40, 28)      # 攻击(火)..机动上升
    terrain_names = exe.ptr_table(0x48bd40 + 28 * 4, TERRAIN_COUNT)  # 平原..地下
    family_names = exe.ptr_table(0x48be38, 27)       # 英雄..百姓
    class_names = exe.ptr_table(0x48bea8, 53)        # 游侠..百姓
    # extra effect names present in .data but not in the 59-entry pointer table (mod additions)
    extra_effect_names = [exe.cstr(a) for a in (0x48c1be, 0x48c1c7, 0x48c1ce, 0x48c1db, 0x48c1e4,
                                                0x48c1ed, 0x48c1fa, 0x48c203, 0x48c20c, 0x48c215)]

    # effect id space shared by aux-item `type` and treasure `special` (0x407a09 / 0x407af2):
    #   18..76 -> item_effects[id-18]; 81..90 -> extra mod effects (固定伤害 = 85 = 墨阳剑, 辅助地形移动 = 86 = 黄骠马 ...)
    effect_names = {i + 18: n for i, n in enumerate(item_effects)}
    effect_names.update({81 + i: n for i, n in enumerate(extra_effect_names)})

    ent = read_archive(os.path.join(GAME, 'data.wa'))
    fhua = open(os.path.join(GAME, 'Fhua.wa'), 'rb').read()

    def text(i):
        return gbk(fhua[i * 200:(i + 1) * 200])

    texts = [text(i) for i in range(len(fhua) // 200)]

    # ------------------------------------------------------------ classes (e3)
    e3 = ent[3]
    classes = []
    for i in range(len(e3) // 27):
        r = e3[i * 27:(i + 1) * 27]
        fam = i // 3 if i <= 38 else (i - 26 if i < 53 else 27)   # 0x4077d0
        classes.append({
            'id': i,
            'name': class_names[i] if i < len(class_names) else '',
            'family': fam,
            'family_name': family_names[fam] if fam < 27 else '',
            'move': r[0],                       # 0x40727b: move = class[0] + equip(7)
            'attack_range': r[1],               # 0x43f8f5 getter 0x44f9a0 (range shape code)
            'growth': {                         # 0x4073b9 level up, 0x4095a0(i)
                'attack': r[2], 'defense': r[3], 'spirit': r[4], 'agility': r[5], 'morale': r[6],
                'hp': r[7], 'mp': r[8]},
            'equip_types': [t for t in range(18) if r[9 + t]],   # 0x4095c0(type) != 0 -> may equip
            'equip_raw': list(r[9:27]),
            'description': texts[350 + i] if i < 53 else '',
        })

    # ------------------------------------------------- class families / terrain (e4)
    e4 = ent[4]
    families = []
    for i in range(len(e4) // 60):
        r = e4[i * 60:(i + 1) * 60]
        families.append({
            'id': i,
            'name': family_names[i],
            'terrain_effect': list(r[:30]),     # x10 % (10 = 100%), 0x43f84d
            'move_cost': [None if b == 0xff else b for b in r[30:60]],   # 0xff = impassable
        })
    terrain = {'names': terrain_names, 'count': TERRAIN_COUNT,
               'note': 'terrain_effect[t] is in units of 10% (attack & defense multiplier), move_cost None = impassable'}

    # ------------------------------------------------------------- persons (e0)
    e0 = ent[0]
    pw = open(os.path.join(GAME, 'person.wa'), 'rb').read()
    persons = []
    for i in range(len(e0) // 32):
        r = e0[i * 32:(i + 1) * 32]
        persons.append({
            'id': i,
            'name': gbk(r[0:13]),
            'face': struct.unpack_from('<H', r, 0x0d)[0],     # mem+0x04
            'sprite': r[0x0f],                                # mem+0x02 (R/S map sprite index)
            'unk_10': r[0x10],                                # mem+0x26 (unknown, raw)
            'fixed_growth_flag': r[0x11],                     # mem+0x2a; 0 -> randomised growth (0x448b09)
            'attack': r[0x12],     # 武艺  (mem word +0x11 & raw byte +0x21)
            'defense': r[0x13],    # 统制  (+0x13 / +0x22)
            'spirit': r[0x14],     # 智谋  (+0x15 / +0x23)
            'agility': r[0x15],    # 感知 / 反应 (+0x17 / +0x24)
            'morale': r[0x16],     # 胆魄  (+0x19 / +0x25)
            'hp': min(struct.unpack_from('<H', r, 0x17)[0], 500),   # mem+0x1c base max HP (clamped 500)
            'mp': min(r[0x19], 250),                                 # mem+0x20 base max MP (clamped 250)
            'class': r[0x1a],                                        # mem+0x2b
            'level': r[0x1b] or 1,                                   # mem+0x2c
            'exp': r[0x1c],                                          # mem+0x2d
            'weapon': ff(r[0x1d]), 'armor': ff(r[0x1e]), 'accessory': ff(r[0x1f]),
            'custom_sprite_sel': pw[i] if i < len(pw) else 0,        # person.wa, 0x406a75
            'bio': texts[922 + i] if 922 + i < len(texts) else '',
        })

    # --------------------------------------------------------------- items (e1)
    e1 = ent[1]
    items = []

    def item_category(t):   # 0x40c6ea
        if t < 14: return 'weapon'
        if t < 18: return 'armor'
        if t < 63: return 'accessory'
        if t < 81: return 'consumable'
        return 'accessory'

    for i in range(len(e1) // 25):
        r = e1[i * 25:(i + 1) * 25]
        t = r[0x11]
        cat = item_category(t)
        eff = effect_names.get(t) if t >= 18 else None
        spec = r[0x12]
        spec_name = effect_names.get(spec) if spec != 0xff else None
        items.append({
            'id': i,
            'name': gbk(r[0:17]),
            'type': t,                          # mem+0x11; 0..17 weapon/armor kinds, >=18 effect id
            'category': cat,
            'type_effect_name': eff,            # for t>=18: effect_names[t]
            'weapon_kind': (t // 2) if t < 18 else None,   # index into item_groups (近战系.. 衣服)
            'treasure': bool(t < 18 and t % 2 == 1),       # odd weapon/armor types carry a special effect
            'special': ff(spec),                # mem+0x14, effect id for treasures (same id space as type)
            'special_name': spec_name,
            'price': r[0x13],                   # mem+0x12 (x100 gold?; 255 = not sold)
            'icon': r[0x14],                    # mem+0x13
            'value': r[0x15],                   # mem+0x15 base value at level 1
            'special_value': r[0x16],           # mem+0x16
            'growth': r[0x17],                  # mem+0x17 per-level increase (weapons/armor)
            'unk_18': r[0x18],                  # mem+0x18 (1 for unique items)
            'description': texts[i] if i < 104 else '',
        })

    # ---------------------------------------------------------- strategies (e5)
    e5 = ent[5]
    strategies = []
    for i in range(len(e5) // 70):
        r = e5[i * 70:(i + 1) * 70]
        learn = {str(c): r[0x11 + c] for c in range(53) if r[0x11 + c]}
        strategies.append({
            'id': i,
            'name': gbk(r[0:10]),
            'effect': r[0x0b],                  # mem+0x0f, index into strategy effect names
            'effect_name': strat_effects[r[0x0b]] if r[0x0b] < len(strat_effects) else None,
            'target': r[0x0c],                  # mem+0x0b: 0 enemy, 1 ally, 2 none/weather
            'range': r[0x0d],                   # mem+0x0c: cast range shape code
            'area': r[0x0e],                    # mem+0x0d: effect area shape code
            'mp': r[0x0f],                      # mem+0x0e: MP cost
            'anim': r[0x10],                    # mem+0x10: animation / element group
            'learn_level_by_class': learn,      # mem+0x11+class, 0 = cannot learn (0x409580)
            'loaded_by_exe': i < 68,
            'description': texts[150 + i] if i < 68 else '',
        })

    # --------------------------------------------------------------- shops (e2)
    e2 = ent[2]
    shops = []
    for i in range(len(e2) // 36):
        r = e2[i * 36:(i + 1) * 36]
        shops.append({
            'id': i,
            'unk_a': struct.unpack_from('<H', r, 0)[0],
            'unk_b': struct.unpack_from('<H', r, 2)[0],
            'equipment': [b for b in r[4:20] if b != 0xff],
            'items': [b for b in r[20:36] if b != 0xff],
            'raw': r.hex(),
            'loaded_by_exe': i < 58,
        })

    # ---------------------------------------------------------- misc / names
    names = {
        'item_groups': item_groups,
        'item_effects': item_effects,
        'item_effects_extra_unreferenced': extra_effect_names,
        'effect_names_by_id': {str(k): v for k, v in sorted(effect_names.items())},
        'strategy_effects': strat_effects,
        'terrain': terrain_names,
        'class_families': family_names,
        'classes': class_names,
        'battle_names': [texts[250 + i] for i in range(58)],
    }
    text_ranges = {
        'item_desc': [0, 104], 'strategy_desc': [150, 68], 'battle_name': [250, 58],
        'class_desc': [350, 53], 'person_bio': [922, 1024],
        'note': 'other ranges (420-921) hold skill descriptions, quotes etc. Index = record number (200 bytes each).',
    }

    def dump(name, obj):
        with open(os.path.join(OUT, name), 'w', encoding='utf-8') as f:
            json.dump(obj, f, ensure_ascii=False, indent=1)

    dump('persons.json', persons)
    dump('items.json', items)
    dump('classes.json', classes)
    dump('class_families.json', families)
    dump('terrain.json', terrain)
    dump('strategies.json', strategies)
    dump('shops.json', shops)
    dump('names.json', names)
    dump('shapes.json', {'range': {str(k): v for k, v in RANGE_SHAPES.items()},
                         'area': {str(k): v for k, v in AREA_SHAPES.items()},
                         'note': 'range codes: class.attack_range, strategy.range; area codes: strategy.area. '
                                 'For ally-targeting strategies the caster cell is added to the range (flag bit 1).'})
    dump('texts.json', {'ranges': text_ranges, 'texts': texts})
    print('wrote', OUT, len(persons), len(items), len(classes), len(families), len(strategies), len(shops), len(texts))


if __name__ == '__main__':
    main()
