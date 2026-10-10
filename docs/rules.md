# 新改曹操傳 6.6 — data tables (and, later, game rules)

All addresses are VAs in `orig/Ekd5.exe` (the 6.6 engine, image base 0x400000). Confidence tags: **[C]** confirmed
from code (function given), **[D]** confirmed from data / the mod's own notes only, **[G]** guess.
The memory map (person, unit, GS, save layout) is in [memory.md](memory.md). Converter: `tools/conv_data.py`
→ `game/assets/data/*.json`. The 6.6 engine rewrote and moved most of CCZ, so wg2025 (rea) addresses and layouts
do not carry over; everything below was re-checked in Ekd5.exe.

Mod notes used as hints (UTF-8 / GBK text in `orig/修改器與修改記錄/`): `變量計算+意義.txt` (EV 4016–4095),
`其他檔案/6.5数据转移.txt` (table positions), `6.5異常狀態計算.txt` (status / buff encoding), `orig/System.ini`
(strategy extension tables, item id ranges).

---------------------------------------------------------------------------------------------------
## 1. Data files

### 1.0 Overview

| File | Format | Records | Loaded to | Loader |
|---|---|---|---|---|
| Data.e5 e0 | Ls12 entry | 1024 × 32 persons | 1024 × 0x48 at `[0x4cea00]` | 0x41b666 → 0x408c0c |
| Data.e5 e1 | | 104 × 25 items 0..103 | 0x49f820 (raw) | 0x4010b0 |
| Data.e5 e2 | | 128 × 36 shops | 128 × 0x28 at `[0x4cea04]` | 0x41b7ee → 0x40d793 |
| Data.e5 e3 | | 80 × 35 classes | 0x4a2a27 (raw) | 0x41b73e → 0x436360 |
| Data.e5 e4 | | 40 × 60 class families | 0x4a3517 (raw) | 0x41b790 → 0x40956f |
| Data.e5 e5 | | 144 × 97 strategies + 97 × 16 skill names | 0x4a3e77 / 0x4a7510 | 0x41b830 → 0x40d737 |
| Data.e5 e6–e9 | | "闲置区段07..10" filler | not loaded | |
| Star.e5 | raw | 152 × 25 items 104..255 (then filler) | 0x4a0248 (reads ≤ 0x27d8 bytes) | 0x451313 |
| Imsg.e5 | raw | 2507 × 200 GBK texts | read on demand | 0x40bf56(buf, index) |

The archive reader is 0x41b533(name, entry, dest). Everything is loaded once at boot (0x404caf → 0x41b639).

### 1.1 Person record (Data.e5 e0, 32 bytes) [C: 0x408c0c]

| File off | Size | → memory | Meaning |
|---|---|---|---|
| 0x00 | 13 | +0x08 (12 bytes copied), tail → +0x3f | name (GBK). Display name 0x407775 stops at NUL or an ASCII digit |
| 0x0d | u16 | +0x04, face table 0x50f000[id] | face (portrait) |
| 0x0f | 1 | — | not read by the 6.6 parser (wg2025: map sprite). Sprites come from 0x501000 / 0x50f800 |
| 0x10 | 1 | +0x26 | voice type for generic critical lines (0x40c099) |
| 0x11 | 1 | +0x2a | army: 0 = player's army, 0xff = none (every person in Data.e5 has 0xff) |
| 0x12..0x16 | 5 × u8 | words +0x11.. and bytes +0x21.. | 武力 统率 智力 敏捷 运气 (battle stats 攻击 防御 精神 爆发 士气) |
| 0x17 | u16 | +0x1b (u32) | base max HP, clamped to 500 at load |
| 0x19 | u8 | +0x1f (u16) | base max MP, clamped to 250 at load |
| 0x1a | 1 | +0x2b | class 0..79 |
| 0x1b | 1 | +0x2c | level (0 → 1) |
| 0x1c | 1 | +0x2d | exp |
| 0x1d / 0x1e / 0x1f | 1 each | +0x2e / +0x31 / +0x34 | weapon, armour, accessory (0xff none); equipment level and exp stay 0 |

JSON `persons.json` adds `s_sprite` (0x501000[id]), `r_sprite` (0x50f800[id]), `sp` (0x501c00[id]) and `bio`
(Imsg 922 + id). `hp`/`mp` are the clamped values (`hp_raw` keeps the file value). `army` is the byte at 0x11
(`fixed_growth_flag` is the same value under the wg2025 key).

### 1.2 Item record (Data.e5 e1 / Star.e5, 25 bytes) [C]

The two files share the layout. After loading, 0x4010b0 fixes up 0x200 records: +0x0e = 0 (names keep 14 bytes),
then moves file bytes 0x12/0x13/0x14 to +0x14/+0x12/+0x13.

| File | Memory | Meaning | Evidence |
|---|---|---|---|
| 0x00..0x0e | +0x00 | name, 15-byte field (14 kept) | 0x4010e7 |
| 0x0f | +0x0f u16 | icon picture index (Star.e5: equal to the item id; Data.e5: id, item 0 = 209) | 0x4063bf → 0x4089b9 |
| 0x11 | +0x11 | type: 0x00..0x13 weapons, 0x14..0x19 armour (even = normal, odd = treasure), ≥ 0x1a = effect id of an accessory / consumable | 0x43ad20, 0x40b444 |
| 0x12 | +0x14 | weapons/armour: treasure effect id (0xff none); others: kind 2 = accessory, 3 = consumable | 0x43ad29, 0x40b444 |
| 0x13 | +0x12 | price: buy = price·100 (0x40e070); sell = price·100·3/4, 0xff = cannot be sold (0x40b477) | |
| 0x14 | +0x13 | equals the item id for most items (wg2025 called it the icon); no 6.6 reader identified | [G] |
| 0x15 | +0x15 | base value (level 1) | 0x41dd72 |
| 0x16 | +0x16 | effect value | |
| 0x17 | +0x17 | equipment: value gained per level; accessory: family that may wear it (0xff = all; 0x420e83) | 0x4202bb |
| 0x18 | +0x18 | 1 for unique items / 3 for some consumables (bit 0 counted by 0x427a98 → [0x500ada]) | 0x4083f0 |

* **Category** (0x40b444): type < 0x14 weapon (0), < 0x1a armour (1), else the byte at +0x14 (2 accessory,
  3 consumable). Equipment = category ≤ 1 (0x40c45a). Treasure = equipment with odd type (0x40b4e1).
* **Effect id** (0x40b4bd): equipment → +0x14, else +0x11; effect index = id − 0x1a. Names: consumables
  (category 3) 0x4ce000 + index·9 (58 names: 恢复HP …), others 0x4cb7a0 + index·16 (230 names) (0x4230fa).
* **Equipment kind** = type >> 1 (0..12), names 0x48bc04: 剑 枪 弓 棍 炮车 锤 斧 扇 宝剑 神器 铠甲 劲装 袍服
  (13 辅助, 14 道具). Class may equip type t iff class byte 9 + t ≠ 0 (0x41c60f).
* **Ids by range** (script equip codes, 0x407df1): weapons from 0, armour from 70 (0x46), accessories from 109
  (0x6d) (`System.ini` DefID / AssID). The default-equipment table 0x482427 (13 bytes) lists the first id of each
  weapon/armour kind for the automatic shop (0xff = not sold).
* **Value at level** (0x40b3d7): equipment = value + growth·(level − 1), level is 1-based (level 0 would loop 255
  times); accessories = value. Max level (0x4201c1): treasure 10, else 5.
* **Which stat an item raises**: equipment by kind (table 0x40684f: kinds 0–6 → 攻击, 7–8 → 精神, 9 → code 10
  (攻击 and 精神, 0x405670), 10–12 → 防御); accessories by type (0x4067ce: 0x20..0x26 → stats 0..6, 0x27 → 8 exp,
  0x28 → 7 move, 0x5c → 9, 0xfe → 10); treasure specials by 0x40678e (0x20..0x28 via table 0x4067c5).
* **Accessory family groups** (0x420e83): allowed if +0x17 == 0xff or == the wearer's family, or if the wearer's
  family is listed under +0x17 in the group table 0x44c341: `ff 0c 12 13 1a ff 02 04 13 ff 03 0c ff ff` = family 12
  (女兵) also 18, 19, 26; family 2 (弓兵) also 4, 19; family 3 (骑兵) also 12.

### 1.3 Class record (Data.e5 e3, 35 bytes; memory identical) [C]

| Off | Meaning | Evidence |
|---|---|---|
| 0 | move points | 0x41edef via 0x4072d3 |
| 1 | attack hit-area code (0..32, see the Hitarea list in `CczEditor-*.config`) | 0x44f9a0 via 0x417a51 |
| 2..6 | growth of 攻击 防御 精神 爆发 士气 (stat 0..4) | 0x40dbae(stat): class[2 + stat] |
| 7 | HP growth (stat 5) | 0x40dbae |
| 8 | MP growth (stat 6) | 0x40dbae |
| 9..34 | may-equip flag per item type 0..25 | 0x41c60f(type): class[9 + type] |

Growth is adjusted by the raw-ability grade 0x4072f2 and the per-person modifier table 0x507ec0 (0x436e3d).
**Family** (0x40bf0c): class ≤ 59 → class/3 (20 three-tier families), 60..79 → class − 40, else 40 (none).
Class names: pointers 0x48bea8[80] → 9-byte strings at 0x5000d0. Descriptions: Imsg 350 + class.

### 1.4 Class family record (Data.e5 e4, 60 bytes; memory identical) [C]

| Off | Meaning | Evidence |
|---|---|---|
| 0..29 | terrain effect per terrain type, **percent** (100 = normal; wg2025 used tenths) | 0x41f62a(t): fam[t] |
| 30..59 | move cost per terrain type, 0xff = impassable | 0x4060c4(t): fam[0x1e + t] |

Family names: pointers 0x48c570[40] → 0x48c610 (君主 步兵 … 百姓). Terrain names: pointers 0x48bdb0[34]
(平原 … 地下, then 30 地雷 31 战壕 32 掩体 33 工事 which have no column in e4).

Tables in the exe after the 6.6 class data (`System.ini` UserXK = file 0xA3280):
* **Matchup** 0x4d1a80, u8[40][40] percent: 0x426737(a, b) = table[family(b)·40 + family(a)] (then ± 0x413272);
  the physical damage 0x43bc5a calls it with (attacker, defender), so row = defender family, column = attacker
  family (e.g. row 弓兵, column 骑兵 = 130). Exported as `damage_taken_from[attacker_family]`.
* **Family attribute rows** 0x4d20c0 + 40·k, k = 0..8 (u8[40] each), exported as `attr0_move_kind` … `attr8`.
  Readers: k0 0x43f371 (3 = special move kind, else jump table 0x43f43e), k1 0x4011e8, k2 0x403d34 → [0x500e7c],
  k3 0x4281af, k4 0x43fff4, k5 0x4190e8 / AI 0x439a78, k6 0x43c16d (percent in strategy damage), k7 0x416e9c
  (0 → SP table used), k8 0x40114b / 0x411278 / 0x44db2d. Meanings beyond the reader are not verified.

### 1.5 Strategy record (Data.e5 e5, 97 bytes → 0x61 in memory) [C: 0x40d737]

| File | Memory | Meaning |
|---|---|---|
| 0x00..0x09 | +0x00 (+0x0a = 0) | name |
| 0x0b | +0x0f | effect id → names 0x48bfe8 + id·9 (72: 攻击(火) … 附加技能 …) (getter 0x4212e3) |
| 0x0c | +0x0b | target: 0 enemy, 1 ally, 2 none (weather) [D] |
| 0x0d | +0x0c | cast range code |
| 0x0e | +0x0d | effect area code (read at 0x4245c5) |
| 0x0f | +0x0e | MP cost |
| 0x10 | +0x10 | animation group |
| 0x11..0x60 | +0x11.. | learn level per class 0..79 (0 = never) |

144 strategies (0..143; the 空白 ones are placeholders); descriptions Imsg 0..143. The 1552 bytes after strategy
143 are the 97 skill names (16 bytes each: 武将技 0..79, 军师技 80..96), copied to 0x4a7510; descriptions Imsg 144+i.

Per-strategy extension tables, u8[144] each at 0x4d14e0 + 0x90·k (names from `System.ini`):

| k | Address | JSON key | Meaning |
|---|---|---|---|
| 0 | 0x4d14e0 | mimic_pierce | MgMF 能否被模仿、辅助穿透对策略是否有效 |
| 1 | 0x4d1570 | effect_index | MgID 策略效果索引 |
| 2 | 0x4d1600 | ai_use_battle | MgAIYN1 AI 是否使用 (战场); 13 = not used |
| 3 | 0x4d1690 | ai_use_training | MgAIYN2 AI 和我军是否使用 (练武场); 13 = not used |
| 4 | 0x4d1720 | hit_cap | MgHit 命中上限; 0 → 90, 1 → 100, 2 → 100, 3 → 34, 4 → 50, else the value |
| 5 | 0x4d17b0 | learn_group | Mg8 学会策略 (8 类) |
| 6 | 0x4d1840 | damage_coef | MgHurt 伤害系数; 28 = no damage |
| 7 | 0x4d18d0 | damage_kind | MgHurtYN 是否伤血: 0 四系, 1 毒麻, 2 八图/撞心, 3 青龙/朱雀, 4 不伤血 |
| 8 | 0x4d1960 | meff | MgMeff small animation number |
| 9 | 0x4d19f0 | mcall | MgMcall big animation; < 100 = none |

### 1.6 Shop record (Data.e5 e2, 36 bytes → 0x28) [C: 0x40d793]

u16 a → u32 +0, u16 b → u32 +4 (meaning not identified), 16 equipment ids → +8, 16 item ids → +0x18
(0xff = end). EV 4088 = 0 turns the automatic shop on (equipment by party level, 0x482427).

### 1.7 Imsg.e5 (2507 × 200 bytes) [C: wrappers of 0x40bf56]

| Range | Contents | Reader |
|---|---|---|
| 0..143 | strategy descriptions | 0x425aa2 (index < 241 direct) |
| 144..240 | skill (武将技 / 军师技) descriptions | 0x425aa2 |
| 250..348 | battle names (99) | 0x4190aa: 0xfa + i |
| 350..429 | class descriptions | 0x40bfbd: 0x15e + class |
| 430..609 | 特效 descriptions (names 0x4cc600 + i·16, 255 slots) | 0x419230: 0x1ae + i |
| 650..698 | retreat lines (header 649) | [D] |
| 700..798 | critical lines (header 699) | 0x40c0e7: 0x2bc + i |
| 800..918 | credits | 0x431564: 0x320 + i |
| 922..1945 | person biographies | 0x40bfdb: 0x39a + id |
| 1946..2201 | item descriptions | 0x4143ae: 0x79a + id |
| 2458..2506 | 49 extra lines (6.5 addition) | 0x40c00f: 0x99a + i |

Records 249, 349, 649, 699, 799, 921 are section headers; 2202..2457 are blank.

### 1.8 Name tables in the exe (exported in names.json)

| Table | Address | Shape |
|---|---|---|
| classes | 0x48bea8 → 0x5000d0 | 80 pointers |
| class families | 0x48c570 → 0x48c610 | 40 pointers |
| terrain | 0x48bdb0 | 34 pointers (scripts may repoint entries) |
| equipment kinds | 0x48bc04 | 15 pointers |
| strategy effects | 0x48bfe8 | 72 × 9 bytes |
| item effects (accessories / treasures) | 0x4cb7a0 | 230 × 16, index = effect id − 0x1a |
| consumable effects | 0x4ce000 | 58 × 9, index = effect id − 0x1a |
| 特效 (person / class special effects) | 0x4cc600 | 255 × 16 |
| skills | 0x4a7510 (from Data.e5 e5) | 97 × 16 |

### 1.9 Per-person tables in the exe image

`sprite_tables.json`: S (battle) sprite u16[1024] at 0x501000 (file 0xD2800; 0 = by class, reader 0x4068de) and
R (story) sprite u16[1024] at 0x50f800 (file 0xE1000; reader 0x409038, written by op 0x411f49). Both are inside
the 0x501000 block that saves store raw, so scripts can change them per playthrough. SP u8[1024] at 0x501c00.
