# 新改曹操傳 6.6 — skills, 特效 and item effects (the effect system)

All addresses are VAs in `orig/Ekd5.exe` (the 6.6 engine, image base 0x400000). Tags: **[C]** confirmed in the
disassembly (function given), **[D]** from data / the mod's own notes only, **[G]** guess. Memory layouts of
persons, units and the 0x501000 save block are in [memory.md](memory.md); item / class records in
[rules.md](rules.md) §1; script ops in [eex.md](eex.md). The 6.6 engine is hand-written asm with odd conventions
(object in `ecx` pushed to `[ebp-4]`, results in `edx`/`ecx`, callees reading the caller's pushes as their own
locals); everything below was read in the disassembly (`tools/disx.py`), Ghidra only as a cross-check.
Data file: `game/assets/data/skills.json` (names, descriptions, default values, initial class skills, every query
pair with its call sites, item-effect table, the 97 必杀 records) — reference data generated from the exe tables
(`game/assets/` is untracked; tools/conv_data.py does not produce this file yet).

Summary

| Source | Storage | Written by | Section |
|---|---|---|---|
| 个人天赋 (personal) | 0x511000: 255 rows × {4 × (u16 person, u8 value), 2 × (u8 class, u8 value)} | op 0x72 sub 5 | 2.1 |
| 兵种技能 (class) | same rows, class entries (inherited upward in the family unless EV 4058) | op 0x72 sub 5 (pos 4/5) | 2.1 |
| 附加技能 (added / temporary) | stream 0x512dc0 `FF sid {value, turns, u16 person}…` | op 0x72 sub 35, consumables type 0x34, strategy result 28 | 2.2 |
| equipment | item+0x14 (treasure) / item+0x11 (accessory) = item effect id, value by level | — | 2.3, 6 |
| 专属 / 套装 | 0x50e000: 256 rows × {2 × (u16 person, item, value), 2 × (weapon, armour, accessory, value)} | op 0x72 sub 10 | 2.4 |
| 必杀 | definitions 0x4a7510 (97 × 16), learners 0x512000 (80 × 16), SP 0x501c00 | op 0x72 sub 6 | 3 |

Query: `0x4101d9(unit, sid, eid, mode, a4)` combines all sources (mode 0 sum, 1 max, 2 first-non-zero with 7
dominant, 3 OR), blocked by an adjacent enemy's 特效屏蔽, extended by 特效模仿 (§4). Catalogue: §5.

## 1. Overview: two id spaces, one query

The 6.6 engine replaces CCZ's item-effect checks by one generic query that unifies every source of a "skill":

* **特效 id** (`sid`, 0..254) — the skill itself. Names: 0x4cc600 + sid·16 (255 × 16 bytes; the in-game skill
  list draws these, 0x44d8d1). Description: Imsg.e5 record 430 + sid (sid < 180; 0x419230). Personal talents,
  class skills, 附加技能 (added / temporary skills), 专属 (exclusive equipment) and 套装 (equipment sets) are all
  stored as 特效 ids.
* **Item effect id** (`eid`, 0x1a..0xff) — what an equipment item carries: a treasure weapon/armour's effect byte
  item+0x14 (only if the type is odd = treasure), an accessory's type byte item+0x11. Names: 0x4cb7a0 + (eid−0x1a)·16
  (230 × 16; the mod renamed many to list everything the item gives, e.g. 0x34 "无反破攻忽防爆"). The item's
  description (Imsg 1946 + item) is what the player reads.

A query names **both** ids — "does this unit have 特效 `sid` (from any source) or wear an item with effect `eid`" —
plus a combine mode. The pairs are fixed in the code (one tiny wrapper or inline call per feature). One item effect
can therefore stand for several 特效 (0x41 黄金铠 is queried as 集气加倍, 防御致命攻击 and 防御二次攻击), and some
特效 have no item effect at all (`eid` 0 never matches). §5 lists every pair.

```
value = Query(unit_or_person, sid, eid, mode, a4)          ; 0x4101d9, battle only
value = QueryAny(person, sid, eid, mode, a4)               ; 0x42518f: 0x4101d9 in battle, else 0x41301e
value = QuerySources(person, sid, eid, mode, a4)           ; 0x41301e: no 特效屏蔽 / 特效模仿 handling
```

## 2. Where a unit's skills come from (storage)

All tables below live in the 0x501000..0x531000 block that saves store raw (memory.md §8–9). Their initial
contents are part of Ekd5.exe's image (.text3, loaded with the exe); nothing re-initialises them for a new game,
so a port must take them from `exe_image.bin` at start-up and save/load them with the block.

### 2.1 个人天赋 (personal talents) and 兵种技能 (class skills): table 0x511000 [C]

Pointer `[0x500c3b]` = 0x511000 (constant in the exe). 255 rows (sid 0..254) × 16 bytes:

| Row bytes | Meaning |
|---|---|
| +0 + 3k (k = 0..3) | person entry k: u16 person id, u8 value. Person 0x400 (= 1024, no person) = empty |
| +0xc + 2k (k = 0..1) | class entry k: u8 class id, u8 value. Class ≥ 0x50 (0xff) = empty |

Lookup (0x4198be, sid = row): personal value = the value of the **first** person entry whose id equals the person
(only one is used); class value = the first class entry that matches (0x42f998):

```
class_matches(entry_class, my_class):                     ; 0x42f998 (returns 0 = match)
    if entry_class >= 0x50: no
    if EV4058 != 0: return entry_class == my_class        ; 兵种特性向下继承 off
    return family(entry_class) == family(my_class) and entry_class <= my_class
family(c) = c < 60 ? c/3 : c < 80 ? c-40 : 40             ; 0x40687f
```

So by default (EV 4058 = 0) a class skill given to a tier-1 class is also held by tiers 2 and 3 of its family.

Writer: **script op 0x72 sub 5 习得特技** (0x408811), text `sid \n pos \n who \n value` (each number may be `*N` =
EV N, or negative; any single separator character):
* `pos` 0..3 → person entry pos: u16 = who (person id), u8 value.
* `pos` 4..5 → class entry pos−4: u8 class = who, u8 value.
* `sid` > 0xfe or `pos` > 5 → ignored. Writing person 1024 clears a slot (the scripts do this).

The scripts use it 9,236 times, mostly in "reset and re-grant" blocks; e.g. `20\n0\n12\n30` = 吸血攻击 30 for
person 12 (曹洪) in slot 0. Initial exe contents: every person slot 1024 with a template value (the default value the
mod uses for that sid, listed in §5), class entries e.g. sid 0 每回合恢复HP: 蛮骑兵(72) 30, 石像鬼(75) 20; sid 89
特效屏蔽: 皇帝(78) 1 (`skills.json` → `initial_class_skills`).

The person-info dialog lists the three skill groups 个人天赋 / 兵种技能 / 附加技能 (headers 0x48ec91, list builder
0x40f436 called from 0x401126; "  --" when a group is empty) with the value next to each name.

### 2.2 附加技能 (added / temporary skills): list 0x512dc0 [C]

A byte stream of at most 0x800 bytes: groups `FF sid` followed by 4-byte entries `[value, turns, u16 person]`,
the stream ends with `FF FF`. An entry counts only while `turns` ≠ 0 (0x42fbe1: value if turns ≠ 0, else 0).
`turns` 1..99 = temporary, counted down; ≥ 100 = permanent.

* **Lookup** 0x42fbe1(person, sid) → 0x436f16 (scan for group `sid`, then the entry with the person).
* **Insert / update** 0x402ac7(key = person | 0xffff0000, packed = sid | value<<8 | turns<<16, entry_extra = 1,
  list = 0x512dc0, overwrite):
  existing entry: overwrite ≠ 0 → value and turns replaced; overwrite = 0 → each becomes max(old, new).
  New entry: appended at the end of its group (memmove 0x40bb4b) or as a new group at the end of the list;
  ignored when the list would pass 0x800 bytes. (The same routine with entry_extra = 0 maintains the 3-byte lists
  0x507800 — strategies learned, op 0x72 sub 4 — and 0x507ec0 — op 0x72 sub 36.)
* **Writers**:
  * script op 0x72 **sub 35** (0x42fd47), text `sid,value,turns,person` → overwrite = 1. The scripts' only use is
    the reset loop `*0,0,0,119` (turns 0 = disable).
  * consumables of use type 0x34 附加技能 (handler 0x432a77, reached through the item-use jump table entry at
    0x44f364): target person gets sid = item+0x15 (file 0x15 "value"), value = item+0x16, turns = item+0x17,
    max-merged (overwrite = 0). Items 174 吸血卷軸 (sid 20, 20, 3 turns), 177 (sid 67 策略吸血, 20, 3), 178–182
    (sid 133..137 能力辅助 with codes 0x01/0x22/0x44/0x68/0x90 = +20 % 攻/防/精/爆/士, 3 turns).
  * strategy result code 28 (0x42fd09 ← 0x42282f in the per-target result switch 0x42269c): the target gets
    sid = MgMcall[s] (0x4d19f0 + s), value = MgHurt[s] (0x4d1840 + s), turns = MgHurtYN[s] (0x4d18d0 + s), max-merged
    — the strategy extension tables' animation / damage columns reused. In this mod only the blank strategies 112
    (sid 7 破坏防御, 1, 5 turns) and 113 (sid 111 末日审判, 1, 3 turns) carry such data [D]; which MgID yields result
    code 28 was not traced [G]. No 必杀 writes to this list.
* **Count-down** 0x42fc0c, called by the phase start 0x44ee30 (eax = 0 player phase, 1 enemy phase) before the
  per-unit start-of-phase work: for every entry with turns 1..99
  * person has no unit on the field → turns −1 (at both phase starts);
  * unit side (0x406710: 1 player/friend, 0 enemy, 2 third party) & 1 == phase flag → untouched (so a side's
    entries count down at the start of its own phase);
  * turns ≥ 2 → turns −1;
  * turns == 1 → it expires only if the roll 0x43786b(0x43c72c(unit, 0), 1) succeeds — the same per-unit chance the
    engine uses to shake off a status ailment (see 每回合恢复状态 in §5) — then message 0x2f (0x427cbc) and turns = 0;
    otherwise it stays at 1 and stays active.
* **Clean-up** 0x42fc8c removes every entry with turns ≤ 99 (expired or not) and empty groups; called only from
  0x473de1, i.e. script op 0x0a `clear_flags` (handler 0x415aca, which also zeroes 0x501b00..0x501fff — this
  includes the SP table 0x501c00 — and 0x510000..0x510c7f). Op 0x0a is in every R (story) script (and 52 S
  scripts), so temporary skills do not outlive the battle.

### 2.3 Equipment (item effect ids) [C]

Sources checked by the item part of the query (0x43c794 → 0x4079da presence, 0x407aed value), slots
weapon (+0x2e), armour (+0x31), accessory (+0x34) of the person record:
* weapon / armour: only treasures (odd type, 0x40b4e1) with item+0x14 == eid; value = ValueAtLevel(item, level)
* accessory: item+0x11 == eid; value = item+0x15 (no level)

Item values of several slots are merged by 0x407b9e with the query mode (0 sum, 1 max, 2 "7 is sticky else last",
3 OR, 4 last, ≥5 the slot mode−5 wins else first non-zero) and clamped to 255.

**ValueAtLevel** (0x4200f5; `sv` = item+0x16, `L` = equipment level, `k` = eid − 0x1a):
```
if eid == 0x1f (同仇破甲):  v = sv * (L+1)            ; then the level-10 rule below
elif L < 7:                 return sv
elif eid == 0x72 (限制伤害): v = sv*3 >> 2             ; then the level-10 rule
elif eid == 0x33 (穿透攻击): return sv == 4 ? 7 : sv
elif eid == 0x32 (远距攻击): return sv * 2
elif eid in (0x36 引导, 0x42 主动连击, 0x46 自动使用): return sv + 1
else: v = KIND[k] < 7 ? sv*3/2 : sv                     ; KIND = u8[230] at 0x4cb6ba
if L >= 10 and LV10[k] != 0xfe: return LV10[k]          ; LV10 = u8[240] at 0x4cb5ca ("10级宝物" values)
return v
```
KIND (0x4cb6ba) is the value's display kind (0x46215b formats it: 0 flag, 1 flat, 2 percent, …) and doubles as the
"×1.5 at level 7" switch; LV10 values per eid are in `skills.json`. Treasure max level is 10, normal equipment 5
(0x4201c1).

Stat item effects 0x20..0x28 also raise a stat (besides the 特效 some of them are paired with in §5, e.g. 0x22
倚天剑 = 精神 % + 辅助全防御): the equipment stat bonus 0x407c29(stat) adds, for a treasure
whose effect maps to the stat (0x40678e) and for an accessory whose type maps to it (0x4067ce), 0x452825(stat, v):
eids 0x20..0x26 → +v % of the person's base 攻/防/精/爆/士/HP/MP (the 神魔附体-adjusted value when that
applies; KIND 2), 0x27 → exp (+v), 0x28 → move (+v); eid 0x5c 神魔附体
maps to stat 9 and 0xfe to 0xa.

### 2.4 专属 (exclusive equipment) and 套装 (sets): table 0x50e000 [C]

256 rows (sid) × 16 bytes, initially all zero:

| Bytes | Entry | Matches when |
|---|---|---|
| +0, +4 | 专属 k = 0..1: u16 person, u8 item, u8 value | the person is the queried one and wears the item in any slot (empty slots 0xff never match); the first matching entry gives the value |
| +8, +0xc | 套装 k = 0..1: u8 weapon, u8 armour, u8 accessory, u8 value | for each of the three slots the entry is 0xff (don't care) or equals the item worn in **that** slot, and at least two slots are named; any person |

Read by 0x402cf9 (the last step of 0x41301e): acc = combine(mode, …) with the exclusive value, then with the set
value. Writer: script op 0x72 **sub 10 装备专属和套装** (0x411c4a):
* `0\n slot,sid,person,item,value` → 专属 entry slot (0/1) of row sid.
* `1\n slot,sid,weapon,armour,accessory,value` → 套装 entry slot (0/1); `255` = any. Writing 255,255,255 disables it.
* sid > 0xfe or slot > 1 → ignored. Item ids are item numbers (0..255).
The scripts use it 705 times (e.g. `1\n0,16,255,74,121,80` 皮衣+護心鏡 = 中毒攻击 80; `0\n0,51,…` 关羽+青龙偃月刀 =
致命一击).

### 2.5 必杀 tables

The 97 必杀 definitions (0x4a7510) and the learner table `[0x500c37]` = 0x512000 are described in §3.

### 2.6 Other script ops of the effect system (op 0x72 sub-functions) [C]

Op 0x72 (信息传送, handler 0x47d89e) parses a sub-function number and a text and calls the table 0x47d8df[sub].
Numbers in the text: optional `-` / `*` prefix (`*N` = EV N), any single separator (0x426e64).

| Sub | Handler | Text | Effect |
|---|---|---|---|
| 4 习得策略 | 0x402a96 | `strategy \n level \n person` | list 0x507800 (3-byte entries `[level, u16 person]` in groups `FF strategy`): the person learns the strategy at that level (strategy rules, not 特效) |
| 5 习得特技 | 0x408811 | `sid \n pos \n who \n value` | §2.1 |
| 6 习得必杀 | 0x40886e | `id \n pos \n level \n person` | §3 |
| 10 装备专属和套装 | 0x411c4a | §2.4 | §2.4 |
| 21 部队行动标识 | 0x4078ed | `mode, slot, x` | slot = battle unit slot (`*260` in the scripts = EV 260). mode 0: EV[x] = (unit+0x0d & 2) ? 1 : 0 (has the unit acted); mode ≠ 0: x ≠ 0 sets unit+0x0d bits 1\|2 (= done, 不可行动), x = 0 clears them (可行动), then redraws (0x44a88a). Not a 特效 |
| 35 (unnamed) | 0x42fd47 | `sid,value,turns,person` | 附加技能 entry, overwrite (§2.2) |
| 36 (unnamed) | 0x436eb0 | `stat,amount,person` | list 0x507ec0 (groups `FF stat`, entries `[amount, u16 person]`): amount ≠ 0 → set (overwrite), 0 → remove (0x436ef2). Read by 0x436e3d from the growth grade 0x4072f2(stat): grade (raw ability ≥ 99 → 10, ≥ 90 → 8, ≥ 70 → 6, ≥ 50 → 4, else 2; stats > 4 → 0) + amount (signed byte, a negative amount counts one less). "曹操提高防禦1" = +1 defence growth per level. Not a 特效 |
| 1 对指定人物释放法术 | 0x40c4b7 | `n0 \n strategy \n camera \n person…` | strategy context 0x497af8 set up by 0x4251e1(strategy, caster slot 0x3c); every listed person (< 0x400) standing on the field (unit state 2) becomes a target (≤ 250); `camera` ≠ 0 scrolls to the first target; then 0x406d64 casts. `strategy` ≥ 100 → nothing. n0 (−666 in the scripts) is not read by this handler [G: beyond it]. Not a 特效 |

### 2.7 Per-unit counters used by skills [C]

| Where | Meaning | Reset |
|---|---|---|
| unit+0x22 | 先制攻击 attacks made this phase (sid 82) | dword unit+0x22 = 0 for all 250 units at every phase start (0x44ac28 → 0x44ad37), together with the acted flags |
| unit+0x23 | 同仇敌忾 / 戮力同心 assist attacks made (sid 59 / 113; incremented 0x4105b8) | same dword write |
| unit+0x24 | 大杀四方 restored actions (low 7 bits) + bit 7 "restore pending" (sid 64) | same dword write |
| 0x508b00[slot] | 二次行动 state: 0 / 1 / 0xff = second action used (sid 56) | 0 at every phase start (0x44ad3d) |
| 0x508a00[slot] | hits taken, for 仇恨攻击 (sid 44); +1 per physical hit taken (0x40608a), ≤ 255 | slots 0..59 at the enemy-phase start, 60..249 at the player-phase start (0x420952 ← 0x44ee80); battle init (0x412207) |
| byte 0x500c48 | cells moved in the current action (冲锋攻击 sid 25) | 再次移动 sets 0 |
| byte 0x500c46 / words 0x500c42 / 0x500c44 | 策略连击 repeat guard / saved exp accumulators (sid 58) | 0x4230ea |
| word 0x500e9a | current action: byte 0 = 0 attack, 1 围攻 (assist group), 2 必杀; byte 1 (0x500e9b) = 必杀 id | each command / attack start 0x41058d |

## 3. 必杀 (武将技 / 文官必杀 / 军师技) [C unless marked]

Catalogue of all 97 records with learners and descriptions: `game/assets/data/skills.json` → `bisha`.

### 3.1 Definitions: 97 records × 16 B at 0x4a7510

Copied at boot from the 0x610 bytes after the 144 strategies in Data.e5 entry 5 (0x41b86e); getter 0x41e918
(`cl` = id). Never written afterwards and not saved. Description: Imsg 144 + id.

| Off | Meaning | Reader |
|---|---|---|
| +0x00 | name (≤ 10 bytes GBK) | menus, 0x413870, 0x417a96 |
| +0x0b | not read by the battle code [G: icon] | — |
| +0x0c | attack range code, replaces the class range while this 必杀 (id ≠ 0) is the current action | 0x43f8e1 |
| +0x0d | 穿透 shape (0 = none; 24 破阵 1, 25 血路 4, 26 破軍 2, 27 滅世 3, 76–79 1/4/5/7) | 0x484e27 via 0x407835 |
| +0x0e | SP cost (0x425ad0) | 0x465bcd, 0x423910, 0x4225d5 |
| +0x0f | effect value: `0x436334(cur, k)` returns it when the current 必杀 id cur ≠ 0 and cur == k | §3.5 |

Ids 0–79 武将技 (0 = 重击, always available), 80–88 文官必杀 (by class family), 89 "？？" (random 文官), 90–96 军师技
(named but unreachable). Shipped data: cost 100 for 重击, 255 (= full SP) for 1–27 and 80–89, 0 for 28–75, 80/80/80/60
for 76–79; value 7 for 0–6, 23–27, 77–79, 100 for 20 嗜血 and 21 斬首, 0 otherwise.

### 3.2 Learners: `[0x500c37]` = 0x512000, 80 rows × 16 B (in the saved block)

Row id: 5 × {u16 person (1024 = none), u8 learn level} at +0, +3, +6, +9, +0xc; byte +0xf = class family that owns the
必杀 without learning it (40 = none). Initial exe data: all slots (1024, 1), family 40.

* **Op 0x72 sub 6 习得必杀** (0x40886e), text `id \n pos \n level \n person` (4 numbers): id ≥ 0x50 ignored;
  pos 0..4 → slot pos = (person, level); pos ≥ 5 → byte row + pos·3 = low byte of `person` (pos 5 = the family
  byte, e.g. `21\n5\n200\n40` = 斬首 owned by no family; pos > 5 would write into the next row — no check).
  Scripts: 3,924 uses, mostly slot 0 and reset loops (`*0\n0..4\n99\n1024`).
* **Available** (0x418744, ecx = row): `family(person) == row[15]` or a slot with this person and person level ≥
  slot level (family ownership ignores the level).
* **Learn message** (LevelUp 0x4073f3 → 0x41bce6, unless EV 4059 == 1): only rows 0..0x1a, a slot whose level ==
  the new level → "领悟必杀技「%s」！".

### 3.3 SP (u8 per person at 0x501c00 + pid, in the saved block, max 255)

* Add 0x423930(unit, n, forced): unless forced, nothing for pid > EV 4030 (default 200, scripts set 1024); SP =
  min(SP + n, 255).
* **Gain on damage** 0x410fc3(receiver slot, n): nothing if EV 4087 ≠ 0 or EV 4059 == 1; `if Query(receiver, 36
  集气加倍, 0x41, 1, 0): n ·= 2`; receiver kind (unit+5) < 2 (player / friend) → n >> 2, else n >> 1; at least 1 if
  n > 0. Callers: 0x405a8e physical hit (receiver = each target, n = HP damage to it), 0x4229b0 strategy result
  (receiver = target, n = HP damage clamped to its HP), 0x423059 strategy cast (receiver = caster, n = 2·MP spent).
  The attacker gains nothing for hitting.
* Forced adds: 每回合恢复SP (sid 105), SP光环 (sid 103), SP consumables (0x42241e).
* Cleared: op 0x0a zeroes 0x501b00..0x501fff (all SP); revive (0x4277e6) sets SP 0 unless EV 4095 ≠ 0.

### 3.4 Use

* **Gate 0x4225fb**(unit): EV 4059 ≠ 0 → no. `attr8 = 0x4d2200[family]` (文官 families: 君主 7, 策士 5, 医师 1,
  道士 4, 統軍 5, 都督 9, 咒术士 3, 阴阳师 6, 辎重队 7, 仙人 8, 皇帝 2, 百姓 6): attr8 ≠ 0 → cost = record(0x4f + attr8)
  .cost, kind 2; else player-controlled (unit+0xe == 7) → yes (menu always offered); else (AI) cost = EV 4061 (default
  100), kind 1. 禁咒 → no. Returns kind if SP ≥ cost.
* **Player 武将技** (command 5 → 0x423358): 禁咒 / already acted → refuse. List 0x411261: 重击 always, ids 1..0x4f
  with 0x418744 (attr8 families: only their 文官 id); an entry is selectable iff its cost ≤ SP (0x465bcd). Then
  action word 0x500e9a = id<<8 | 2, target selection, 0x417a96 (name; ids 1..6 → own buff stat id−1 raised
  (0x409821(stat, 1): < 3 → 3, else 6); id 7 金刚 → result code 0x57 on self = 攻/防/爆/士 up), attack 0x43db23,
  acted, **SP −= min(SP, cost)** (0x423910).
* **AI 武将技**: before an AI unit acts (0x44e825), gate == 1 → 0x4225a2 picks the first id 1..0x4f available with
  SP ≥ cost, else 重击 (cost not checked); attack 0x465fab (same execution, SP −= min(SP, cost)). Units passing the
  gate form the first group of the AI action order (0x44db19; 都督 attr8 9 → order code 0x75). AI-FLOW track.
* **文官必杀** 0x467c9e (player command 5 first, AI 0x43b2cb): needs EV 4087 == 0, gate ≠ 0, attr8 ≠ 0; idx =
  attr8 − 1, or rand(8) when attr8 − 1 ≥ 9 (id 89 ？？); no targeting; jump table 0x467d1d[idx]; SP −= min(SP, 255).
  Area: whole map (0x0a) when the caster's kind ≥ 2 (enemy), else shape 0x0c around the caster [G shape].

| idx | id | name | handler | effect |
|---|---|---|---|---|
| 0 | 80 | 重生 | 0x451195 | own side incl. self: heal (0x43c5df) and clear status |
| 1 | 81 | 歷精圖治 | 0x4510ba | own side: all buffs = 6 |
| 2 | 82 | 八陣圖 | 0x451129 | enemies: all buffs = 0 |
| 3 | 83 | 巫蠱 | 0x42ac0a | 0x45ade7(0, 0, H, W, camp, 6, 0x16) — the map rectangle with width and height swapped, units of the other camp (home code 5 / 4): ailments 0x16 = 麻痹 禁咒 中毒 (status event 6, the 0x4240d6 masks), Meff 0x31 unless EV 4043 [C] |
| 4 | 84 | 鼓舞 | 0x41dbcd | own side: 气合 up (buff code 0x35) |
| 5 | 85 | 賣慘 | 0x422c4a | enemies: 气合 down (0x1b) |
| 6 | 86 | 濟世 | 0x43bf2a | as 重生, then move buff 6 and MP restore 0x436ce1(50) [G] |
| 7 | 87 | 超度 | 0x436d8b | map-wide 八阵图 variant; own side's status cleared [C part] |
| 8 | 88 | 再戰 | 0x410339 | own side (not self): acted flags cleared (act again) |

### 3.5 What a 武将技 does

Common to every 武将技 (action kind 2): hit 100 % (0x43b62d); forced critical (0x405eb8, +50 %; a defender with
防御致命攻击 still nullifies it unless the attacker has 忽视暴防); the damage preview adds the same +50 % (0x406b0e ← 0x43bf06, preview only); no counter
(0x406453 runs only for kind 0); range from +0x0c, 穿透 from +0x0d.

Id-specific hooks `0x436334(cur, k)` — when the value is ≠ 0 the named effect is forced, otherwise the unit's own 特效
query decides (so these are the same code paths as the 特效 in §5):

| k | 必杀 | Site | Forced effect (value v) | 特效 path otherwise |
|---|---|---|---|---|
| 8..13 | 破攻 破防 破精 破敏 破士 破移 | 0x4039b6 | debuff stat k−8 | 破坏X (6..11) |
| 14 | 折磨 | 0x472d79 | min(v, 6) random debuffs | 随机破坏能力 (12) |
| 15..18 | 捕縛 攻心 威風 虚弱 | 0x403a0d | 麻痹 / 禁咒 / 混乱 / 中毒 without a roll | 13..16 |
| 19 | 鬼门 | 0x405a4d | random statuses by weapon level | 随机异常状态 (17) |
| 20 | 嗜血 | 0x406b7c | 吸血 min(v, 100) % | 吸血攻击 (20) |
| 21 | 斬首 | 0x43bc9e | damage = maxHP·v % (100 = kill) | 破甲攻击 (22) |
| 22 | 驱逐 | 0x41108a | 突破攻击 | 加强 / 突破 (98 / 97) |
| 23 | 血戰 | 0x436415 | 奋战攻击 without the 2-attack limit | 奋战攻击 (23) |

Data quirk: as shipped, 8–19 and 22 have value 0, so they never force their named effect (only the common bonuses);
嗜血, 斬首 (100) and 血戰 (7) do.

## 4. The query (0x4101d9 and its layers) [C]

### 4.1 Signatures

| Function | Call | Returns | Notes |
|---|---|---|---|
| **0x4101d9** Query | `ecx` = battle unit **or** person record; stdcall (sid, eid, mode, a4), `ret 0x10` | eax = value, edx = the unit's own item part | battle only (see 4.4) |
| 0x42518f QueryAny | `ecx` = person or unit; same args | as above | in battle (0x40b922: scene mode 3) → 0x4101d9, else 0x41301e |
| 0x41301e QuerySources | `ecx` = person record; same args | eax = value, edx = item part | no 屏蔽 / 模仿 |
| 0x4198be | skill part: personal (0x511000) ⊕ 附加技能 (0x512dc0) ⊕ class | | |
| 0x43c794 | item part: 0x4079da presence, 0x407aed value | eax, ecx = 1 if an item matched | |
| 0x402cf9 | 专属 ⊕ 套装 (0x50e000) | | |

Arguments: `sid` is masked to a byte; `eid` 0 means "no item effect" (no item has eid 0); `mode` is the combine
rule; `a4` ≠ 0 makes a matching item count as **100** instead of its value (used when only presence matters).

### 4.2 Algorithm

```
QuerySources(P, sid, eid, mode, a4):                      ; 0x41301e
    pid = P.id                                            ; (P - [0x4cea00]) / 0x48, 0x40be7d
    row = 0x511000 + sid*16
    s = first k<4 with row.person[k] == pid ? row.value[k] : 0
    s = C(mode, Added(pid, sid), s)                       ; 附加技能 0x42fbe1 (0 unless turns != 0)
    s = C(mode, first matching class entry value or 0, s)
    item = has_item_effect(P, eid) ? (a4 ? 100 : ItemValue(P, eid, mode)) : 0      ; 0x43c794
    v = C(mode, item, s)
    v = C'(mode, v, exclusive_value(P, sid))              ; 0x402cf9, 0 if none
    v = C'(mode, v, set_value(P, sid))
    return v (eax), item (edx)

Query(X, sid, eid, mode, a4):                             ; 0x4101d9
    (P, U) = resolve(X)                                   ; 0x426a07, below
    if U is "none" (slot byte 0xff): return 0
    gate = U.person < EV4062                              ; EV 4062 default 1024 = everyone
    if gate and not Shielded(U) and EnemyShieldAdjacent(U): return 0          ; 特效屏蔽
    v = QuerySources(P, ...) ; item_part = edx
    if gate and QuerySources(P, 88 特效模仿, 0x74, 1, 1) != 0:                 ; 0x43c414
        for each of the 4 neighbour cells of U (up, right, down, left; 0x4359f5 table 0x435a3e):
            if a unit stands there (0x435884): v = C(mode, QuerySources(that unit's person, ...), v)
    return v (eax), item_part (edx)
```

`C(mode, new, acc)` = 0x413009 → 0x40bf2f, and `C'` is the same routine with the operands swapped (0x402cf9
passes the accumulator as "new"):

| mode | C(mode, new, acc) | meaning |
|---|---|---|
| 0 | acc + new (32-bit) | sum of all sources |
| 1 | max(acc, new) unsigned | best source |
| 2 | if acc == 0: acc = new; result = (new & 0xff) == 7 ? new : acc | first non-zero source wins, but a value 7 overrides; with `C'` the later 专属/套装 value wins over the earlier ones unless the earlier is 7 |
| 3 | acc \| new | bit masks (OR) |

Order of the sources: personal → 附加技能 → class → item → 专属 → 套装 → neighbours (模仿). Only mode 2 depends on
it. The item part itself merges the three slots with 0x407b9e (§2.3) and is ≤ 255; skill values are bytes, so with
mode 0 a sum can exceed 255 (callers clamp where needed).

### 4.3 特效屏蔽 and 特效模仿 (sid 89 / 88)

* `Shielded(U)` (0x40f1ac): U's person has 特效屏蔽 (0x43c426 = QuerySources(P, 89, 0x75, 1, 1)), or U has
  特效模仿 (0x43c414) and scanning the 4 neighbours for units with 特效屏蔽 finds a same-side one before any
  other-side one (an other-side 屏蔽 neighbour ends the scan with "no").
* `EnemyShieldAdjacent(U)` (0x425390): some neighbour on another side (0x406710 side code differs) is
  `Shielded`.
* So a unit next to an enemy holding 特效屏蔽 loses **every** queried effect (all sources, items too) unless it is
  itself shielded. 特效模仿 / 特效屏蔽 themselves are read with QuerySources and are never blocked or copied.
* 特效模仿 adds the neighbours' values from all four sides, **friend or foe**, without their own 模仿 (no chains).
* Both are skipped for persons with id ≥ EV 4062 (they can neither be blocked nor copy).

### 4.4 Resolving the argument (0x426a07)

* `ecx` → word < 0x1000: it is a battle unit (0x30 B at 0x4a7b20): P = person of the unit (0x40658f), slot byte =
  unit+4.
* word ≥ 0x1000: a person record. In battle (0x40b922) the unit is found by 0x43e4d6 (slots 0..249 with
  unit+0 == id; slot 0xff = none → Query returns 0 for persons not on the field). Shortcut: if the person is the
  unit cached in `[0x500ac8]` (set by the unit stat getters 0x43f5ff..) that unit is used and the "slot byte" is the
  low byte of the person id — persons 255/511/767/1023 would then read as "no unit" (quirk, harmless in this mod).
* Outside battle the unit pointer is 0 and 0x4101d9 would dereference address 0; every out-of-battle caller uses
  0x42518f or 0x41301e instead.

### 4.5 Helpers worth naming

| VA | Use |
|---|---|
| 0x43c414 / 0x43c426 | has 特效模仿 (88, 0x74) / 特效屏蔽 (89, 0x75), QuerySources, mode 1, a4 1 |
| 0x4079da(eid) | does the person wear an item with effect eid (presence only) |
| 0x407aed(eid, mode) | item part value (slot merge 0x407b9e) |
| 0x4200f5 | ValueAtLevel of a treasure (§2.3) |
| 0x42fbe1(pid, sid) | 附加技能 value (and `cl` = turns) |
| 0x42f998 | class entry matching (EV 4058) |

## 5. Catalogue of 特效 ids [C unless marked]

Every query pair found in Ekd5.exe: 105 calls of 0x4101d9, 6 of 0x41301e, 4 of 0x42518f, the computed-id loops and
the function-pointer tables 0x415e2b (同仇/戮力), 0x412c70 (能力替换/辅助), 0x42f8c5 (auras). `Q(U)` = the query on unit
U with the row's (sid, eid, mode, a4); "def" = the unit's default value in the exe's 0x511000 row (what the mod
writes with op 0x72 sub 5 is usually the same). No caller uses the edx item part except 神魔附体 (61). Names in
parentheses after an eid are the mod's item-effect names (0x4cb7a0). `pct(a, b)` = a·b/100 (0x425ad9, unsigned).

### 5.1 Master table

| sid | 特效 | eid (item name) | mode/a4 | value | effect (details in 5.2–5.11) |
|---|---|---|---|---|---|
| 0 | 每回合恢复HP | 0x25 (辅助與恢復HP) | 0/0 | % maxHP, def 30 | own phase start: heal pct(maxHP, v) |
| 1 | 每回合恢复MP | 0x1b | 0/0 | MP, def 10 | own phase start: +v MP |
| 2 | 每回合恢复状态 | 0x1c | 1/1 | flag | status-recovery chance 100 (ailments and debuffs cured at phase start) |
| 3 | 每回合获得exp | 0x1d (随机异常状态) | 0/0 | exp, def 30 | player units: +v·(100+exp bonus)/100 exp per turn |
| 4 | 每回合武器exp | 0x73 (裝備Exp與轉傷) | 0/0 | def 3 | ditto weapon exp |
| 5 | 每回合护具exp | 0x73 | 0/0 | def 3 | ditto armour exp |
| 6..11 | 破坏攻击/防御/精神/爆发/士气/移动 | 0x34 / 0x24 / 0x54 / 0x2d / 0x2c / 0x5f | 1/1 | flag | on hit: target's buff of that stat → lowest (or back to normal if buffed) |
| 12 | 随机破坏能力 | 0x5e | 1/0 | count, def 1 | on hit: min(v, 6) random stats debuffed |
| 13 | 麻痹攻击 | 0x2d (麻痹破爆) | 1/1 | % chance, def 60 | on hit: 麻痹 1 turn |
| 14 | 禁咒攻击 | 0x26 (辅MP與策略命中) | 1/1 | %, def 30 | on hit: 禁咒 2 turns |
| 15 | 混乱攻击 | 0x2b | 1/**0** | %, def 60 | on hit: 混乱 1 turn (items give their value, not 100) |
| 16 | 中毒攻击 | 0x2c (遠程中毒破士) | 1/1 | %, def 80 | on hit: 中毒 3 turns |
| 17 | 随机异常状态 | 0x1d | 1/1 | flag | on hit: each ailment rolled by weapon level |
| 18 | 反弹异常攻击 | 0x2a (化險為夷) | 1/1 | flag | ailments aimed at it go to the attacker; own ailments/debuffs cleaned after actions |
| 19 | 反弹伤害 | 0x42 (主动连击) | 1/0 | %, def 30 | attacker loses Σ pct(damage, v) (never lethal) |
| 20 | 吸血攻击 | 0x65 | 1/0 | %, def 30 | attacker heals min(v,100) % of the damage dealt |
| 21 | 吸收金钱 | 0x5b (金钱防御) | 1/1 | flag | gold ± damage dealt |
| 22 | 破甲攻击 | 0x1f (同仇破甲) | 1/0 | damage, def 30 | physical damage = v (fixed) |
| 23 | 奋战攻击 | 0x36 (引导攻击) | 1/0 | flag | after attacking: up to 2 more attacks on other enemies in range |
| 24 | 引导攻击 | 0x36 | 1/1 | flag | after a kill: up to 2 more attacks |
| 25 | 冲锋攻击 | 0x5f | 1/0 | %/cell, def 5 | damage +v % per cell moved this action |
| 26 | 先手攻击 | 0x29 (先手突擊閃避) | 1/1 | flag | defender strikes first if the attacker is in its range |
| 27 | 策略绝对命中 | 0x1b (每回合恢复MP) | 1/1 | flag | own strategies hit 100 % |
| 28 | 辅助策略命中 | 0x26 | 1/0 | +pts, def 10 | strategy hit +v |
| 29 | 辅助策略防御 | 0x29 | 1/0 | −pts, def 10 | strategy hit against it −v |
| 30 | 攻击绝对命中 | 0x24 (辅士破防必中) | 1/1 | flag | own physical attacks hit 100 % |
| 31 | 辅助攻击命中 | 0x7e (MP辅助) | 1/0 | +pts, def 10 | physical hit +v |
| 32 | 辅助攻击防御 | 0x29 | 1/0 | −pts, def 15 | physical hit against it −v |
| 33 | 辅助全防御 | 0x22 (辅精神加格檔) | 1/0 | −pts, def 10 | final −v on every hit chance against it |
| 34 | 减轻远距损伤 | 0x45 | 1/0 | −%, def 40 | damage from ranged families −v % |
| 35 | 减轻物理损伤 | 0x3d | 1/0 | −%, def 20 | physical damage −v % |
| 36 | 集气加倍 | 0x41 (防御特殊攻击) | 1/0 | flag | SP gained from damage ×2 |
| 37 | 反击后反击 | 0x30 | 1/1 | flag | may answer a counter (attack → counter → counter) |
| 38 | 无反击攻击 | 0x34 (无反破攻忽防爆) | 1/1 | flag | its attacks are not countered |
| 39 | 辅助妨碍策略 | 0x20 (輔攻擊妨礙) | 1/0 | %, def 25 | strategy hit +10 (flag); damage of strategy kinds ≥ 4 +v % |
| 40 | 辅助四类策略 | 0x38 (辅助四系策略) | 1/0 | %, def 20 | damage of 火水地风 strategies +v % |
| 41 | 减轻策略损伤 | 0x43 | 1/0 | −%, def 20 | strategy damage −v % (floor 0) |
| 42 | 策略无视天气 | 0x3a (可以禁咒) | 1/1 | flag | fire / 四神 strategies ignore weather |
| 43 | 策略无视地形 | 0x38 | 1/1 | flag | elemental strategies ignore the target terrain |
| 44 | 仇恨攻击 | 0x4a (仇恨猛擊盾反) | 1/0 | %, def 10 | damage +v % per physical hit it took since the other side's phase began |
| 45 | 策略模仿 | 0x3b (仿策連擊) | 1/1 | flag | may cast the strategies of the 4 adjacent units |
| 46 | 节约MP | 0x39 | 1/0 | %, def 50 | MP cost ·(100−v)/100 |
| 47 | 防御远距攻击 | 0x4e (防遠克制) | 1/1 | flag | ranged-family physical attacks never hit it |
| 48 | 防御致命攻击 | 0x41 | 1/1 | flag | a critical hit on it deals 0 |
| 49 | 防御二次攻击 | 0x41 | 1/1 | flag | the second strike of an exchange deals 0 |
| 50 | MP防御 | 0x44 (MP辅助防御) | 1/1 and 0/0 | flag / MP | physical HP damage taken from MP; mode-0 value added to MP regen |
| 51 | 致命一击 | 0x31 | 3/0 | mask 1 phys 2 strat | always critical (+100 to the rate) |
| 52 | 主动连击 | 0x42 | 1/1 | flag | double-attack rate 100 when attacking |
| 53 | 双枪攻击 | 0x42 | 1/0 | flag | always a second strike (also on counters) |
| 54 | 穿越移动 | 0x5d | 1/1 | flag | ignores ZOC, passes enemies, cheaper terrain |
| 55 | 突击移动 | 0x29 | 1/1 | flag | ignores ZOC |
| 56 | 二次行动 | 0x5a | 1/1 | flag | one extra action per phase |
| 57 | 唯我独尊 | 0x61 | 1/1 | flag | every stat it uses = its highest stat |
| 58 | 策略连击 | 0x3b | 1/1 | flag | each strategy is executed twice |
| 59 | 同仇敌忾 | 0x1f | 1/0 | count, def 3 | joins allies' attacks on an enemy (v times) |
| 60 | 众志成城 | 0x1c (每回合恢复状态) | 1/0 | %, def 2 | units around it: ±n·v % to their stats |
| 61 | 神魔附体 | 0x5c | 0/0 (+edx) | growth grade | battle stats recomputed with grade v |
| 62 | 辅助地形状态 | 0x2a | 1/1 | flag | terrain effect ≥ 110 % |
| 63 | 恶路移动 | 0x2a | 1/1 | flag | every passable terrain costs 1 |
| 64 | 大杀四方 | 0x54 | 1/0 | count, def 2 | a kill restores the action (v times per phase) |
| 65 | 增加视野 | — (0) | 1/0 | shape, def 4 | sight shape v−2 when v ≥ 12 (no item; 0x41301e) |
| 66 | 策略反伤 | 0x55 | 1/0 | %, def 30 | caster of a damaging strategy loses pct(damage, v) (never lethal) |
| 67 | 策略吸血 | 0x56 | 1/0 | %, def 20 | caster heals pct(total strategy damage, v) |
| 68 | 洪荒之力 | 0x6e | 1/1 | flag | strategies may be aimed at an empty cell |
| 69 | 获得功勋 | 0x3a | 1/0 | +n, def 4 | +v 功勋 per award (via 0x42518f) |
| 70 | 深入敌后 | 0x68 | 0/1 | flag | belongs to the side whose phase it is |
| 71 | 一夫当关 | 0x69 | 0/0 | %, def 20 | stats +v % when alone in its 3×3, else +v/2 % |
| 72 | 强化反击 | 0x6a (偷梁换柱) | 1/1 | flag | its counters are not reduced to 3/4 |
| 73..80 | 学会策略 (四系 降能力 妨碍 补给 升能力 气候 绝 四神) | 0x6c | 3/0 | MgLearn mask | learns every strategy whose 0x4d17b0 mask matches |
| 81 | 鬼神之勇 | 0x6d | 0/0 | cap %, def 20 | stats + min(lost-HP % / 2, v) % |
| 82 | 先制攻击 | 0x51 | 0/0 | count, def 1 | strikes player units entering its range (v per phase) |
| 83 | 众矢之的 | 0x6f | 3/0 | mask, def 3 | AI prefers it as a target (1 physical, 2 strategy) |
| 84 | 批亢捣虚 | 0x70 | 1/0 | stat, def 6 | its target defends with stat v−1 (≥ 6: lowest stat) |
| 85 | 万夫莫敌 | 0x71 | 1/0 | %, def 4 | stats +(n+1)·v %, n = enemies in its 3×3 |
| 86 | 限制伤害 | 0x72 | 1/0 | cap, def 200 | physical damage taken ≤ v |
| 87 | 转移伤害 | 0x73 | 1/0 | %, def 20 | moves pct(damage, v) to the weakest enemy in its range |
| 88 | 特效模仿 | 0x74 | 1/1 | flag | copies the 4 neighbours' 特效 (§4.3) |
| 89 | 特效屏蔽 | 0x75 | 1/1 | flag | adjacent enemies lose all 特效 (§4.3) |
| 90 | 再次移动 | 0x5f (冲锋攻击) | 1/1 | flag | may move again after acting |
| 91 / 92 | 远距攻击-攻击 / -策略 | 0x76 | 3/0 | mask 1 / 2 | attack / strategy range code upgraded |
| 93 | 策略追击 | 0x77 | 1/0 | strategy+1, def 31 | after each strike casts strategy v−1 on the target |
| 94 | 策略先手 | 0x78 | 1/0 | strategy+1, def 31 | when attacked / targeted casts v−1 on the attacker first |
| 95 | 策略反击 | 0x79 | 1/0 | strategy+1, def 9 | counters with strategy v−1 |
| 96 | 左天羅右地網 | 0x7a (忽视能力) | 1/1 | flag | adjacent enemies cannot move and lose their attack range |
| 97 | 突破攻击 | 0x35 (加强攻击) | 1/1 | flag | knocks the defender back (+30 % if blocked) |
| 98 | 加强攻击 | 0x35 | 0/0 | %, def 20 | physical damage +v % (excludes 突破) |
| 99 | 策略免疫 | 0x4f | 1/1 | flag | enemy strategies never hit it |
| 100 | 健康光环 | 0x7b (能力辅助) | 1/1 | flag | same-side units in its 8 cells: all ailments cured |
| 101 | HP光环 | 0x52 (生命光环) | 0/0 | %, def 15 | same-side units in its 8 cells heal pct(maxHP, v) |
| 102 | MP光环 | 0x53 (魔力光环) | 0/0 | %, def 10 | ditto MP |
| 103 | SP光环 | — | 0/0 | SP, def 8 | ditto +v SP |
| 104 | 诅咒光环 | — | 0/0 | %, def 16 | other-side units in its 8 cells lose pct(maxHP, v) (never lethal) |
| 105 | 每回合恢复SP | — | 0/0 | SP, def 1 | own phase start: +v SP |
| 106 | 偷梁换柱 | 0x6a | 1/0 | stat, def 2 | its attacker uses stat v−1 (≥ 6: lowest) against it |
| 107 | 金钱防御 | 0x5b | 1/1 | flag | physical damage reduced to 1 (player units pay 10 gold per point) |
| 108 | 自动使用 | 0x46 | 1/0 | item id, def 190 | uses that consumable automatically after being hit |
| 110 | 斩杀攻击 | 0x7d (HP辅助) | 1/0 | %, def 4 | kills a defender at HP ≤ pct(maxHP, v) |
| 111 | 末日审判 | 0x48 | 3/0 | mask 1 phys 2 strat | damage + pct(maxHP, 10..14) |
| 112 | 忽视暴防 | 0x34 | 1/1 | flag | 防御致命攻击 does not stop its criticals |
| 113 | 戮力同心 | 0x58 | 1/0 | count, def 1 | joins the attack when an ally is attacked (v times) |
| 114 | 猛击 | 0x4a | 1/0 | %, def 15 | target that blocked/dodged loses v % current HP + 混乱 |
| 115 | 盾反 | 0x4a | 1/0 | %, def 15 | attacker that missed loses v % current HP + 麻痹 |
| 116 | 状态强化 | 0x4c | 1/0 | code, def 11 | stronger buffs / weaker debuffs for it and its neighbours |
| 117 | 疾风攻击 | 0x4c | 1/0 | move, def 13 | damage +5 % per move point the defender has below v |
| 118 | 绝对克制 | 0x4e | 1/0 | ±%, def 10 | class matchup +v when attacking, −v when defending |
| 128..132 | 能力替换 ×5 | 0x7c | 2/0 | code | stat = max(stat, source stat) |
| 133..137 | 能力辅助 ×5 | 0x7b | 2/0 | code | stat + 20 % of the source stat |
| 138..143 | 忽视能力 ×6 | 0x7a | 3/0 | stat mask | opponent's masked stat −20 % |
| 144..150 | 自动提升 ×7 | 0x66 | 3/0 | buff mask | own phase start: masked buffs to max |
| 151..156 | Buff光环 ×6 | 0x7f | 3/0 | buff mask | same-side units in its 8 cells: masked buffs = 6 |
| 157..161 | HP辅助 ×5 | 0x7d | 3/0 | stat mask | masked stat + current HP / 5 |
| 162..166 | MP辅助 ×5 | 0x7e | 3/0 | stat mask | masked stat + current MP; physical hits drain 1 MP |
| 167 / 168 | 辅助穿透-攻击 / -策略 | 0x57 | 3/0 | mask 1 / 2 | pierce / area shape upgraded (via 0x42518f) |
| 169..171 | 龙巡四海 / 虎啸山林 / 万里龙城 | 0x2a | **0**/0 | terrain-class mask | 169/170: terrain effect 120 % on matching terrain and move cost 1 on all passable terrain; 171 bit 4: the cell it stands on reads as 关隘 |

Unused: 109 (6D), 119..127, 172..254 have no query (their names are placeholders).

Code values: "code" for 能力替换/能力辅助 = source·0x20 + target mask (source 0 攻 1 防 2 精 3 爆 4 士; mask 1 攻 2 防
4 精 8 爆 16 士; `能力替換.txt`); stat masks use the same bits; buff masks 1 攻 2 防 4 精 8 爆 16 士 32 移 (0x3f = all).

### 5.2 Phase start (recovery, exp, auras)

Order at the start of a side's phase (0x44ee30(side): side 0 → slots 0..59, else 60..249) — after the per-phase
reset 0x44ac28 (§2.7) and 深入敌后 (0x416f38):
1. 0x42fc0c — 附加技能 count-down (§2.2).
2. For each slot: 0x4263b0 status recovery, then 0x43c940 buff decay.
3. 0x420952 (仇恨 hit counters of the other side reset), 0x44dfc7.
4. For each slot on the map: **0x43cddd**: auras 0x42f8d9 → 自动提升 0x43d038 → HP / SP / MP regen → exp.

* **Status-recovery chance** 0x43c72c(U, flag): flag 1: `Q(U, 2 每回合恢复状态, 0x1c, 1, 1) ? 100 :
  0x4070e1(U, 士气)/2`; flag 0: `s = 士气 & 0xff; s > 100 ? 10 : max(60 − s/2, 0)` (as coded).
  * 0x4263b0 → 健康光环 first: if U has any ailment and a same-side unit N in the 8 surrounding cells has
    `Q(N, 100, 0x7b, 1, 1)` → all ailments cleared (0x43d16a, 0x45aa37 code 0x9e); else 0x42402c(U, chance(1)):
    per ailment k: chance ≥ 100 → cured; counter ≠ 1 → −1; counter 1 → cured if the roll passes (EV 4023: 0 → roll
    0x43786b(p, 0); 1 → pseudo-random stream 0x455e25; 2 → always).
  * 0x43c940 buff decay, per buff j (unit+0x18+j): 3 keep; ≥ 5 → −1; 4 → 3 if roll(chance(0), 1); ≤ 2: chance(1) ==
    100 (每回合恢复状态) → 3 at once, else 2 → 3 if roll(chance(1), 0), 0/1 → +1.
* **0x43cddd** (unit state 2), T = terrain heal value 0x428a25 (terrain 0x12..0x16 → 0x41e467(t), else 0):
  ```
  hp = pct(maxHP, T) + pct(maxHP, Q(U, 0, 0x25, 0, 0))             ; 0x4210f4 ← 0x43ce37
  sp = Q(U, 105, 0, 0, 0); if sp: SP += sp (forced, cap 255)         ; 0x43d0fa ← 0x43ce75
  mp = T + Q(U, 1, 0x1b, 0, 0) + Q(U, 50, 0x44, 0, 0)               ; 0x421106 ← 0x43ce8f, 0x42109a ← 0x43ce9a
  中毒 (0x423fa1): hp /= 2, mp /= 2;  hp = min(hp, maxHP − HP); mp = min(mp, maxMP − MP)
  if U.kind == 0 (player):                                           ; 0x43cef7
      g[k] = pct(Q(U, 3+k, (0x1d, 0x73, 0x73)[k], 0, 0), 100 + equipment exp bonus (stat 8, 0x407faa))
      exp += g0 (0x4088cd), weapon exp += g1, armour exp += g2 (0x4082dd)
  popup 0x450986, then HP += hp, MP += mp
  ```
* **Auras 0x42f8d9**(U) (pointer table 0x42f8c5 = 0x42f88e, 0x42f8a1, 0x42f8b3, 0x43d0d6, 0x43d0e8); each sets the
  pseudo-strategy context 0x4251e1(0x497af8, 0x43, U) and collects targets with 0x422caf: area code 1 = the 8
  surrounding cells, U excluded, HP > 0, same side as U (诅咒光环: other side).
  * Buff光环 151..156 (mask = OR of `Q(U, 151+i, 0x7f, 3, 0)`, i = 0..5): for each bit j (攻 防 精 爆 士 移) every
    target's buff j = 6 (0x42dc04).
  * HP光环 101 (`Q(U, 101, 0x52, 0, 0)`): heal min(pct(maxHP, v), maxHP − HP) (0x422e68).
  * MP光环 102 (`Q(U, 102, 0x53, 0, 0)`; v > 100 → 0): 0x436ce1(v): pct(maxMP, v) (v = 0 → (level+10)/10), capped.
  * SP光环 103 (`Q(U, 103, 0, 0, 0)`): SP += v (forced).
  * 诅咒光环 104 (`Q(U, 104, 0, 0, 0)`): other side loses max(pct(maxHP, v), 1), at most HP − 1 (0x44e024).
* **自动提升 0x43d038** (`Q(U, 144+i, 0x66, 3, 0)`, i = 0..6): v == 0x3f → if any buff ≤ 3 all six buffs = 6 (message
  0x26) and stop; else for each bit j with buff_j ≤ 3: buff_j = 3 if it was < 3, else 6 (0x414361(j, 1), shown).

### 5.3 Physical attack: hit, double, critical

Physical hit rate **0x43b623**(A, D) (← 0x43b4ca), in order:
```
if action kind == 2 (必杀): 100
if !0x47ef3d(A, D): 0       ; A's family ranged (0x4281af: 0x4d2138[family]) and Q(D, 47 防御远距攻击, 0x4e, 1, 1)
if D 麻痹: 100
rate = 0x43b53a(爆发 pair 0x40d2ab(A,3,D,3,0))
if Q(A, 30 攻击绝对命中, 0x24, 1, 1): 100
rate = min(rate + Q(A, 31, 0x7e, 1, 0), 100)            ; 辅助攻击命中
rate = rate − Q(D, 32, 0x29, 1, 0) (saturating)          ; 辅助攻击防御
rate = 0x408eee(A, D, rate)
```
0x408eee (end of both hit functions): rate = min(rate + facing bonus 0x408db1 (EV 4066), 100); rate −= Q(D, 33
辅助全防御, 0x22, 1, 0) (saturating, wrapper 0x410edb ← 0x408f15); 0 → 1.

* Double attack: rate 0x405cb9 = `Q(A, 52 主动连击, 0x42, 1, 1) ? 100 : 0x405d0a(爆发 pair)`; "another strike?"
  0x4060d2 after each strike: `Q(A, 53 双枪攻击, 0x42, 1, 0)` and strike index 0 → yes (also in counters); else
  counter exchange → no; else roll the double rate (0x4287a8). At most 2 strikes per exchange.
* Critical: rate 0x40c7d8 (+100 if `Q(A, 51, 0x31, 3, 0) & 1`, wrapper 0x44f9a9); in 0x405de1 at 0x405ef0 for target
  0: if a critical happens, `0x42aa2a`: `!Q(A, 112 忽视暴防, 0x34, 1, 1) && Q(D, 48 防御致命攻击, 0x41, 1, 1)` →
  damage 0 (crit flag still set); else damage += damage·rate'/200.
* Per target i of a strike (0x405de1): second strike (combat+0x608 > 0) and `Q(T_i, 49 防御二次攻击, 0x41, 1, 1)` →
  damage 0; MP辅助 holder (0x414d70) with MP > 50 % loses 1 MP per hit; MP防御 / 金钱防御 (5.9).

### 5.4 Physical damage 0x43bc5a(A, D, preview, counter)

```
if 斩杀: Q(A, 110, 0x7d, 1, 0) = v and D.HP <= pct(maxHP_D, v): dmg = D.HP → skip to the final cap  ; 0x43637b
if 必杀 斬首 value v: dmg = pct(maxHP_D, v) → 限制伤害
elif v = Q(A, 22 破甲攻击, 0x1f, 1, 0): dmg = (byte 0x4cb6bf == 1) ? v : pct(maxHP_D, v)   ; byte is 1: fixed v
    → 限制伤害
(atk, def) = 0x40d2ab(A, 0, D, 1, 0); hit roll (not preview) fails → 0
dmg = level_A + 25 + (atk − def)/5   (atk < def: max(level_A + 25 − (def − atk)/5, 1))
v = Q(A, 117 疾风, 0x4c, 1, 0); m = move points of D (0x43f74f, 麻痹 → 0); if m < v: dmg += pct(dmg, 5·(v − m))
m% = matchup[fam A][fam D] + Q(A, 118 绝对克制, 0x4e, 1, 0) − Q(D, 118, ...) (≥ 0, 0x426737); m% ≠ 100: dmg = max(pct(dmg, m%), 1)
A ranged family: v = Q(D, 34, 0x45, 1, 0): dmg = cut(dmg, pct(dmg, v))         ; cut(x, r) = x > r ? max(x − r, 1) : 1
0x411072 (加强 98 / 突破 97, below)
v = Q(A, 25 冲锋, 0x5f, 1, 0); n = byte 0x500c48 (cells moved): dmg += pct(dmg, v·n)
v = Q(D, 35, 0x3d, 1, 0): dmg = cut(dmg, pct(dmg, v))
not a counter: dmg += pct(dmg, Q(A, 44 仇恨, 0x4a, 1, 0) · hits_taken[A])       ; 0x478f08, hits 0x508a00
counter: if !Q(A, 72 强化反击, 0x6a, 1, 1): dmg = max(dmg·3/4, 1)
0x412c78(...); not preview: 0x42423d(A, dmg, D, 1) (末日审判 111)
v = Q(D, 86 限制伤害, 0x72, 1, 0): if v and v < dmg: dmg = v                     ; item value ×3/4 at level ≥ 7
preview only: 必杀 (action kind 2) → dmg += pct(dmg, 50) (0x406b0e = the forced critical); cap at D.HP
```
* **加强 / 突破** 0x411072(mode, D, A): 必杀 驱逐 active → 突破 path; else `v = Q(A, 98, 0x35, 0, 0)`: v ≠ 0 →
  (mode ≠ 1) dmg += pct(dmg, v), done (no 突破); else `Q(A, 97, 0x35, 1, 1)` = 0 → done. 突破 path: action kind 1 or
  D dead / 混乱 → +30 %; else the cell behind D (0x42230e) must be valid, empty and passable (0x45936d): mode 0
  (damage calc) → no change; mode 1 (after the first hit landed, 0x405b38) → D is pushed there (0x4594ea); blocked →
  +30 % (constant 0x4110c1). An item with eid 0x35 and value 0 (青釭剑) gives 突破, one with a value gives 加强.
* **末日审判** 0x42423d(A, dmg, D, kind): `if Q(A, 111, 0x48, 3, 0) & kind: dmg += pct(maxHP_D, 10 + R/20)`, R = next
  byte of pseudo-random stream 0 (0x455e25, table 0x508998) → +10..14 %. kind 1 physical (0x43bedf), 2 strategy
  (0x40ca68).
* Stat pair **0x40d2ab**(A, sA, B, sB, flag) used by every formula above (and strategy hit/damage):
  ```
  a = Stat(A, sA, f = Q(B, 106 偷梁换柱, 0x6a, 1, 0)); a = 替换/辅助(A, sA, a); a = 忽视(B, sA, a)
  b = Stat(B, sB, f = Q(A, 84 批亢捣虚, 0x70, 1, 0)); b = 替换/辅助(B, sB, b); b = 忽视(A, sB, b)
  flag 0: a ·= terrain%(A), b ·= terrain%(B)
  ```
  Effective stat **0x414ccb**(U, s, f): w = `Q(U, 57 唯我独尊, 0x61, 1, 1)`; f = 0: w ? max of the 5 stats : stat s;
  f ≠ 0: w ? stat s : (f ≤ 5 ? stat f−1 : min of the 5 stats). Then HP辅助/MP辅助 (0x428430) → 一夫当关 (0x478eab) →
  万夫莫敌 (0x4363b0) → 0x4200a2: 众志成城 (0x43cb00) → 鬼神之勇 (0x45b67c), ≥ 1, then EV 4033 / 4034 scaling.
  Buffs scale every stat getter through 0x42211e (状态强化 116).

### 5.5 On-hit effects (0x405966, per target that took HP or MP damage, only when byte 0x500c44 == 0)

`recipient` = the target, or the attacker when no 必杀 is active and the target has 反弹异常攻击 (0x4220b0 ←
0x405a0f: `Q(T, 18, 0x2a, 1, 1)`).
* 破坏 0x40399f (0x405a24): for i = 0..5: 必杀 8+i or `Q(A, 6+i, (0x34,0x24,0x54,0x2d,0x2c,0x5f)[i], 1, 1)` →
  0x409821(recipient, i, 0): buff i = (buff > 3) ? 3 : 0.
* 随机破坏能力 0x472d6e (0x405a32): v = 必杀 折磨 value or `Q(A, 12, 0x5e, 1, 0)`; min(v, 6) distinct rand(6) stats
  debuffed the same way.
* Ailments 0x4039f6 (0x405a40): for i = 0..3 (麻痹 禁咒 混乱 中毒): 必杀 15+i, or `v = Q(A, 13+i,
  (0x2d,0x26,0x2b,0x2c)[i], 1, i == 2 ? 0 : 1)` and roll 0x43786b(v, 0) → 0x4240d6(recipient, 2<<i): status |= {0x01,
  0x08, 0x10, 0xc0}[i] (麻痹 1 turn, 禁咒 2, 混乱 1, 中毒 3; OR into the counters). The four are rolled independently.
* 随机异常状态 0x42119b (0x405a59): 必杀 鬼门 or `Q(A, 17, 0x1d, 1, 1)`: L = A's weapon level; independently
  roll(5L+15) 禁咒, roll(4L+8) 中毒, roll(3L+3) 麻痹, roll(2L) 混乱.
* Strike did 0 HP and 0 MP to a target (0x422026 ← 0x405a78): `v = Q(A, 114 猛击, 0x4a, 1, 0)` → target loses
  pct(current HP, min(v, 100)) and gets 混乱 (to A instead if the target has 反弹异常); then if the target lives and
  `v = Q(T, 115 盾反, 0x4a, 1, 0)` → A loses pct(A's HP, min(v,100)) and gets 麻痹 (to T if A has 反弹异常).
* After the exchange 0x406b3c (skipped when byte 0x500c44 == 2): 反弹伤害 0x440e06: A loses Σ_i
  pct(damage_i, `Q(T_i, 19, 0x42, 1, 0)`), at most HP − 1; then 吸血 `v = 必杀 嗜血 or Q(A, 20, 0x65, 1, 0)`: HP =
  min(HP + pct(main-target damage of the exchange (0x48e8bd), min(v, 100)), maxHP); then 吸收金钱 `Q(A, 21, 0x5b, 1,
  1)`: defender kind ≥ 2 → gold += that damage (≤ 999999), else gold −= it (≥ 0).
* 反弹异常 cleanup 0x42bc14 (after every action, script ops, phase steps): holders on the map with HP > 0 get all
  ailments cured (0x42402c(…, 100)) and every debuffed level (< 3) reset to 3.

### 5.6 Exchanges, counters, extra attacks

* **先手攻击** 0x410f1c(D, A) (before any attack, ← 0x41058d, 0x417c0c, AI 0x43ac99, player 0x43db6b): D 混乱 → normal.
  策略先手 first: `v = Q(D, 94, 0x78, 1, 0)` and 0x41cecc(A, D, v−1) casts strategy v−1 at A; A then dead / 混乱 →
  attack cancelled (0xff). Then `Q(D, 26, 0x29, 1, 1)` and A inside D's attack range → D strikes first and A answers
  as the counter.
* **Counter** 0x406453 (only action kind 0): target dead / 混乱 → none; counter depth [0x492e04] > 1 → none; depth 1
  and !`Q(original attacker, 37 反击后反击, 0x30, 1, 1)` → none; `Q(striker, 38 无反击攻击, 0x34, 1, 1)` → none; range =
  strategy v−1's range if `v = Q(T, 95 策略反击, 0x79, 1, 0)` and castable, else the attack range (0x41ce0b); in range →
  0x417941: 策略反击 cast succeeds → chain ends, else a physical counter.
* **策略追击** 0x417983 after every strike: `v = Q(A, 93, 0x77, 1, 0)`: cast v−1 at the target (0x4179b4), or if not
  castable one more physical strike (0x4527fe).
* **转移伤害** 0x418205 (← 0x452907, skipped when A has 斩杀攻击): for each target T_i with `v = Q(T_i, 87, 0x73, 1, 0)`
  and damage_i ≥ v: moved = pct(damage_i, v) to the lowest-HP enemy of T_i within T_i's attack range (not A),
  capped by its HP; added to its damage or as a new target.
* **奋战攻击** 0x4363f1 (after a player / AI attack 0x42c14b, 0x43acca): attacker alive, not 混乱; 必杀 血戰 or `Q(A,
  23, 0x36, 1, 0)` (low byte): attack each other enemy in range (list 0x500ea5), at most 2 (unlimited with 血戰),
  stopping if A dies / is confused; then the kill follow-up is skipped.
* **引导攻击** 0x4212f1 (after an attack that killed: 0x417d0a, 0x42c168, AI 0x43ace7): `Q(A, 24, 0x36, 1, 1)`: attack the
  enemies in range in turn, at most 2 more, stopping when one survives. (方天画戟's "Lv7 no kill needed" = eid 0x36
  also feeds 奋战攻击 with a4 0; 0x4200f5 gives 0x36 value + 1 at level 7.)
* **同仇敌忾 / 戮力同心** 0x438ebd(kind, victim, other) via the pointer pair 0x415e2b, called twice by 0x4223a9 after
  an attack (kind 0: victim = defender, other = attacker; kind 1: victim = attacker, other = defender); nothing if the
  victim is dead or EV 4087 ≠ 0. Every unit j ≠ other on the map, same side as other, not dead / 混乱, with `v = Q(j,
  kind ? 113 : 59, kind ? 0x58 : 0x1f, 1, 0)`, unit_j+0x23 < v and the victim inside j's range joins; joiners attack
  the victim one by one (0x41058d: +0x23 += 1, 先手 check, full exchange) until it dies. eid 0x1f's item value is
  sv·(L+1), i.e. practically unlimited.
* **大杀四方** (kill: physical 0x4037f0, strategy 0x420f7c → 0x4290c8): `v = Q(killer, 64, 0x54, 1, 0)` and
  (unit+0x24 & 0x7f) < v → bit 7 set; after the action (0x41b508) bit 7 → cleared, +0x24 += 1, acted flags cleared.
* **先制攻击** 0x428a53(cell, do_it, kind) in the movement step test (0x437d76, 0x43da5a): only for a player-controlled
  mover entering an empty cell; every on-map unit X of another side with `v = Q(X, 82, 0x51, 0, 0)`, X+0x22 < v and
  the cell in X's attack range stops the mover; do_it: X+0x22 += 1, X attacks the mover (0x43db23), the mover is
  marked acted.
* **二次行动** 0x43d4fc (action start): byte 0x508b00[slot] = `Q(U, 56, 0x5a, 1, 1)` ? 0 : 1 (unless 0xff); 0x412d52
  after the action (phase loops 0x44e569 / 0x44ea76 / 0x44ea99): alive, byte 0 and Q → acted flags cleared, byte =
  0xff (one extra action).
* **再次移动** 0x415d93 (← 0x44e548, player loop): alive, not 混乱, `Q(U, 90, 0x5f, 1, 1)` → acted flags cleared,
  message 0x27, 0x43d4fc(U, 0xb, 0, 1) [G: re-opens the move command], acted, byte 0x500c48 = 0.

### 5.7 Strategies

* Strategy hit **0x43b730**(C, T, s): 控制敌军 vs T.pid < 0xd2 → 0; not usable (0x42044d) → 0; T 麻痹 and s ∉ {10, 31,
  53} → 100; `Q(C, 27, 0x1b, 1, 1)` → 100; `Q(T, 99 策略免疫, 0x4f, 1, 1)` and s targets enemies (0x423cb3 == 0) → 0;
  rate = 0x43b53a(精神+士气 pairs); rate −= Q(T, 29, 0x29, 1, 0); 0x408eee (辅助全防御); MgHit table 0x4d1720[s];
  kind 5 by caster family 12 → ×1.5; rate += Q(C, 28, 0x26, 1, 0); `Q(C, 39, 0x20, 1, 0)` → +10; cap 100.
* Strategy damage **0x43c01d**(C, T, s): kinds 0..3 (火水地风, 0x420a9b): dmg += pct(dmg, Q(C, 40, 0x38, 1, 0));
  kinds ≥ 4: dmg += pct(dmg, Q(C, 39, 0x20, 1, 0)); then `v = Q(T, 41, 0x43, 1, 0)`: dmg −= pct(dmg, v) (floor 0);
  0x412c78; 末日审判 kind 2 and the strategy critical 0x40ca68 (rate 0x401dac + 100 if `Q(C, 51, 0x31, 3, 0) & 2`;
  crit → dmg += pct(dmg, rate/4)).
* MP cost **0x417b27**(U, s): base = strategy+0x0e; `v = Q(U, 46 节约MP, 0x39, 1, 0)`: cost = base·(byte)(100 − v)/100.
* Usability: elemental strategies (effect 0..3) skip the target-terrain test if EV 4087 ≠ 0 or `Q(C, 43, 0x38, 1, 1)`
  (0x41d90e). Fire (effect 0) in bad weather (≥ 2) fails unless `Q(U, 42, 0x3a, 1, 1)` (0x46fcf8). 四神 (effect
  0x19, 0x41ff6e): 学会策略-四神 value ≥ 0x80 → usable regardless; else the person needs an item with eid 0x3a
  (0x4079da) and, unless `Q(U, 42, ...)`, the strategy's weather class.
* Strategy lists: `Q(U, 45 策略模仿, 0x3b, 1, 1)` adds the strategies of the 4 adjacent units (any side) except those with
  MgMF bit 0 (0x43e023, 0x465a1f). 学会策略 73..80 (`0x42518f(U, 73+k, 0x6c, 3, 0)`, 0x43e1a8): strategy s is known if
  value_k & MgLearn[s] (0x4d17b0) (or, for k = 0 only, learnt normally).
* After the cast (0x422f2d): `v = Q(caster, 67 策略吸血, 0x56, 1, 0)` → heal pct(total damage, v) (0x42356e caps at
  missing HP; added to a 吸收HP strategy's own gain); 策略反伤: reflect = Σ_i pct(damage_i, `Q(T_i, 66, 0x55, 1, 0)`)
  (0x42bbba); net HP change = heal − reflect, never lethal. Spending MP gives SP (0x410fc3(2·MP)).
* **策略连击** 0x4390a9 (← 0x423201): after the strategy is executed, if byte 0x500c46 == 0 and `Q(caster, 58, 0x3b, 1,
  1)` → executed once more (exp accumulators saved / restored; one repeat).
* **洪荒之力** 0x406e2b (target picker 0x45533d, clicked cell empty): strategies accept the empty cell as the centre only
  if `Q(U, 68, 0x6e, 1, 1)` and the area contains a target (physical/item shapes accept empty cells anyway).
* Ranges: 远距攻击 `Q(U, 0x5a + k, 0x76, 3, 0) & k` (k 1 attack, 2 strategy; 0x41cdee) → range code via table 0x41ceab
  (0x41ce8c; k 1 ← 0x417a38 class range, k 2 ← 0x401dff strategy range). 辅助穿透 `0x42518f(U, 0xa6 + k, 0x57, 3,
  0) & k` → shape via table 0x45d343 (0x45d316, EV 4087 ≠ 0 → none; k 1 ← 0x407878 attack pierce, k 2 ← 0x41a12d
  strategy area, only if MgMF bit 1).

### 5.8 Stat modifiers (all inside 0x414ccb / 0x40d2ab, so they apply to every formula)

* 能力替换 / 能力辅助 0x423ced(U, s, value) via table 0x412c70: for t = 0 (替换, sid 128+i, eid 0x7c) then 1 (辅助, sid
  133+i, eid 0x7b), i = 0..4: c = Q(U, row, eid, 2, 0); skip if c == 0 or bit s of (c & 0x1f) clear; src =
  0x414ccb(U, c >> 5, 0); 替换: s == 4 (士气) → src, else max(value, src); 辅助: once per distinct code → value +
  pct(src, 20).
* 忽视能力 0x416a38(opponent, s, value): first row i (138+i, eid 0x7a, mode 3) whose mask has bit s → value −=
  pct(value, 20).
* HP辅助 / MP辅助 0x428430(U, base, s): for i = 0..4: (Q(U, 157+i, 0x7d, 3, 0) >> s) & 1 → base += current HP / 5
  (signed); (Q(U, 162+i, 0x7e, 3, 0) >> s) & 1 → base += current MP; the first row index that hits ends the loop.
* 一夫当关 0x478eab: v = Q(U, 71, 0x69, 0, 0); companions in the 3×3 (0x41bc4a) = 0 (or only itself) → stat +=
  pct(stat, v), else + pct(stat, v/2).
* 万夫莫敌 0x4363b0: v = Q(U, 85, 0x71, 1, 0); n = enemies in its 3×3 (0x41bc4a kind 4/5); stat += pct(stat, (n+1)·v).
* 众志成城 0x43cb00(U, x): for every other unit V on the map (pid < 0x400) with v = Q(V, 60, 0x1c, 1, 0) and U in V's
  8 cells: n = V's same-side units in V's 8 cells; sum ±= n·v (+ same side as U, − otherwise); x = sum > 0 ? x +
  pct(x, sum) : x − min(pct(x, −sum), x − 1).
* 鬼神之勇 0x45b67c: v = Q(U, 81, 0x6d, 0, 0); lost = (maxHP − HP)·100/maxHP >> 1; stat += pct(stat, min(lost, v)).
* 神魔附体 0x436e02(person, base, k ≤ 4) via 0x436df0 = 0x42518f(61, 0x5c, 0, 0): **uses edx** — no item and v == 0
  → base; v == 0xff without item → 0; else extra = max(grade·level + raw ability k + 功勋 bonus, stat k) − stat k with
  grade = v (or the class grade 0x4250b6 when v = 0) → base + extra.
* 状态强化 0x42211e(x, code 0x22, level, U): up = 2, down = 2; the first of U and its 8 same-side neighbours with v =
  Q(N, 116, 0x4c, 1, 0) ≠ 0: up += v/10, down −= min(v % 10, down); level ≥ 4 → x·(10+up)/10, level ≤ 2 →
  x·(10−down)/10.
* 疾风, 绝对克制, 批亢捣虚, 偷梁换柱, 唯我独尊: 5.4.

### 5.9 Damage absorption and economy

* **MP防御** 0x405fb3 in the hit loop: `Q(D, 50, 0x44, 1, 1)` and current MP > 0: X = MP < dmg ? MP : (dmg < HP ? dmg :
  min(raw damage, MP)); patch 0x41ab00 (`Q(D, 50, 0x44, 1, 1)` again): X = min(X, HP); MP damage += X, HP damage = 0.
* **金钱防御** 0x42128a (← 0x405fcc, physical only): `Q(D, 107, 0x5b, 1, 1)` and dmg > 1: player-controlled (unit+0xe
  == 7) → cost (dmg − 1)·10 gold, not enough gold → no effect; else (or for AI units free) dmg = 1.
* **自动使用** 0x422edf (← 0x416442: after a physical hit on a living defender 0x405b25 and after strategy damage
  0x422a33): v = Q(U, 108, 0x46, 1, 0) = consumable id; player kind and HP + item value > maxHP → 0; EV 4035 == 0 and
  player kind → the item must be in the bag (0x4202c4) and is consumed; else free; used via 0x44f2ac.
* **获得功勋** 0x42ab8e(n, table, person, k): unless raw ability k ≥ 0xff: v = 0x42518f(person, 69, 0x3a, 1, 0);
  (练武场 + EV 4055 rules); table[k] += n + v.
* 每回合获得exp etc.: 5.2.

### 5.10 Movement, terrain, sides, vision

* Terrain/move method **0x43f7b8**(U, terrain) (al = cost, dl = effect %; EV 4087 ≠ 0 → 0xff/100): 龙巡四海/虎啸山林
  (0x435bb1: `Q(U, 169+i, 0x2a, 0, 0)` for i = 0, 1; value & class[terrain] (0x435bf2: 树林 荒地 山地 岩山 山崖 = 2,
  雪原 桥梁 浅滩 沼泽 池塘 小河 大河 = 1) → effect = max(effect, 120); either value ≠ 0 → cost 1 on passable terrain);
  `Q(U, 62, 0x2a, 1, 1)` → effect = max(effect, 110); `Q(U, 63, 0x2a, 1, 1)` and cost ≠ 0xff → 1; `Q(U, 54, 0x5d, 1,
  1)` → cost ≥ 0x80 ? 1 : max(cost − 1, 1).
* ZOC / stop test 0x437d59 (path search): trap/mine (先制攻击) → stop; `穿越移动 || Q(U, 55, 0x29, 1, 1)` → no ZOC; else
  stop next to a hostile unit (side function by EV 4019). Passing occupied hostile cells: only 穿越移动 (0x438794).
  The 穿越移动 wrapper 0x403a6f answers yes without querying while byte 0x500ad3 == 1 (forced moves: 突破 knock-back
  0x4594ea, 0x40eb7e).
* 左天羅右地網: units with another-side neighbour having `Q(N, 96, 0x7a, 1, 1)` → move cost max(cost, 0x80) (0x412b5f,
  unless unit+0xd ≥ 0x80) and attack range code 0 (0x42bb57 → 0x43f8c0, unless code 0xb); AI threat map 0x43a2ac.
* 万里龙城: terrain getter 0x412557 — a unit with `Q(U, 171, 0x2a, 0, 0) & 4` makes its cell read as terrain 0x13 关隘.
  Unit drawing: on 大河 without 龙巡四海 the boat sprite is used (0x435b9e).
* 深入敌后 0x416f38(phase) at every phase start: units with `Q(U, 70, 0x68, 0, 1)` get unit+5 rewritten so that they
  belong to the acting side (player phase: slots ≥ 60 kind += 3; enemy phase: player/friend slots kind 2); others are
  restored.
* 增加视野 0x42b1f1: v = 0x41301e(person, 65, 0, 1, 0); sight shape = v ≥ 12 ? v − 2 : 6 (0x42a7e4 cell visible,
  0x42a2af reveal when byte 0x501bd2 ≥ 2) [G: fog of war].

### 5.11 AI-only

* 众矢之的 (wrappers 0x44f9c9(mask) = `Q(T, 83, 0x6f, 3, 0) & mask`): physical target score low byte = 101 (0x4389f9,
  mask 1); strategy score +101 against another side (0x40c880, mask 2).
* 0x401e1d(AI, target): target worthless (score 1) iff SP < EV 4061, no 忽视暴防, `致命一击 & 1` and the target has
  防御致命攻击.
* 防御远距攻击 in target scoring (0x438a38), 左天羅右地網 threat map, 0x439b00 MP-restore scoring (+12 if the target wears
  eid 0x48).

## 6. Item effects (eid) [C; items from items.json]

Which 特效 each equipment effect id stands for (the fixed query pairs), the value rules of §2.3, and the items carrying
it (treasure weapons/armour by item+0x14, accessories by type). "kind" = display kind 0x4cb6ba (also the ×1.5 switch:
kind < 7), "LV10" = level-10 value 0x4cb5ca (`keep` = 0xfe = use the level-7 rule; `—` = not applied for that eid).
The mod's names describe everything an item effect grants (e.g. 0x41 防御特殊攻击 = 防御致命 + 防御二次 + 集气加倍).
An a4 = 1 pair ignores the value (presence = 100), so level rules only matter for a4 = 0 pairs and the stat bonuses.
The level rule and LV10 apply to treasure weapons/armour only; an accessory always gives its value byte item+0x15.

| eid | name (0x4cb7a0) | kind | LV10 | level rule | 特效 pairs (sid name mode/a4) | other use | items |
|---|---|---|---|---|---|---|---|
| 0x1a | 每回合恢复HP | 4 | 100 | L≥7 ×1.5 | — |  | 66 42武器, 67 43武器, 68 44武器, 96 60护具, 97 61护具 … |
| 0x1b | 每回合恢复MP | 5 | 200 | L≥7 ×1.5 | 1 每回合恢复MP 0/0, 27 策略绝对命中 1/1 |  | 90 鹤氅, 145 孙子兵法 |
| 0x1c | 每回合恢复状态 | 0 | 3 | L≥7 ×1.5 | 2 每回合恢复状态 1/1, 60 众志成城 1/0 |  | 144 太平清領道 |
| 0x1d | 随机异常状态 | 0 | 10 | L≥7 ×1.5 | 3 每回合获得exp 0/0, 17 随机异常状态 1/1 |  | 43 金火罐炮 |
| 0x1f | 同仇破甲 | 1 | 200 | ×(L+1) | 22 破甲攻击 1/0, 59 同仇敌忾 1/0 |  | 33 古锭刀 |
| 0x20 | 輔攻擊妨礙 | 2 | 50 | L≥7 ×1.5 | 39 辅助妨碍策略 1/0 | 攻击 % | 49 七星宝刀, 139 人骨琵琶 |
| 0x21 | 辅助防御力 | 2 | 50 | L≥7 ×1.5 | — | 防御 % | 119 镔铁盔 |
| 0x22 | 辅精神加格檔 | 2 | 50 | L≥7 ×1.5 | 33 辅助全防御 1/0 | 精神 % | 32 倚天剑, 155 白银盾 |
| 0x23 | 辅助爆发力 | 2 | 75 | L≥7 ×1.5 | — | 爆发 % | 37 龙胆涯角枪, 88 飞龙道袍 |
| 0x24 | 辅士破防必中 | 2 | 75 | L≥7 ×1.5 | 7 破坏防御 1/1, 30 攻击绝对命中 1/1 | 士气 % | 133 酒壶 |
| 0x25 | 辅助與恢復HP | 2 | 100 | L≥7 ×1.5 | 0 每回合恢复HP 0/0 | HP % | 69 45武器end, 102 骨箏(棄), 103 軍令狀(棄), 104 史考特(棄), 105 白银盾(棄) … |
| 0x26 | 辅MP與策略命中 | 2 | 100 | L≥7 ×1.5 | 14 禁咒攻击 1/1, 28 辅助策略命中 1/0 | MP % | 138 白玉簫笛 |
| 0x27 | 辅助获得Exp | 2 | 255 | L≥7 ×1.5 | — | exp + | — |
| 0x28 | 辅助移动力 | 1 | 10 | L≥7 ×1.5 | — | 移动 + | 111 大宛马 |
| 0x29 | 先手突擊閃避 | 4 | 50 | L≥7 ×1.5 | 26 先手攻击 1/1, 29 辅助策略防御 1/0, 32 辅助攻击防御 1/0, 55 突击移动 1/1 |  | 94 伏魔袈裟, 114 赤兔马, 125 保你命三千 |
| 0x2a | 化險為夷 | 19 | 4 | — | 18 反弹异常攻击 1/1, 62 辅助地形状态 1/1, 63 恶路移动 1/1, 169 龙巡四海 0/0, 170 虎啸山林 0/0, 171 万里龙城 0/0 |  | 95 天子龍袍, 115 的卢 |
| 0x2b | 混乱攻击 | 4 | 100 | L≥7 ×1.5 | 15 混乱攻击 1/0 |  | 141 胡笳十八拍 |
| 0x2c | 遠程中毒破士 | 4 | 100 | L≥7 ×1.5 | 10 破坏士气 1/1, 16 中毒攻击 1/1 | range byte 0x14 (0x43f90c) | 158 飞刀 |
| 0x2d | 麻痹破爆 | 4 | 100 | L≥7 ×1.5 | 9 破坏爆发 1/1, 13 麻痹攻击 1/1 |  | 39 吕布之弓 |
| 0x30 | 反击后反击 | 0 | 255 | L≥7 ×1.5 | 37 反击后反击 1/1 |  | 30 双股剑, 42 大铁戟 |
| 0x31 | 致命一击 | 16 | 3 | — | 51 致命一击 3/0 |  | 45 大斧, 60 天女聖劍, 130 传国玉玺 |
| 0x32 | 远距攻击 | 0 | — | L≥7 ×2 | — | item-only: attack range code (0x43f8fb, mode 5) | 109 没羽箭, 137 外掛神珠, 157 手戟 |
| 0x33 | 穿透攻击 | 12 | — | L≥7 4→7 | — | item-only: 穿透 shape (0x45d3e8, mode 5) | 35 丈八蛇矛, 40 李广之弓, 56 屠宰砍刀, 110 穿雲箭, 135 新型砲彈 |
| 0x34 | 无反破攻忽防爆 | 0 | keep | L≥7 ×1.5 | 6 破坏攻击 1/1, 38 无反击攻击 1/1, 112 忽视暴防 1/1 |  | 34 青龙偃月刀 |
| 0x35 | 加强攻击 | 2 | 150 | L≥7 ×1.5 | 97 突破攻击 1/1, 98 加强攻击 0/0 |  | 41 雷嘯狂鞭, 132 青釭剑 |
| 0x36 | 引导攻击 | 0 | — | L≥7 +1 | 23 奋战攻击 1/0, 24 引导攻击 1/1 |  | 36 方天画戟 |
| 0x38 | 辅助四系策略 | 4 | 50 | L≥7 ×1.5 | 40 辅助四类策略 1/0, 43 策略无视地形 1/1 |  | 48 白羽扇 |
| 0x39 | 节约MP | 3 | 100 | L≥7 ×1.5 | 46 节约MP 1/0 |  | 50 圣者宝剑, 122 诸葛巾 |
| 0x3a | 可以禁咒 | 0 | keep | L≥7 ×1.5 | 42 策略无视天气 1/1, 69 获得功勋 1/0 | 四神 strategies need it (0x41ff8c) | 129 四神宝玉 |
| 0x3b | 仿策連擊 | 0 | keep | L≥7 ×1.5 | 45 策略模仿 1/1, 58 策略连击 1/1 |  | 146 遁甲天书 |
| 0x3d | 減輕物理傷害 | 3 | 100 | L≥7 ×1.5 | 35 减轻物理损伤 1/0 |  | 85 青龙战袍 |
| 0x41 | 防御特殊攻击 | 0 | keep | L≥7 ×1.5 | 36 集气加倍 1/0, 48 防御致命攻击 1/1, 49 防御二次攻击 1/1 |  | 80 黄金铠 |
| 0x42 | 主动连击 | 0 | — | L≥7 +1 | 19 反弹伤害 1/0, 52 主动连击 1/1, 53 双枪攻击 1/0 |  | 81 连环铠 |
| 0x43 | 减轻策略损伤 | 3 | 100 | L≥7 ×1.5 | 41 减轻策略损伤 1/0 |  | 82 白银铠 |
| 0x44 | MP辅助防御 | 5 | keep | L≥7 ×1.5 | 50 MP防御 1/1, 50 MP防御 0/0 |  | 83 龙鳞铠, 89 金縷衣 |
| 0x45 | 减轻远距损伤 | 3 | 100 | L≥7 ×1.5 | 34 减轻远距损伤 1/0 |  | 86 紫色長裙, 121 护心镜 |
| 0x46 | 自动使用 | 18 | — | L≥7 +1 | 108 自动使用 1/0 |  | 93 紫綬仙衣, 148 豆袋, 149 木牛流馬 |
| 0x48 | 末日审判 | 16 | 3 | — | 111 末日审判 3/0 | AI MP-restore scoring (0x439b00) | 65 芭蕉扇, 136 未來的手槍 |
| 0x4a | 仇恨猛擊盾反 | 4 | 50 | L≥7 ×1.5 | 44 仇恨攻击 1/0, 114 猛击 1/0, 115 盾反 1/0 |  | 47 黑金勾魂槍, 53 鐵蒺藜骨朵 |
| 0x4c | 状态强化 | 2 | 22 | L≥7 ×1.5 | 116 状态强化 1/0, 117 疾风攻击 1/0 |  | 117 烏騅 |
| 0x4e | 防遠克制 | 4 | 50 | L≥7 ×1.5 | 47 防御远距攻击 1/1, 118 绝对克制 1/0 |  | 58 倚天神劍, 79 镜铠 |
| 0x4f | 策略免疫 | 0 | 0 | L≥7 ×1.5 | 99 策略免疫 1/1 |  | — |
| 0x51 | 先制攻击 | 6 | 3 | L≥7 ×1.5 | 82 先制攻击 0/0 |  | 62 疾風神速弓 |
| 0x52 | 生命光环 | 4 | 100 | L≥7 ×1.5 | 101 HP光环 0/0 |  | — |
| 0x53 | 魔力光环 | 4 | 100 | L≥7 ×1.5 | 102 MP光环 0/0 |  | — |
| 0x54 | 大杀四方 | 6 | 3 | L≥7 ×1.5 | 8 破坏精神 1/1, 64 大杀四方 1/0 | range byte 0x0c (0x43f91e) | 44 流星锤 |
| 0x55 | 策略反伤 | 4 | 200 | L≥7 ×1.5 | 66 策略反伤 1/0 |  | — |
| 0x56 | 策略吸血 | 4 | 200 | L≥7 ×1.5 | 67 策略吸血 1/0 |  | — |
| 0x57 | 辅助穿透 | 16 | 3 | — | 167 辅助穿透-攻击 3/0, 168 辅助穿透-策略 3/0 |  | 61 仇與恨之爪, 64 五火神焰扇 |
| 0x58 | 戮力同心 | 6 | 5 | L≥7 ×1.5 | 113 戮力同心 1/0 |  | 52 三尖刀, 54 愛與美之爪 |
| 0x5a | 二次行动 | 0 | 1 | L≥7 ×1.5 | 56 二次行动 1/1 |  | 113 绝影 |
| 0x5b | 金钱防御 | 0 | 1 | L≥7 ×1.5 | 21 吸收金钱 1/1, 107 金钱防御 1/1 |  | 124 保命錢 |
| 0x5c | 神魔附体 | 5 | 10 | L≥7 ×1.5 | 61 神魔附体 0/0 | stat 9 (no 0x452825 effect) | 31 魔之劍 |
| 0x5d | 穿越移动 | 0 | 1 | L≥7 ×1.5 | 54 穿越移动 1/1 |  | 116 獨角獸 |
| 0x5e | 随机破坏能力 | 5 | 6 | L≥7 ×1.5 | 12 随机破坏能力 1/0 |  | 150 千年不死的心 |
| 0x5f | 冲锋攻击 | 4 | 10 | L≥7 ×1.5 | 11 破坏移动 1/1, 25 冲锋攻击 1/0, 90 再次移动 1/1 |  | 112 爪黄飞电 |
| 0x61 | 唯我独尊 | 0 | 1 | L≥7 ×1.5 | 57 唯我独尊 1/1 |  | 46 黑羽扇 |
| 0x65 | 吸血攻击 | 4 | 100 | L≥7 ×1.5 | 20 吸血攻击 1/0 |  | 38 霸王枪 |
| 0x66 | 自动提升 | 10 | 63 | — | 144 自动提升 3/0, 145 自动提升 3/0, 146 自动提升 3/0, 147 自动提升 3/0, 148 自动提升 3/0, 149 自动提升 3/0, 150 自动提升 3/0 |  | 156 鬼神盾 |
| 0x68 | 深入敌后 | 0 | 0 | L≥7 ×1.5 | 70 深入敌后 0/1 |  | 126 隱形頭冠, 127 ？？？ |
| 0x69 | 一夫当关 | 4 | 25 | L≥7 ×1.5 | 71 一夫当关 0/0 |  | 87 凤凰羽衣 |
| 0x6a | 偷梁换柱 | 8 | 6 | — | 72 强化反击 1/1, 106 偷梁换柱 1/0 |  | — |
| 0x6c | 学会策略 | 17 | 255 | — | 73 学会策略-四系 3/0, 74 学会策略-降能力 3/0, 75 学会策略-妨碍 3/0, 76 学会策略-补给 3/0, 77 学会策略-升能力 3/0, 78 学会策略-气候 3/0, 79 学会策略-绝 3/0, 80 学会策略-四神 3/0 |  | 140 祭祀顱骨 |
| 0x6d | 鬼神之勇 | 4 | 30 | L≥7 ×1.5 | 81 鬼神之勇 0/0 |  | 147 麻花寶典 |
| 0x6e | 洪荒之力 | 0 | 3 | L≥7 ×1.5 | 68 洪荒之力 1/1 |  | — |
| 0x6f | 众矢之的 | 16 | 3 | — | 83 众矢之的 3/0 |  | 123 女用紅鞋 |
| 0x70 | 批亢捣虚 | 8 | 6 | — | 84 批亢捣虚 1/0 |  | 134 呂氏老方 |
| 0x71 | 万夫莫敌 | 4 | 4 | L≥7 ×1.5 | 85 万夫莫敌 1/0 |  | — |
| 0x72 | 限制伤害 | 5 | 1 | L≥7 ×3/4 | 86 限制伤害 1/0 |  | 120 西凉战盔 |
| 0x73 | 裝備Exp與轉傷 | 4 | 50 | L≥7 ×1.5 | 4 每回合武器exp 0/0, 5 每回合护具exp 0/0, 87 转移伤害 1/0 |  | 142 孟德新书 |
| 0x74 | 特效模仿 | 0 | 0 | L≥7 ×1.5 | 88 特效模仿 1/1 |  | 59 冰晶石 |
| 0x75 | 特效屏蔽 | 0 | 0 | L≥7 ×1.5 | 89 特效屏蔽 1/1 |  | — |
| 0x76 | 远距攻击 | 16 | 3 | — | 91 远距攻击-攻击 3/0, 92 远距攻击-策略 3/0 |  | 84 外星科技 |
| 0x77 | 策略追击 | 7 | 29 | — | 93 策略追击 1/0 |  | 55 思召, 57 千年雷殺弩 |
| 0x78 | 策略先手 | 7 | 29 | — | 94 策略先手 1/0 |  | 63 蕩魔杵, 154 史考特 |
| 0x79 | 策略反击 | 7 | 29 | — | 95 策略反击 1/0 |  | 153 軍令狀 |
| 0x7a | 忽视能力 | 11 | 31 | — | 96 左天羅右地網 1/1, 138 忽视能力 3/0, 139 忽视能力 3/0, 140 忽视能力 3/0, 141 忽视能力 3/0, 142 忽视能力 3/0, 143 忽视能力 3/0 |  | 51 威盛長錘 |
| 0x7b | 能力辅助 | 9 | 31 | — | 100 健康光环 1/1, 133 能力辅助 2/0, 134 能力辅助 2/0, 135 能力辅助 2/0, 136 能力辅助 2/0, 137 能力辅助 2/0 |  | 92 鳳仙寶衣, 152 骨箏 |
| 0x7c | 能力替换 | 9 | 31 | — | 128 能力替换 2/0, 129 能力替换 2/0, 130 能力替换 2/0, 131 能力替换 2/0, 132 能力替换 2/0 |  | 91 漆黑道服 |
| 0x7d | HP辅助 | 11 | 31 | — | 110 斩杀攻击 1/0, 157 HP辅助 3/0, 158 HP辅助 3/0, 159 HP辅助 3/0, 160 HP辅助 3/0, 161 HP辅助 3/0 |  | 131 行军眼罩 |
| 0x7e | MP辅助 | 11 | 31 | — | 31 辅助攻击命中 1/0, 162 MP辅助 3/0, 163 MP辅助 3/0, 164 MP辅助 3/0, 165 MP辅助 3/0, 166 MP辅助 3/0 |  | 128 激戰手套 |
| 0x7f | Buff光环 | 10 | 63 | — | 151 Buff光环 3/0, 152 Buff光环 3/0, 153 Buff光环 3/0, 154 Buff光环 3/0, 155 Buff光环 3/0, 156 Buff光环 3/0 |  | — |

Eids carried by items but used by no 特效 pair: 0x1a (placeholder items), 0x21 / 0x23 / 0x28 (stat bonus only),
0x32 / 0x33 (range / 穿透, item-only). Item-only checks bypass 特效屏蔽 and 特效模仿.

## 7. Engine options and config EVs that change skill behaviour [C]

Config EV n = u32 at 0x502000 + 4n (defaults in the exe; the scripts set many of them).

| EV | Default | Effect on the skill system | Reader |
|---|---|---|---|
| 4058 兵种特性向下继承 | 0 | 0: a class entry also matches higher classes of the same family; ≠ 0: exact class only | 0x42f9a4 |
| 4062 | 1024 | persons with id ≥ EV are neither blocked by 特效屏蔽 nor able to use 特效模仿 | 0x4101f5 |
| 4059 禁止必杀 | 0 | ≠ 0: no 必杀 (gate 0x4225fb), no SP from damage, no learn message, SP hidden in the UI | 0x40755f, 0x410fd1, 0x422602, 0x4404aa, 0x45003c, 0x465904 |
| 4061 必杀所需SP | 100 | AI 武将技 threshold and AI scoring (the player pays the record's cost) | 0x401e2b, 0x416ebc, 0x422635 |
| 4030 | 200 | non-forced SP gains only for pid ≤ EV (scripts set 1024) | 0x42393d |
| 4095 | 0 | ≠ 0: revived units keep their SP | 0x4277e8 |
| 4087 练武场 | 0 | ≠ 0 (training duels): no SP gain, no 文官必杀, no 同仇/戮力 assists, no 辅助穿透, terrain method returns cost 0xff / effect 100, elemental strategies ignore terrain, weather rule relaxed, … (69 readers) | 0x410fc8 etc. |
| 4035 | 0 | ≠ 0: 自动使用 does not consume the item from the bag | 0x416457 |
| 4023 负面状态恢复模式 | 0 | roll mode of the status recovery (0 chance, 1 pseudo-random, 2 always) | 0x424079 |
| 4077 伪随机 | 2 | < 2: 0x43786b rolls use the pseudo-random tables 0x508998 (on-hit ailments, expiry of 附加技能, …) | 0x437871 |
| 4018 / 4017 | 0 / 0 | 4018 = 1: hits / doubles / crits use per-unit accumulators 0x4930c8 (集气 hit mode) seeded by 4017 — not SP | 0x4287a8, 0x43b4e1 |
| 4019 深入敌后 超级卡位 | 0 | which side function the ZOC test uses (home side vs 深入敌后 side) | 0x42e2bf |
| 4053 | 0 | third-party side code (affects "other side" tests of 屏蔽, auras, 众志成城 …) | 0x40671d |
| 4033 / 4034 | 0 | enemy / player stat multiplier (%), applied after the 特效 stat chain (0x4200a2) | 0x4200c5 / 0x4200bd |
| 4066 | 0 | facing bonus to hit (0x408db1) before 辅助全防御 | 0x408db9 |
| 4055 | 0 | 练武场 功勋 rule in 获得功勋 | 0x42abca |

The option strings at 0x4beec0 + 16·i ("5-显示生命条", "6-显示Buff状态" … "p-极速移动", state bytes 0x500fa4 + i) are display / convenience toggles (life bars, buff display, auto-save, skip battle animation,
fast moves, …; drawn by 0x44d87c). None of the code paths in this document reads 0x500fa4.. (no direct reference in
the effect code; the options are read through computed addresses, so this is [G] for completeness).

The shipped Ekd5.exe already contains every patch listed in `辅助小软件v0.22/6.6修正版bug修改記錄.txt` and the
"修改記錄整理" constants (checked byte for byte: 0x40889d, 0x44e3df, 0x422ee6, 0x4283fa, 0x43db9a, 0x412c8b, 0x44e552,
0x41ab08, 0x4cb5ca …), so the behaviour above is the patched one.

## 8. Notes for the port

* Keep the four tables as memory (0x511000, 0x512000, 0x512dc0 stream, 0x50e000) inside the emulated 0x501000 block,
  initialised from `exe_image.bin`; ops 0x72 sub 5/6/10/35 write them byte-exactly as in §2. `skills.json` holds names,
  descriptions, defaults and every query pair for reference; the logic should call one function shaped like 0x4101d9
  (unit, sid, eid, mode, a4) → (value, item part).
* The query depends on the 4 neighbours (屏蔽 / 模仿) and on the current equipment, class and level, so results cannot
  be cached across moves.
* Only the bytes matter: values are u8 per source, mode-0 sums are u32, mode-1 max is unsigned, item values clamp at
  255, `pct` truncates.
* Quirks to keep: 附加技能 last turn needs a recovery roll; persons without a unit count down twice per turn; op 0x0a
  removes temporary skills and SP; 龙巡四海/虎啸山林/万里龙城 sum (mode 0) bit masks; eid 0x1d doubles as the per-turn exp
  item effect; Imsg descriptions of sids 62, 63, 65, 68, 103–106 do not match what the code does (follow the code);
  item effect 0x1f (同仇破甲) grows ×(L+1); MP光环 ignores values > 100; 增加视野 values < 12 do nothing.

## 9. Open questions

* Which strategy MgID produces strategy result code 28 (the 附加技能 grant 0x42fd09); in this mod only blank
  strategies carry such data.
* Attack range codes 0 and 0xb (左天羅右地網 / 禁咒 units), the weather class of each 四神 strategy (0x46fe10), byte
  0x501bd2 (fog of war?), byte 0x500c44 (1/2 = item / explosive attack paths? skips on-hit effects) and 0x500ad7.
* 金钱防御 and MP防御 were found only in the physical hit loop; the strategy damage path was not searched for them.
* 0x4024aa's correction term in 众志成城 and the kinds counted by 0x428df1 (万夫莫敌 / 一夫当关) are only partly traced.
* 0x405d0a (double-attack ratio): which argument is the attacker's 爆发 (formula confirmed, order not).
* The 文官必杀 area shape 0x0c and the side filter of 巫蠱 (BATTLE / strategy tracks).
