"""Convert the 新改曹操傳 6.6 game data tables (Data.e5, Star.e5, Imsg.e5, tables in Ekd5.exe) to JSON for the Godot port.

usage: tools/venv/bin/python -I tools/conv_data.py [GAME_DIR] [OUT_DIR]
  GAME_DIR defaults to <repo>/orig     (read-only input; files are only parsed, nothing is executed)
  OUT_DIR  defaults to <repo>/game/assets/data

Sources (record layouts, field evidence and exe addresses: docs/rules.md section 1, memory map: docs/memory.md):
  Data.e5 (Ls12, 10 entries; loaded once at boot by 0x41b639)
    e0 persons     1024 x 32  -> 1024 x 0x48 at [0x4cea00]   parser 0x408c0c (loop 0x41b666)
    e1 items        104 x 25  -> 0x49f820 (items 0..103)      raw copy, fixed up by 0x4010b0
    e2 shops        128 x 36  -> 128 x 0x28 at [0x4cea04]     parser 0x40d793 (loop 0x41b7ee)
    e3 classes       80 x 35  -> 80 x 0x23 at 0x4a2a27        raw copy 0x436360 (loop 0x41b73e)
    e4 families      40 x 60  -> 40 x 0x3c at 0x4a3517        raw copy 0x40956f (loop 0x41b790)
    e5 strategies   144 x 97  -> 144 x 0x61 at 0x4a3e77       parser 0x40d737 (loop 0x41b830)
       + 0x610 bytes after them = 97 skill names x 16 (武将技/军师技) copied to 0x4a7510
    e6..e9 "闲置区段" filler (not loaded)
  Star.e5 (raw, 152 x 25)  -> items 104..255 at 0x4a0248 (0x451313 reads up to 0x27d8 bytes)
  Imsg.e5 (raw, 2507 x 200 GBK)  reader 0x40bf56(buf, index); index bases see TEXT_RANGES
  Ekd5.exe name / extension tables (see names.json and docs/rules.md)
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from e5 import Archive  # noqa: E402

GAME = sys.argv[1] if len(sys.argv) > 1 else _REPO + '/orig'
OUT = sys.argv[2] if len(sys.argv) > 2 else _REPO + '/game/assets/data'

NONE = 0xff


def gbk(b):
    b = b.split(b'\0')[0]
    return b.decode('gbk', errors='replace')


def ff(v):
    """0xff -> None (empty slot)"""
    return None if v == NONE else v


# ---------------------------------------------------------------- the executable
class Exe:
    """Ekd5.exe read as the loader maps it (sections at their VAs). Parsed with struct only."""

    def __init__(self, path):
        self.data = open(path, 'rb').read()
        pe = struct.unpack_from('<I', self.data, 0x3c)[0]
        nsec = struct.unpack_from('<H', self.data, pe + 6)[0]
        optsz = struct.unpack_from('<H', self.data, pe + 20)[0]
        opt = pe + 24
        self.base = struct.unpack_from('<I', self.data, opt + 28)[0]
        self.secs = []
        for i in range(nsec):
            o = opt + optsz + 40 * i
            vsz, va, rsz, roff = struct.unpack_from('<IIII', self.data, o + 8)
            self.secs.append((self.base + va, max(vsz, rsz), roff, rsz))

    def read(self, va, n):
        for v, vs, ro, rs in self.secs:
            if v <= va < v + vs:
                o = va - v
                raw = self.data[ro + o:ro + min(o + n, rs)] if o < rs else b''
                return raw + bytes(n - len(raw))       # zero-filled virtual part
        raise ValueError(hex(va))

    def u8(self, va):
        return self.read(va, 1)[0]

    def u16(self, va):
        return struct.unpack('<H', self.read(va, 2))[0]

    def u32(self, va):
        return struct.unpack('<I', self.read(va, 4))[0]

    def cstr(self, va, maxlen=64):
        return gbk(self.read(va, maxlen))

    def ptr_table(self, va, n):
        return [self.cstr(self.u32(va + 4 * i)) for i in range(n)]

    def fixed_table(self, va, n, stride):
        d = self.read(va, n * stride)
        return [gbk(d[i * stride:(i + 1) * stride]) for i in range(n)]


# ---------------------------------------------------------------- exe addresses (verified, docs/rules.md)
CLASS_NAMES = 0x48bea8          # u32[80] -> 9-byte GBK names at 0x5000d0
FAMILY_NAMES = 0x48c570         # u32[40] -> 9-byte names at 0x48c610
TERRAIN_NAMES = 0x48bdb0        # u32[34] (平原..工事); scripts may rename entries by pointer
TERRAIN_COUNT = 34
EQUIP_TYPE_NAMES = 0x48bc04     # u32[15]: 剑 枪 弓 棍 炮车 锤 斧 扇 宝剑 神器 铠甲 劲装 袍服 辅助 道具 (index type>>1)
STRAT_EFFECT_NAMES = 0x48bfe8   # 72 x 9 bytes, strategy effect id (record +0x0b) (getter 0x4212e3)
ITEM_EFFECT_NAMES = 0x4cb7a0    # 230 x 16 bytes, accessory / treasure effect id - 0x1a (0x4230fa)
USE_EFFECT_NAMES = 0x4ce000     # 58 x 9 bytes, consumable effect id - 0x1a (0x4230fa, item+0x14 == 3)
SPECIAL_NAMES = 0x4cc600        # 255 x 16 bytes, 特效 (person / class special effects) (0x41b707); desc Imsg 430+i
STRAT_TABLES = 0x4d14e0         # 10 x u8[144] per-strategy extension tables (System.ini Mg* keys)
MATCHUP = 0x4d1a80              # u8[40][40] percent, [defender_family*40 + attacker_family] (0x426737)
FAMILY_ATTRS = 0x4d20c0         # 9 x u8[40] per-family attribute rows following the matchup table
S_SPRITE = 0x501000             # u16[1024] battle (S) sprite override per person (file 0xD2800, 0x4068de)
R_SPRITE = 0x50f800             # u16[1024] story (R) sprite per person (file 0xE1000, 0x409038)
SP_TABLE = 0x501c00             # u8[1024] SP per person (0x416eb3)

STRAT_TABLE_KEYS = [            # order of the ten tables at 0x4d14e0 + 0x90*k (orig/System.ini)
    ('mimic_pierce', 'MgMF 策略能否被模仿、辅助穿透对策略是否有效'),
    ('effect_index', 'MgID 策略效果索引'),
    ('ai_use_battle', 'MgAIYN1 AI是否使用策略(战场), 13 = not used'),
    ('ai_use_training', 'MgAIYN2 AI和我军是否使用策略(练武场), 13 = not used'),
    ('hit_cap', 'MgHit 策略命中上限; 0 -> 90 (大觉醒), 1 -> 100 (觉醒), 2 -> 100, 3 -> 34 (海啸), 4 -> 50 (暗杀)'),
    ('learn_group', 'Mg8 学会策略(8类设置)'),
    ('damage_coef', 'MgHurt 策略伤害系数; 28 = no damage'),
    ('damage_kind', 'MgHurtYN 是否伤血: 0 四系, 1 毒麻, 2 八图/撞心, 3 青龙/朱雀, 4 不伤血'),
    ('meff', 'MgMeff 小动画 meff number'),
    ('mcall', 'MgMcall 大动画 mcall number; < 100 = none (only the small animation)'),
]
FAMILY_ATTR_KEYS = [            # rows at 0x4d20c0 + 40*k; readers given, meaning partly unverified
    ('attr0_move_kind', '0x43f371: terrain/move kind (3 = special case, else jump table 0x43f43e)'),
    ('attr1', '0x4011e8: tested == 0'),
    ('attr2', '0x403d34: copied to [0x500e7c] (>= 2 sets [0x500c45])'),
    ('attr3', 'getter 0x4281af'),
    ('attr4', 'getter 0x43fff4'),
    ('attr5', '0x4190e8 / AI 0x439a78 (== 2 tested)'),
    ('attr6_percent', '0x43c16d: percent applied in strategy damage (0x425ad9)'),
    ('attr7', '0x416e9c: 0 -> the SP table 0x501c00 is used (SP / 必杀 allowed?)'),
    ('attr8', '0x40114b / 0x411278: non-zero -> +0x4f (index), 9 tested by AI 0x44db2d'),
]

# Imsg.e5 index map: reader 0x40bf56(buf, index); wrappers give the bases.
TEXT_RANGES = {
    'strategy_desc': [0, 144, '0x425aa2: index < 241 read directly'],
    'skill_desc': [144, 97, '武将技 0..79 / 军师技 80..96 (names: names.json skills)'],
    'battle_name': [250, 99, '0x4190aa: 0xfa + i, i <= 99'],
    'class_desc': [350, 80, '0x40bfbd: 0x15e + class, class < 80'],
    'special_desc': [430, 180, '0x419230: 0x1ae + i (特效 i, names 0x4cc600)'],
    'retreat_line': [650, 49, 'header record 649'],
    'critical_line': [700, 99, '0x40c0e7: 0x2bc + i'],
    'credits': [800, 119, '0x431564: 0x320 + i'],
    'person_bio': [922, 1024, '0x40bfdb: 0x39a + person, person < 1024'],
    'item_desc': [1946, 256, '0x4143ae: 0x79a + item'],
    'extra_line': [2458, 49, '0x40c00f: 0x99a + i, i < 49'],
}


def class_family(c):
    """0x40bf0c: class <= 59 -> class/3 (20 three-tier families), 60..79 -> class-40, else 40 (none)."""
    if c <= 0x3b:
        return c // 3
    if c < 0x50:
        return c - 40
    return 40


def item_category(t, b12):
    """0x40b444 on the in-memory record: type (+0x11) < 0x14 weapon, < 0x1a armour, else byte +0x14
    (file byte 0x12): 2 accessory, 3 consumable."""
    if t < 0x14:
        return 0
    if t < 0x1a:
        return 1
    return b12


CATEGORY_NAMES = {0: 'weapon', 1: 'armor', 2: 'accessory', 3: 'consumable'}


def main():
    os.makedirs(OUT, exist_ok=True)
    exe = Exe(os.path.join(GAME, 'Ekd5.exe'))
    data = Archive(os.path.join(GAME, 'Data.e5'))
    imsg = open(os.path.join(GAME, 'Imsg.e5'), 'rb').read()
    star = open(os.path.join(GAME, 'Star.e5'), 'rb').read()
    texts = [gbk(imsg[i * 200:(i + 1) * 200]) for i in range(len(imsg) // 200)]

    def text(i):
        return texts[i] if 0 <= i < len(texts) else ''

    # ------------------------------------------------------------ name tables
    class_names = exe.ptr_table(CLASS_NAMES, 80)
    family_names = exe.ptr_table(FAMILY_NAMES, 40)
    terrain_names = exe.ptr_table(TERRAIN_NAMES, TERRAIN_COUNT)
    equip_type_names = exe.ptr_table(EQUIP_TYPE_NAMES, 15)
    strat_effect_names = exe.fixed_table(STRAT_EFFECT_NAMES, 72, 9)
    item_effect_names = exe.fixed_table(ITEM_EFFECT_NAMES, 230, 16)
    use_effect_names = exe.fixed_table(USE_EFFECT_NAMES, 58, 9)
    special_names = exe.fixed_table(SPECIAL_NAMES, 255, 16)
    e5 = data[5]
    skill_tail = e5[144 * 97:]
    skill_names = [gbk(skill_tail[i * 16:(i + 1) * 16]) for i in range(len(skill_tail) // 16)]

    # ------------------------------------------------------------ classes (e3)
    e3 = data[3]
    classes = []
    for i in range(len(e3) // 35):
        r = e3[i * 35:(i + 1) * 35]
        fam = class_family(i)
        eq = list(r[9:35])
        classes.append({
            'id': i,
            'name': class_names[i],
            'family': fam,
            'family_name': family_names[fam] if fam < 40 else '',
            'move': r[0],                       # move points
            'attack_range': r[1],               # hit-area code (Hitarea), 0..32
            'growth': {                         # 0x40dbae: class[2 + stat] (stat 0..4, 5 HP, 6 MP)
                'attack': r[2], 'defense': r[3], 'spirit': r[4], 'agility': r[5], 'morale': r[6],
                'hp': r[7], 'mp': r[8]},
            'equip_types': [t for t in range(26) if eq[t]],   # may equip item type t (0..25)
            'equip_raw': eq,
            'description': text(350 + i),
        })

    # ------------------------------------------------- class families / terrain (e4) + exe tables
    e4 = data[4]
    matchup = exe.read(MATCHUP, 1600)
    attrs = exe.read(FAMILY_ATTRS, 40 * len(FAMILY_ATTR_KEYS))
    families = []
    for i in range(len(e4) // 60):
        r = e4[i * 60:(i + 1) * 60]
        fam = {
            'id': i,
            'name': family_names[i],
            'terrain_effect': list(r[:30]),     # PERCENT (100 = normal) per terrain 0..29 (wg2025: units of 10%)
            'move_cost': [None if b == NONE else b for b in r[30:60]],   # None = impassable
            'damage_taken_from': list(matchup[i * 40:(i + 1) * 40]),   # % when attacked by family j (0x426737)
        }
        for k, (key, _) in enumerate(FAMILY_ATTR_KEYS):
            fam[key] = attrs[k * 40 + i]
        families.append(fam)
    terrain = {
        'names': terrain_names, 'count': TERRAIN_COUNT,
        'note': 'class_families.terrain_effect[t] is a PERCENT (100 = 100%, Data.e5 e4 bytes 0..29); '
                'move_cost None = impassable. Data.e5 holds 30 terrain columns; the exe names 34 terrain '
                'types (30 地雷, 31 战壕, 32 掩体, 33 工事 have no column). Map terrain byte = '
                '[mapbuf + 0x640 + x + y*W] (0x412557).',
    }

    # ------------------------------------------------------------- persons (e0)
    e0 = data[0]
    s_spr = struct.unpack('<1024H', exe.read(S_SPRITE, 2048))
    r_spr = struct.unpack('<1024H', exe.read(R_SPRITE, 2048))
    sp = exe.read(SP_TABLE, 1024)
    persons = []
    for i in range(len(e0) // 32):
        r = e0[i * 32:(i + 1) * 32]
        hp = struct.unpack_from('<H', r, 0x17)[0]
        persons.append({
            'id': i,
            'name': gbk(r[0:12]),               # 0x408c0c copies 12 bytes to +0x08 (tail -> +0x3f, 0x40a72c)
            'face': struct.unpack_from('<H', r, 0x0d)[0],   # +0x04, and the face table 0x50f000[id] (0x423e30)
            'sprite': r[0x0f],                  # file byte 0x0f: NOT loaded by the 6.6 engine (0x408c0c skips it)
            'unk_10': r[0x10],                  # +0x26
            'army': r[0x11],                    # +0x2a: 0 = in the player's army, 0xff = not (0x40c603, 0x4095b9)
            'fixed_growth_flag': r[0x11],       # (wg2025 name of the same byte, kept for compatibility)
            'attack': r[0x12],                  # 武力 word +0x11 and raw byte +0x21
            'defense': r[0x13],                 # 统率 +0x13 / +0x22
            'spirit': r[0x14],                  # 智力 +0x15 / +0x23
            'agility': r[0x15],                 # 敏捷 +0x17 / +0x24
            'morale': r[0x16],                  # 运气 +0x19 / +0x25
            'hp': min(hp, 500),                 # +0x1b (u32), clamped to 500 at load
            'hp_raw': hp,
            'mp': min(r[0x19], 250),            # +0x1f (u16), clamped to 250 at load
            'class': r[0x1a],                   # +0x2b
            'level': r[0x1b] or 1,              # +0x2c (0 -> 1)
            'exp': r[0x1c],                     # +0x2d
            'weapon': ff(r[0x1d]),              # +0x2e (level +0x2f and exp +0x30 left 0)
            'armor': ff(r[0x1e]),               # +0x31 (+0x32 / +0x33 left 0)
            'accessory': ff(r[0x1f]),           # +0x34
            's_sprite': s_spr[i],               # 0x501000[id]
            'r_sprite': r_spr[i],               # 0x50f800[id]
            'sp': sp[i],                        # 0x501c00[id] (initial value in the exe)
            'bio': text(922 + i),
        })

    # --------------------------------------------------------------- items (e1 + Star.e5)
    e1 = data[1]
    raw_items = [(e1[i * 25:(i + 1) * 25], 'Data.e5') for i in range(len(e1) // 25)]
    for i in range(256 - len(raw_items)):
        raw_items.append((star[i * 25:(i + 1) * 25], 'Star.e5'))
    items = []
    for i, (r, src) in enumerate(raw_items):
        t = r[0x11]
        b12 = r[0x12]
        cat = item_category(t, b12)
        equip = cat in (0, 1)
        treasure = equip and (t & 1) == 1                  # 0x40b4e1
        effect = (b12 if b12 != NONE else None) if equip else t     # 0x40b4bd: id; index = id - 0x1a
        if effect is not None and cat == 3:
            eff_name = use_effect_names[effect - 0x1a] if 0x1a <= effect < 0x1a + len(use_effect_names) else None
        elif effect is not None:
            eff_name = item_effect_names[effect - 0x1a] if 0x1a <= effect < 0x1a + len(item_effect_names) else None
        else:
            eff_name = None
        items.append({
            'id': i,
            'name': gbk(r[0:14]),               # 15-byte field; memory keeps 14 bytes (0x4010b0 writes 0 at +0x0e)
            'source': src,
            'type': t,                          # +0x11: 0..0x13 weapon kinds, 0x14..0x19 armour kinds, else effect id
            'category': CATEGORY_NAMES.get(cat, 'unknown'),
            'category_code': cat,
            'equip_type_name': equip_type_names[t >> 1] if equip else equip_type_names[13 if cat == 2 else 14],
            'treasure': treasure,
            'special': (b12 if b12 != NONE else None) if equip else None,   # +0x14 for weapons/armour
            'effect': effect,                   # effect id (treasure special or accessory/consumable type)
            'effect_name': eff_name,
            'price': r[0x13],                   # +0x12; buy = price*100 (0x40e070), sell = 3/4 of it (0x40b477)
            'icon': struct.unpack_from('<H', r, 0x0f)[0],   # +0x0f u16 icon picture (0x4063bf -> 0x4089b9)
            'unk_13': r[0x14],                  # +0x13 (wg2025 called this byte the icon; = item id for most items)
            'value': r[0x15],                   # +0x15 base value (level 1)
            'special_value': r[0x16],           # +0x16
            'growth': r[0x17],                  # +0x17 per-level increase (equipment) / family restriction
            'unk_18': r[0x18],                  # +0x18
            'description': text(1946 + i),
        })

    # ---------------------------------------------------------- strategies (e5) + exe tables
    tabs = [exe.read(STRAT_TABLES + 0x90 * k, 0x90) for k in range(len(STRAT_TABLE_KEYS))]
    strategies = []
    for i in range(144):
        r = e5[i * 97:(i + 1) * 97]
        learn = {str(c): r[0x11 + c] for c in range(80) if r[0x11 + c]}
        s = {
            'id': i,
            'name': gbk(r[0:10]),               # +0x00 (10 bytes, +0x0a = 0)
            'effect': r[0x0b],                  # +0x0f strategy effect (names 0x48bfe8)
            'effect_name': strat_effect_names[r[0x0b]] if r[0x0b] < len(strat_effect_names) else None,
            'target': r[0x0c],                  # +0x0b 0 enemy, 1 ally, 2 none (weather)
            'range': r[0x0d],                   # +0x0c cast range (hit-area code)
            'area': r[0x0e],                    # +0x0d effect area code
            'mp': r[0x0f],                      # +0x0e MP cost
            'anim': r[0x10],                    # +0x10 animation group
            'learn_level_by_class': learn,      # +0x11 + class (80 classes), 0 = never
            'description': text(i),
        }
        for k, (key, _) in enumerate(STRAT_TABLE_KEYS):
            s[key] = tabs[k][i]
        strategies.append(s)

    # --------------------------------------------------------------- shops (e2)
    e2 = data[2]
    shops = []
    for i in range(len(e2) // 36):
        r = e2[i * 36:(i + 1) * 36]
        shops.append({
            'id': i,
            'unk_a': struct.unpack_from('<H', r, 0)[0],   # -> u32 +0
            'unk_b': struct.unpack_from('<H', r, 2)[0],   # -> u32 +4
            'equipment': [b for b in r[4:20] if b != NONE],
            'items': [b for b in r[20:36] if b != NONE],
            'raw': r.hex(),
        })

    # ---------------------------------------------------------- misc / names
    names = {
        'classes': class_names,
        'class_families': family_names,
        'terrain': terrain_names,
        'equip_types': equip_type_names,
        'strategy_effects': strat_effect_names,
        'item_effects_by_id': {str(k + 0x1a): n for k, n in enumerate(item_effect_names)},
        'use_effects_by_id': {str(k + 0x1a): n for k, n in enumerate(use_effect_names) if n},
        'specials': special_names,
        'skills': skill_names,
        'battle_names': [text(250 + i) for i in range(99)],
        'strategy_tables': {k: v for k, v in STRAT_TABLE_KEYS},
        'family_attrs': {k: v for k, v in FAMILY_ATTR_KEYS},
    }
    text_ranges = {k: v[:2] for k, v in TEXT_RANGES.items()}
    text_ranges['note'] = ('[first index, count]; Imsg.e5 record = 200 GBK bytes, reader 0x40bf56. '
                           + '; '.join('%s: %s' % (k, v[2]) for k, v in TEXT_RANGES.items()))
    sprite_tables = {
        's_sprite': list(s_spr), 'r_sprite': list(r_spr),
        'note': 's_sprite = u16[1024] at 0x501000 (exe file offset 0xD2800, System.ini FileHead): battle (S) '
                'sprite per person, 0 = by class (reader 0x4068de); r_sprite = u16[1024] at 0x50f800 '
                '(file 0xE1000, RFileHead): story (R) sprite per person (0x409038; op 0x411f49 writes it). '
                'Both lie in the 0x501000..0x531000 block that saves store raw.',
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
    dump('texts.json', {'ranges': text_ranges, 'texts': texts})
    dump('sprite_tables.json', sprite_tables)
    print('wrote', OUT, 'persons', len(persons), 'items', len(items), 'classes', len(classes),
          'families', len(families), 'strategies', len(strategies), 'shops', len(shops), 'texts', len(texts))


if __name__ == '__main__':
    main()
