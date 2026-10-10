# 新改曹操傳 6.6 (Ekd5.exe) — memory map for the port

What lives where in the original engine's memory, which the port emulates byte for byte (`game/src/core/mem.gd`).
All addresses are VAs in `orig/Ekd5.exe` (image base 0x400000). Facts were checked in the disassembly
(`tools/disx.py`) and Ghidra output; each carries the function that reads or writes it. **[C]** = confirmed
from code, **[S]** = confirmed from save files / data only, **[G]** = guess, not verified.

The 6.6 engine is hand-written assembly patched over CCZ: many functions take their object in `ecx` *and* keep
`this` in `[ebp-4]` via `push ecx`, return values in `ecx` or `edx`, and getters take an index in `cl`/`ecx`.
Ghidra's C for those is often wrong; always read the disassembly for anything that matters.

## 1. Image and sections

`tools/dump_image.py` → `game/assets/data/exe_image.bin` = 0x400000 .. 0x542800 (0x142800 bytes): PE header page,
then each section at its VA, raw data copied, the rest of the virtual size zero.

| Section | VA | vsize | raw | Contents |
|---|---|---|---|---|
| .code | 0x401000 | 0x85000 | 0x84e00 | CCZ code, ~83% rewritten in place (all live code is here; .text3 holds a few routines near 0x4cf000–0x4d1400) |
| .text1 | 0x486000 | 0x5000 | 0x4800 | imports, constant data |
| .text2 | 0x48b000 | 0x33000 | 0x6800 | CCZ .data; 0x491800 .. 0x4be000 is zero-filled BSS (persons/units/GS/flags…) |
| .api | 0x4be000 | 0x10000 | 0xf600 | 6.6 imports, option strings (0x4beed0), item-effect names 0x4cb7a0, 特效 names 0x4cc600 |
| .text3 | 0x4ce000 | 0x64000 | 0x64000 | 6.6 data: heap pointers, strategy/family extension tables, 0x501000 save block (EV, PT, sprite tables, …) |
| .rsrc | 0x532000 | 0x10764 | 0x10800 | resources |

The person and shop tables are allocated at start-up (0x483bd5, CRT heap init): `[0x4cea00]` = persons
(1024 × 0x48 = 0x12000 bytes), `[0x4cea04]` = `[0x4cea00]` + 0x12000 = shops (128 × 0x28), `[0x4cea08]` =
&person[0x3ff] (used as a scratch record by 0x41de7e / 0x418f1f). In the file all three are 0xffffffff.
The port must write them at reset (it keeps the records in its heap).

## 2. Record getters

| Table | Getter (convention) | Address | Count × size | Filled by |
|---|---|---|---|---|
| persons | 0x4061e4 (push id; returns ecx) | `[0x4cea00]` + id·0x48 | 1024 × 0x48 | 0x41b666 → 0x408c0c (Data.e5 e0) |
| battle units | 0x4061f9 (cl = slot; returns ecx) | 0x4a7b20 + slot·0x30 | 250 × 0x30 | 0x44274c (UnitInit) |
| items | 0x4837c2 (ecx = id; returns ecx) | 0x49f820 + id·0x19 | 256 used (512 fixed up) × 0x19 | 0x4010b0 (Data.e5 e1 + Star.e5) |
| classes | 0x41b782 (ecx = id) | 0x4a2a27 + id·0x23 | 80 × 0x23 | 0x41b73e (e3, raw) |
| class families | 0x41b7d2 (ecx = id) | 0x4a3517 + id·0x3c | 40 × 0x3c | 0x41b790 (e4, raw) |
| strategies | 0x484002 (ecx = id) | 0x4a3e77 + id·0x61 | 144 × 0x61 | 0x41b830 → 0x40d737 (e5) |
| skill names | — | 0x4a7510 + i·16 | 97 × 16 | 0x41b830 (the 0x610 bytes after the strategies in e5) |
| shops | 0x41b7e0 (ecx = id) | `[0x4cea04]` + id·0x28 | 128 × 0x28 | 0x41b7ee → 0x40d793 (e2) |
| deployment entries | 0x418dd0(i) | 0x494fd4 + i·0x10 | 250 × 0x10 | script ops (Reader 0x492f90 + 0x2044) |
| RPG actors | — | 0x49cf68 + i·0x40 | 128 × 0x40 | story actor ops |
| person ← unit | 0x40658f (ecx = unit) | person of unit.+0 | | |
| family of person / unit | 0x40bf0c (ecx = person) / 0x43b4a7 (ecx = unit) | class ≤ 59 → class/3, 60..79 → class−40, else 40 | | |

All Data.e5 tables are read **at boot** (0x404caf → 0x41b639, its only caller; the title loop 0x404ce1 that a
finished game returns to comes after it), so no full reload was found for "new game". A single person is reset from Data.e5 by re-reading entry 0 into the temp buffer 0x48b100 and
calling 0x41b617 → 0x408c0c(id, rec, flag 1) (op handler 0x46206c; also 0x4149cf, 0x4266af, 0x43bb2a).

## 3. Person record (0x48 bytes at `[0x4cea00]` + id·0x48)

Expanded from the 32-byte Data.e5 record by **0x408c0c(id, src, flag)** (ecx = record): memset 0x48 to 0, then the
field copies below. `flag` 0 (boot) stores the face into the face table, 1 (reset / load) takes the face from it.
A save stores 0x30 bytes per person (0x408f2e / 0x408f67): +0x02..+0x07, +0x11..+0x36, +0x44..+0x47.

| Off | Type | From file | Meaning | Evidence |
|---|---|---|---|---|
| +0x00 | u32 | id \| 0x1000 | person id (0x482715 returns `& 0xfff`) | 0x408c2c [C] |
| +0x02 | u8 | 0 | 功勋 ability mask: for persons < 0x66, bit k clear → that ability's 功勋 (u16 0x508000[id·5+k]) is moved to the shared pool EV 4048 when 功勋分配模式 (EV 4047) is on | 0x408fa0 [C] |
| +0x03 | u8 | 0 | set by a script op for a list of persons (0x408cfa); meaning unknown | [C] write only |
| +0x04 | u16 (u32 written) | file 0x0d u16 | face (portrait) id; mirrored in the face table 0x50f000[id] (0x423e30); op SetStat(0xf) writes both (0x407027) | [C] |
| +0x06 | u16 | 0 | saved; no direct reader found | [S] |
| +0x08 | char[8] | file 0x00..0x0b | name, first 8 bytes. The parser copies 12 bytes to +0x08..+0x13; 0x40a72c then moves bytes 8.. (stopping at NUL or a digit '0'..'9') to +0x3f.. | 0x408c39, 0x40a72c [C] |
| +0x10 | u8 | (name byte 8) | left over from the name copy | [C] |
| +0x11 | u16 ×5 | file 0x12..0x16 | 武力 统率 智力 敏捷 运气 — the battle stats (攻击 防御 精神 爆发 士气), ≤ 9999 (AddStat 0x406eca / SetStat 0x407027, index 0..4) | [C] |
| +0x1b | u32 | file 0x17 u16, ≤ 500 at load | base max HP (stat 5), ≤ 9999 (AddStat) / 0xffff (SetStat); readers use the low 16 bits (0x407263) | [C] |
| +0x1f | u16 | file 0x19 u8, ≤ 250 at load | base max MP (stat 6), ≤ 9999 (0x40728f) | [C] |
| +0x21 | u8 ×5 | file 0x12..0x16 | raw abilities (stats 0xa..0xe), ≤ 100; growth grade 0x4072f2: ≥ 99 → 10, ≥ 90 → 8, ≥ 70 → 6, ≥ 50 → 4, else 2 | 0x4070e1, 0x4072f2 [C] |
| +0x26 | u8 | file 0x10 | voice type: generic critical line = Imsg 700 + 0x15 + v·3 + rand(3) (persons in the 21-entry table 0x48b230 have their own line) | 0x40c099 [C] |
| +0x27 | u8 | 0 | battles fought: UnitInit adds 1 (≤ 255) for party members, sets 0 for others (getter 0x44000c, setter 0x443160) | 0x4427e6 [C] |
| +0x28 | u8 | 0 | zeroed by UnitInit for non-members (0x42d253); not reachable through op 0x78 | [C] |
| +0x29 | u8 | 0 | retreats (撤退场数, op 0x78 field 15); zeroed by UnitInit for non-members (getter 0x440015, setter 0x443100) | [C] |
| +0x2a | u8 | file 0x11 | army: 0 = in the player's army; 0xff = not. Join/leave 0x4095b9 (also updates the history list 0x501800) | 0x40c603, 0x411da5 [C] |
| +0x2b | u8 | file 0x1a | class (getter 0x406610, setter 0x40e01f) | [C] |
| +0x2c | u8 | file 0x1b (0 → 1) | level (getter 0x4065d0); level ≥ 100 sets exp 0xff (0x4073f3, 0x4088cd) | [C] |
| +0x2d | u8 | file 0x1c | exp 0..99 (0xff at max level) | [C] |
| +0x2e,+0x2f,+0x30 | u8 ×3 | file 0x1d, 0, 0 | weapon id (0xff none), weapon level, weapon exp. Equipment slot k = +0x2e+3k (0x4065f0); level +0x2f+3k (0x4032df) | [C] |
| +0x31,+0x32,+0x33 | u8 ×3 | file 0x1e, 0, 0 | armour id, level, exp | [C] |
| +0x34 | u8 | file 0x1f | accessory id (no level) | [C] |
| +0x35 | u16 | 0 | kill count (incremented by 0x426ba0 outside 練武場; EV 4046 kill bonus 0x405b86) | [C] |
| +0x37 | char[8] | — | display-name buffer: GetName 0x407775 copies +0x08.. (stops at NUL/digit) to +0x37 and returns +0x37; long names run on into +0x3f | [C] |
| +0x3f | char[≤5] | name bytes 8.. | tail of names longer than 8 bytes (0x40a72c), NUL-terminated | [C] |
| +0x44 | u32 | 0 | saved; no direct reader found (0 in every save checked) | [S] |

Notes:
* Equipment levels are 1-based in use; records loaded from Data.e5 keep level 0 for their starting equipment (the
  value-at-level loop 0x40b3d7 would run 255 times for level 0) — the engine assigns levels when equipment is
  (re)equipped (0x407df1 / 0x41ca49) or by EV 4039 auto-upgrade (0x40c990). Saves show `id, 1, exp` for equipped
  items and `ff 00 00` for empty slots.
* Display name: the engine never prints +0x08 directly; it uses 0x407775. Renamed persons (op with EV 4054) are
  kept in the table 0x510d00 (48 × {u16 id (0x400 = free), char[14] name}, count byte 0x5083fe) and re-applied
  from there (0x4081f2).
* Per-person data outside the record: face table 0x50f000, S/R sprite tables 0x501000 / 0x50f800, SP 0x501c00,
  功勋 tables 0x508000 / 0x508400 (persons < 0x66), growth modifiers 0x507ec0 (0x436e3d).

## 4. Battle unit record (0x30 bytes at 0x4a7b20 + slot·0x30, 250 slots)

UnitInit **0x44274c(person, flags, x, y, keep)** (ecx = unit). A save stores 42 bytes per unit (0x44f24c /
0x405d5b): +0x00 u16, +0x10 u16, +0x14 u16, +0x04..+0x0f, +0x18..+0x2f. Script operands ≥ 0x404 name a unit slot
(v − 0x404) instead of a person (0x41b882, 0x4103cd); with EV 4031 = 1 small values are slots too.

| Off | Type | Meaning | Evidence |
|---|---|---|---|
| +0x00 | u32 | person id (0xffff = empty; saved as u16) | 0x442753, 0x41b8a8 [C] |
| +0x04 | u8 | own slot index | 0x449685 [C] |
| +0x05 | u8 | kind / colour: UnitInit sets 0..3 from the deploy flags (0x43ff28 ← 0x425d9a: bit0+bit1 → 3, bit0 → 2, bit1 → 1, else 0); 5 / 6 also occur (0x42e2f0) | [C] |
| +0x06 / +0x07 | u8 | x, y (the 6.x editor labels op 0x78 fields 29/30 that map here 纵坐标 / 横坐标) | 0x442ba7, 0x4043b6 [C] |
| +0x08 | u8 | AI target unit (0xff = point) [G, as wg2025] | |
| +0x09 / +0x0a | u8 | AI target point x, y (op 0x42c846 writes word +0x09) | [C] |
| +0x0b | u8 | action order (0x44f980 / 0x425ac7) | [C] |
| +0x0c | u8 | state: 1 created/off-map, 2 on map, 3/4 defeated/retreated (0x418c90, setter 0x443120) | [C] |
| +0x0d | u8 | flags (set 0x442718, clear 0x406690); bit 1 tested by 0x4078ed | [C] |
| +0x0e | u8 | AI code; 7 = player controlled (0x442669 sets ≤ 7; tests `== 7` at 0x4024c6, 0x409062) | [C] |
| +0x0f | u8 | facing 0..3 (0x406670 / 0x44270c) | [C] |
| +0x10 | u32 | HP (UnitInit = max HP 0x407263; saved as u16) | 0x442793 [C] |
| +0x14 | u32 | MP (= max MP 0x40728f; saved as u16) | 0x4427a1 [C] |
| +0x18..+0x1d | u8 ×6 | buff levels atk, def, spi, agi, mor, move: 0..2 debuff, 3 normal, 4..6 buff (UnitInit = 3) | 0x4427a4, 6.5異常狀態計算.txt [C] |
| +0x1e | u8 | status: four 2-bit counters — 麻痹 bits 0-1, 禁咒 bits 2-3, 混乱 bits 4-5, 中毒 bits 6-7 (value = turns) | 0x4427b1, 6.5異常狀態計算.txt [C] |
| +0x1f | u8 | set by 0x418af9 [unknown] | |
| +0x20 / +0x21 | u8 | second AI point x, y (op 0x42c846; 0x425d3f writes word +0x21) [G] | [C] write |
| +0x23 | u8 | attacks this action (0x4105b8 increments; bit 2 tested by 0x482f82) [G] | [C] |
| +0x24 | u8 | flags; bit 7 tested and cleared by 0x41b510 | [C] |
| +0x25..+0x2f | | saved, not identified | |

Unit slots (0x42e2f0): **0..19 player, 20..59 friends, 60..249 enemies**; for slots ≥ 60 the side also depends on
+0x05 (2 enemy; 3 / 6 → third party when EV 4053; 5 / 6 with the per-slot byte 0x501ad8[slot] set stay on their
side) and the result goes through the table 0x40672d. The per-unit byte table 0x501a84[slot] is stat 0xf of AddStat (0x406eca → 0x477adc maps a
person to its slot). With EV 4018 = 1 (集气 hit mode) the byte at 0x4930c8 + slot·4 (inside FLAGS) is compared in
the hit test 0x428925.

## 4a. The scripts' field interface (op 0x78 整型变量赋值)

Most script memory access goes through op 0x78 `data_transfer ev dir person field` (handler 0x416dcd →
**0x4202d8**(field, person, dir, ev)): dir 0 copies the field into EV `ev`, otherwise EV `ev` into the field. The field number (editor list `CczString.ini`, tag 0x55) is mapped
by **0x415418** to (kind, offset, size); kind 0 = person record, 1 = S-sprite table, 2 = the unit holding the person
(0x43e4d6 searches the 250 slots; no unit → nothing happens). Sizes: 0 byte, 1 u16, 2 u32. Writes have side effects:
level (+0x2c) raised → LevelUp 0x4073f3 for the difference; stats +0x11..+0x1f → 功勋 bookkeeping 0x408b52
(table 0x508400); face → face table 0x50f000 (0x423e30); S sprite → unit sprite refresh 0x40523a.

| Field | Editor label | Target | Size |
|---|---|---|---|
| 0 | R形象 | R-sprite table 0x50f800[id] | u16 |
| 1 | 头像 | person +0x04 | u16 |
| 2..6 | 攻击 防御 精神 爆发 士气 | person +0x11 + 2(i−2) | u16 |
| 7 / 8 | HP / MP | person +0x1b / +0x1f | u16 |
| 9..13 | 武力 统率 智力 敏捷 运气 | person +0x21 + (i−9) | u8 |
| 14 | 出战场数 | person +0x27 | u8 |
| 15..26 | 撤退场数, 我军标识, 兵种, 等级, 经验, 武器, 武器等级, 武器经验, 防具, 防具等级, 防具经验, 辅助 | person +0x1a + i (+0x29 .. +0x34) | u8 |
| 27 | 战场特殊形象 | S-sprite table 0x501000[id] | u16 |
| 28 | 战场编号 | unit +0x04 | u8 |
| 29 / 30 | 战场纵坐标 / 横坐标 | unit +0x06 / +0x07 | u8 |
| 31 | (editor: 战场行动标识) | **person +0x35** (kill count) | u16 |
| 32 | (editor: 战场人物朝向) | **unit +0x0e** | u8 |
| 33 / 34 | HpCur / MpCur | unit +0x10 / +0x14 | u32 |
| 35..41 | 攻击 … 移动状态, 健康状态 | unit +0x18 .. +0x1e | u8 |

Fields 31 and 32 do not do what the editor's labels say; the table above is what 0x415418 does.

## 5. Items, classes, families, strategies, shops in memory

Record layouts and field meanings: docs/rules.md §1. In memory:
* **Item** (0x19): file layout, except the fix-up 0x4010b0 (run over 0x200 records): +0x0e = 0 (names ≤ 14 bytes),
  +0x12 ← file 0x13 (price), +0x13 ← file 0x14, +0x14 ← file 0x12 (special / kind); icon picture = u16 +0x0f (0x4063bf). Category 0x40b444,
  effect id 0x40b4bd, treasure 0x40b4e1, value at level 0x40b3d7, max level 0x4201c1 (treasure 10, else 5).
* **Class** (0x23), **family** (0x3c): raw copies of the file records.
* **Strategy** (0x61): +0x00 name[10], +0x0a = 0, +0x0b target (file 0x0c), +0x0c range (0x0d), +0x0d area (0x0e),
  +0x0e MP (0x0f), +0x0f effect (file 0x0b), +0x10 animation, +0x11..+0x60 learn level per class.
* **Shop** (0x28): +0 u32, +4 u32 (file u16 0/2), +8 16 equipment ids, +0x18 16 item ids.
* Per-strategy extension tables 0x4d14e0 + 0x90·k (k = 0..9) and per-family tables 0x4d1a80 (matchup) /
  0x4d20c0 + 40·k: docs/rules.md §1.5 / §1.4.

## 6. Game-state block GS (0x4b0770, 700 bytes saved)

Init 0x42baf8 (new game / title). Copied whole into saves (0x40c482 / 0x40c49a, 700 bytes).

| Off | Address | Type | Meaning | Evidence |
|---|---|---|---|---|
| +0x00 | 0x4b0770 | u8 ×4 | init 1f 01 01 00, then 0x4241a3 replaces the 4 bytes with settings bytes 4..7 of `SV\SV.E5S` (reader 0x41a280) unless EV 4024 (私档) ≠ 0 | 0x42baf8 [C] |
| +0x02 | 0x4b0772 | u16 | script op 08 result (wg2025 semantics) [G] | |
| +0x04 | 0x4b0774 | u8 | init 0xff (u32 write of 0xff clears +5..+7) | 0x42baf8 [C] |
| +0x05 | 0x4b0775 | u8 | battle map / scene shown in the save list when in battle | 0x4053cc [C] |
| +0x06 | 0x4b0776 | u16 | scenario counter; save list shows min(GS+6 / 2, 127) (0x415e13) | [C] |
| +0x0c | 0x4b077c | u32 | gold, ≤ 999,999 (setter 0x40e1a4, add 0x40da71, sub 0x40d7ee; op 0x3a kind 0) | [C] |
| +0x10 | 0x4b0780 | u8 | message speed (read by 0x4034d2) | [C] |
| +0x11 | 0x4b0781 | u8 | story bits (setter 0x418ca6) | [C] |
| +0x12 | 0x4b0782 | u8 | 忠奸 (loyalty) 0..100 (op 0x3a kind 2 → setter 0x418cb3) | [C] |
| +0x13 | 0x4b0783 | 200 × {u8 id, u8 level, u8 exp} | the bag; empty slot = ff ff ff (0x41606a); search loop 0x40c603 | [C] |
| +0x26b | 0x4b09db | u8 | sortie maximum (op 0x415b4f; new game 1) | [C] |
| +0x26c | 0x4b09dc | u16[20] | forced sortie persons, written 5 at a time at ring offset `[0x4b0a2c]` (0/0xffff = none) | 0x415c0d, 0x418597 [C] |
| +0x294 | 0x4b0a04 | u16[20] | persons who may not sortie, ring offset `[0x4b0a30]`; if any entry is 0 the protagonist is not put first | 0x418597 [C] |
| (after GS) | 0x4b0a2c / 0x4b0a30 | u32 | ring offsets (0, 5, 10, 15) of the two lists; not saved; reset with the lists by 0x41c96d | [C] |

0x41c96d (sortie defaults) writes 0xffffffff over 0x4b09dc .. 0x4b0a2c and 0 to the two ring offsets.

## 7. Other state

| Address | Type | Meaning | Evidence |
|---|---|---|---|
| 0x492f90 | object | script Reader / VM ("R"); saved fields +4 (s16→u32), +8, +0x10 (u16), +0x14, +0x24 (0x40ffea / 0x41001f) | [C] |
| 0x492fc8 | u32[2048] | FLAGS (Reader+0x38); saved whole | 0x405505 [C] |
| 0x493af0 | u8[352] | zeroed by new game (0x42baf8) — inside the FLAGS array (flags 714..801) | [C] |
| 0x494fc8 | u8[8] | saved (Reader+0x2038) | [C] |
| 0x494fd4 | 250 × 16 | deployment entries (Reader+0x2044; 0x418dd0): +0 u16 person, +4/+5 x/y, +8 u32 flags | [C] |
| 0x496c94 | u8[8] | saved (Reader+0x3d04; wg2025: boss config bit0 / id +0x3d06) | [C] |
| 0x496c9e | u16 | saved (Reader+0x3d0e) | [C] |
| 0x496ca0 | char[0x181] | saved (Reader+0x3d10); battle title, copied into the battle part of saves | 0x407a75 [C] |
| 0x48b350 | u16[] | sortie list (person ids, 0xffff-terminated), built by 0x418597 (**u16**, wg2025 used u32) | [C] |
| 0x48b920 | 9 B per action | RPG actor action table (0x41de38) | [C] |
| 0x48bdb0 | u32[34] | terrain-name pointers | [C] |
| 0x4927f0 | object | combat object: +0 attacker slot, +1 defender slot (0x4064f1, method thiscall); +0x428, +0x608 internal | [C] |
| 0x496f60 | u32 | pointer to the data-load buffer (= buffer object 0x48b0e0) | 0x404c99 [C] |
| 0x49cf68 | 128 × 0x40 | RPG actors; saved 0x24 B each (0x427bcb: +0x00..+0x0f, +0x16..+0x1d, u16 +0x28, +0x2c..+0x31, u32 +0x38); +0x3a u16 = person \| 0x1000 | [C] |
| 0x49f1cc | char[22] | scenario title (cleared at boot, saved) | 0x404ca2 [C] |
| 0x4a7b20 | 250 × 0x30 | battle units (§4) | [C] |
| 0x4ac63c | {u8 mode, u8 value} | scene struct: mode (0x41edef; 3 = battle, 0x40b922), value (0x44f9a0); saved as u16 | [C] |
| 0x4ae4bc | file | Imsg.e5 handle (reader 0x40bf56) | [C] |
| 0x4ae4c0 | u32 | 出征 pending flag (set 0x419808, test-and-clear 0x40b900) | [C] |
| 0x4b0758 | char[23] | second title string (saved; drawn by 0x415919) | [C] |
| 0x4b3c80 | object (0x88) | duel object | [G: as wg2025] |
| 0x4b3d08 | object | battle object; saved fields +0 u32, +4 u16, +8 u8, +0xc u32, +0x11 u8, +0x19 250 × {u32, u8}, +0x4fc u16, +0x500 u8, +0x504 u8 (0x44f14a / 0x44f1c6) | [C] |
| 0x4b422c / 0x4b422d | u8 | battle map width / height in cells | 0x403789 [C] |
| 0x4b5ee0 | u32[] | sortie candidates (person pointers) used by 0x418597 | [C] |

### Map buffer

Buffer object 0x48b140 (type byte, +4 size 0x19000, +0xc data pointer; getter 0x401669, offset getter 0x40167e).
There is no fixed pointer variable as in wg2025 (0x4aeb44): code always goes through 0x401669. Cell index =
x + y·W (0x403789).

| Offset | Size | Contents | Evidence |
|---|---|---|---|
| +0x0000 | 0x640 | map header (u16 words read by 0x426a77 / 0x426901) | [C] |
| +0x0640 | 0x640 | terrain byte per cell (0x412557: a cell whose unit has bit 2 set in 0x45d422(unit, 2) reads as 0x13 关隘) | [C] |
| +0x0c80 | 0x640 | unit slot per cell, 0xff = empty (0x41e110); **saved** in battle saves | [C] |
| +0x12c0 | 0x640 | movement / range scratch (cleared to 0xff by 0x43ab06) | [C] |
| +0x1900 | 0x640 | scratch (0x4384d1) | [C] |
| +0x1f40 | 0x640 | per-cell marks (0xff at battle start 0x407d26; 0xcc tested 0x40bde8) | [C] |
| +0x9c50 | 0x4e20 | cleared by 0x40c59b | [C] |

The other buffer objects (0x48b0c0 + 0x10·i, sizes 0x2af00, 0x75630, 0xc0680, 0x640, 0xb6100, 0x72960, 0x5000,
0x1222800, 0x19000; 0x42b88b) are scratch: 0x48b0e0 = data-load buffer, 0x48b100 = Data.e5 reload buffer,
0x48b120 = save-record buffer (0x5000).

## 8. The 0x501000 block (0x30000 bytes, saved raw)

Everything from 0x501000 to 0x531000 is written to and read from saves as one block (0x40531a / 0x41888d). The
6.6 engine keeps its extension state here.

| Address | Type | Meaning | Evidence |
|---|---|---|---|
| 0x501000 | u16[1024] | S (battle) sprite per person; 0 = by class; 1..0x20 → 0x50 + (v−1)·3 + class%3 … (exe file offset 0xD2800) | 0x4068de [C] |
| 0x501800 | u8 + 103 × 6 | history of persons who joined: count byte, then {u16 id, u8 value, u8 weapon, u8 armour, u8 accessory} (0x4095b9, 0x43edd0) | [C] |
| 0x501a84 | u8[250] | per-unit value (AddStat index 0xf) | 0x406eca [C] |
| 0x501ad0 | SYSTEMTIME | save time (GetLocalTime before writing) | 0x40531a [C] |
| 0x501c00 | u8[1024] | SP per person (EV 4061 = SP needed for 必杀) | 0x416eb3 [C] |
| 0x501fff | u8 | flag set by the sortie op | 0x415b9c [C] |
| 0x502000 | u32[4096] | EV: script integer variables, EV n at 0x502000 + 4n; config EVs 4016..4095 at 0x505ec0..0x505ffc (defaults in the exe) | 0x416cfe [C] |
| 0x506000 | u32[481] | PT: script pointer variables, index ≤ 0x1e0 | 0x416cd6 [C] |
| 0x506464 / 0x506f84 / 0x5068c8 | arrays indexed ≥ 200 | written by 0x413618 | [C] |
| 0x507800 | 2040 B | 兵种特效 table (6.5数据转移.txt: file 0xD9000) | [D] |
| 0x507ec0 | | growth modifier table (0x436e3d) | [C] |
| 0x508000 | u16[102][5] | per-person 功勋 per ability (persons < 0x66) | 0x408fa0 [C] |
| 0x5083fc | u8 | 功勋 flag / value used by joins (0x4095b9) and growth (0x46209a) | [C] |
| 0x5083fe | u8 | number of custom names in 0x510d00 | 0x4081f2 [C] |
| 0x508400 | s16[102][7] | per-person 功勋 stat bonuses (0x41055e) | [C] |
| 0x50e000 | 16-byte records | 套装 (item set) data (6.5数据转移.txt) | [D] |
| 0x50f000 | u16[1024] | face table (written at boot by 0x408c0c flag 0, read back on load / reset; portrait = v ? v + 7 : 0, 0x40765c) | [C] |
| 0x50f800 | u16[1024] | R (story) sprite per person (exe file offset 0xE1000; 0x409038, op 0x411f49) | [C] |
| 0x510c81 / 0x510c84 / 0x510cf8 | u8 | flags | [C] |
| 0x510cf9 | u8 | chapter number 章节编号 (op 0x3a kind 1 sets it) | 0x4148af [C] |
| 0x510d00 | 48 × 16 | custom person names {u16 id (0x400 = free), char[14]} (op with EV 4054, 0x4081f2); count 0x5083fe | [C] |
| 0x512500 | 16-byte records | second custom-name table, count 0x5083ff; both are re-applied by 0x4042d5 (from 0x417038) | [C] |
| 0x511800 | 1280 B | 必杀 table (6.5数据转移.txt: 6.4 E3000) | [D] |

`tools/conv_data.py` exports the initial S/R sprite tables to `data/sprite_tables.json` and the initial SP values
per person; the port's emulated memory gets the rest of the block from exe_image.bin.

## 9. Saves (`SV\SV%03u.E5S`, path 0x4288f4)

Writer **0x40531a**, reader **0x41888d** (then 0x4189da for battles). Layout of the file:

| File offset | Size | Contents |
|---|---|---|
| 0x00000 | 0x30000 | memory 0x501000 .. 0x531000, raw (the reader first checks byte 0x30000 == 5) |
| 0x30000 | 0xd4f0 | part A (0x4053cc / 0x405750): [0] 5, [1] party average level (0x40c231), [2] scene mode, [3] GS+6/2, [4] scene value or GS+5; +5 char[22] from 0x49f1cc; +0x1b char[23] from 0x4b0758; +0x32 GS 700 bytes; +0x2ee u16 scene struct 0x4ac63c; +0x2f0 128 actors × 0x24; +0x14f0 1024 persons × 0x30 |
| 0x3d4f0 | 0x313d | part B (0x405505 / 0x4187ad): 0x494fd4 [4000], 0x496ca0 [0x181], 0x496c9e [2], 0x496c94 [8], FLAGS 0x492fc8 [0x2000], 0x494fc8 [8], Reader fields [10] |
| 0x4062d | 0x23 or 0x3436 | battle part (0x407a37 / 0x4189da): [0] 5, [1] level of person 0, [2] battle+2 + 1, +5 battle title from 0x496ca0; in battle also the battle object fields (0x10 + 250·5), 250 units × 42, map unit grid 0x640 |

File sizes: 263760 (outside battle) and 277126 (in battle). The save list reads 4 bytes at 0x4062d, 0x10 at
0xad0 (the SYSTEMTIME), 0x40 at 0x30000 and the 21-byte name at 0x6165 (inside the 0x501000 block: 0x507165).

Memory ranges whose contents the original persists (the port's `Mem.SAVE_RANGES` should cover at least these):

```
[0x492f90, 0x497000)   Reader object + FLAGS + deployment table + battle title (part B; superset)
[0x49cf68, 0x49ef68)   RPG actors (part A, partially)
[0x49f1cc, 0x49f1e2)   scenario title
[0x4a7b20, 0x4aaa00)   battle units
[0x4ac63c, 0x4ac63e)   scene struct
[0x4b0758, 0x4b0a34)   title string + GS + sortie ring offsets
[0x4b3d08, 0x4b4210)   battle object (saved fields lie in +0 .. +0x505)
[0x501000, 0x531000)   6.6 block
+ the person heap (1024 × 0x48; the original keeps 0x30 of each) and the map buffer's unit grid (+0xc80, 0x640)
```

A simpler superset that is safe for the port: `[0x48b000, 0x4be000]` (all of .text2 incl. BSS) and
`[0x501000, 0x531000]`, plus the person heap and the map buffer. Tables the original never saves (items 0x49f820,
classes 0x4a2a27, families 0x4a3517, strategies 0x4a3e77, the .text3 extension tables below 0x501000) are reset
only by restarting the exe; scripts that poke them change them for the rest of the session.
