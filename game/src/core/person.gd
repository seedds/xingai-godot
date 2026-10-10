class_name Person
extends RefCounted
## View of one character (武将) record in emulated memory (0x48 bytes at [0x4cea00] + id*0x48; docs/memory.md §3).
## Stat index order everywhere: 0 攻击(武力) 1 防御(统率) 2 精神(智力) 3 爆发(敏捷) 4 士气(运气)
## 5 HP max, 6 MP max, 7 move, 8 exp gain.
## PENDING marks rules still taken over from wg2025 until docs/battle.md / docs/skills.md cover them.

const STAT_KEYS := ["attack", "defense", "spirit", "agility", "morale"]
const NONE := 0xff

var id := 0
var name := ""

var base: int:
	get: return Mem.person_addr(id)

## Portrait id (+0x04), mirrored in the face table 0x50f000 (written together by SetStat 0xf, 0x407027).
var face: int:
	get: return Mem.r16(base + 0x04)
	set(v):
		Mem.w32(base + 0x04, v & 0xffff)
		Mem.w16(Mem.FACE_TABLE + 2 * id, v)
var cls: int:
	get: return Mem.r8(base + 0x2b)
	set(v): Mem.w8(base + 0x2b, v)
var level: int:
	get: return Mem.r8(base + 0x2c)
	set(v): Mem.w8(base + 0x2c, v)
var exp: int:
	get: return Mem.r8(base + 0x2d)
	set(v): Mem.w8(base + 0x2d, v)
## Base max HP: u32 at +0x1b, readers use the low 16 bits (0x407263).
var hp_base: int:
	get: return Mem.r16(base + 0x1b)
	set(v): Mem.w32(base + 0x1b, v)
var mp_base: int:
	get: return Mem.r16(base + 0x1f)
	set(v): Mem.w16(base + 0x1f, v)
## Voice type for the generic critical lines (+0x26, 0x40c099).
var voice: int:
	get: return Mem.r8(base + 0x26)
## Army flag (+0x2a): 0 = in the player's army, 0xff = not.
var army: int:
	get: return Mem.r8(base + 0x2a)
	set(v): Mem.w8(base + 0x2a, v)
var battles: int:
	get: return Mem.r8(base + 0x27)
	set(v): Mem.w8(base + 0x27, v)
var retreats: int:
	get: return Mem.r8(base + 0x29)
	set(v): Mem.w8(base + 0x29, v)
var kills: int:
	get: return Mem.r16(base + 0x35)
	set(v): Mem.w16(base + 0x35, v)
var weapon: int:
	get: return _item_slot(0x2e)
	set(v): Mem.w8(base + 0x2e, NONE if v < 0 else v)
var weapon_lvl: int:
	get: return Mem.r8(base + 0x2f)
	set(v): Mem.w8(base + 0x2f, v)
var weapon_exp: int:
	get: return Mem.r8(base + 0x30)
	set(v): Mem.w8(base + 0x30, v)
var armor: int:
	get: return _item_slot(0x31)
	set(v): Mem.w8(base + 0x31, NONE if v < 0 else v)
var armor_lvl: int:
	get: return Mem.r8(base + 0x32)
	set(v): Mem.w8(base + 0x32, v)
var armor_exp: int:
	get: return Mem.r8(base + 0x33)
	set(v): Mem.w8(base + 0x33, v)
var accessory: int:
	get: return _item_slot(0x34)
	set(v): Mem.w8(base + 0x34, NONE if v < 0 else v)
## Battle (S) sprite override (u16 table 0x501000; 0 = by class).
var s_sprite: int:
	get: return Mem.r16(Mem.S_SPRITE + 2 * id)
	set(v): Mem.w16(Mem.S_SPRITE + 2 * id, v)
## Story (R) sprite: Pmapobj character (u16 table 0x50f800).
var r_sprite: int:
	get: return Mem.r16(Mem.R_SPRITE + 2 * id)
	set(v): Mem.w16(Mem.R_SPRITE + 2 * id, v)
## 必杀 SP (u8 table 0x501c00).
var sp: int:
	get: return Mem.r8(Mem.SP + id)
	set(v): Mem.w8(Mem.SP + id, v)
var bonus_counter := 0     # PENDING (wg2025 level-up bonus)


func _item_slot(off: int) -> int:
	var v := Mem.r8(base + off)
	return -1 if v == NONE else v


func get_stat_word(i: int) -> int:
	return Mem.r16(base + 0x11 + 2 * i)


func set_stat_word(i: int, v: int) -> void:
	Mem.w16(base + 0x11 + 2 * i, v)


## Raw ability bytes +0x21.. (stats 0xa..0xe, ≤ 100).
func get_raw(i: int) -> int:
	return Mem.r8(base + 0x21 + i)


func set_raw(i: int, v: int) -> void:
	Mem.w8(base + 0x21 + i, v)


## Expand a Data.e5 person record into memory (0x408c0c with flag 0, at boot): the record is zeroed, the face
## goes into the record and the face table, HP is clamped to 500 and MP to 250, equipment keeps level and exp 0.
static func init_record(r: Dictionary) -> Person:
	var p := Person.new()
	p.id = int(r["id"])
	p.name = str(r["name"])
	var b := p.base
	Mem.fill(b, Mem.PERSON_SIZE, 0)
	Mem.w32(b, p.id | 0x1000)
	# name: 12 bytes copied to +0x08, the part from byte 8 on moved to +0x3f (0x40a72c)
	var nb := Gbk.encode(p.name)
	for k in mini(nb.size(), 8):
		Mem.w8(b + 0x08 + k, nb[k])
	for k in range(8, mini(nb.size(), 13)):
		Mem.w8(b + 0x3f + k - 8, nb[k])
	p.face = int(r["face"])
	Mem.w8(b + 0x26, int(r.get("unk_10", 0)))
	p.army = int(r.get("army", 255))
	for i in 5:
		var v := int(r[STAT_KEYS[i]])
		p.set_stat_word(i, v)
		p.set_raw(i, v)
	p.hp_base = mini(int(r["hp"]), 500)
	p.mp_base = mini(int(r["mp"]), 250)
	p.cls = int(r["class"])
	p.level = maxi(1, int(r["level"]))
	p.exp = int(r["exp"])
	p.weapon = -1 if r["weapon"] == null else int(r["weapon"])
	p.armor = -1 if r["armor"] == null else int(r["armor"])
	p.accessory = -1 if r["accessory"] == null else int(r["accessory"])
	return p


static func view(pid: int, pname: String) -> Person:
	var p := Person.new()
	p.id = pid
	p.name = pname
	return p


# ------------------------------------------------------------------ equipment math (docs/rules.md §1.2)
func _item(i: int) -> Dictionary:
	return Game.item(i)


static func is_treasure(it: Dictionary) -> bool:
	return bool(it.get("treasure", false))


## Maximum equipment level (0x4201c1): treasures 10, others 5.
static func max_item_level(it: Dictionary) -> int:
	return 10 if is_treasure(it) else 5


## Value at an equipment level (0x40b3d7): weapons and armour add their growth (L − 1) times — a byte loop, so
## level 0 adds it 255 times as in the original; accessories and items: the value.
static func item_value_at(it: Dictionary, lvl: int) -> int:
	var v := int(it.get("value", 0))
	if int(it.get("category_code", 3)) <= 1:
		v += int(it.get("growth", 0)) * ((lvl - 1) & 0xff)
	return v


## Stat a type / effect id raises (0x4067ce for accessory types and 0x40678e for treasure specials; equipment
## types < 0x1a by kind through table 0x40684f): 0..4 stats, 5 HP, 6 MP, 7 move, 8 exp %, 9 (神魔附体),
## 10 攻击 and 精神 (0x405670), -1 none.
static func stat_of_type(t: int) -> int:
	if t < 0x1a:
		return Mem.r8(0x40684f + (t >> 1))
	if t >= 0x20 and t <= 0x28:
		return Mem.r8(0x4067c5 + t - 0x20)
	if t == 0x5c: return 9
	if t == 0xfe: return 10
	return -1


## Stats an equipment kind (type >> 1) raises (table 0x40684f): kinds 0–6 攻击, 7–8 精神, 9 攻击 and 精神 (code 10,
## 0x405670), 10–12 防御.
static func stats_of_kind(kind: int) -> Array:
	if kind <= 6: return [0]
	if kind <= 8: return [2]
	if kind == 9: return [0, 2]
	if kind <= 12: return [1]
	return []


## Stat an accessory type raises (0x4067ce): 0x20..0x26 → stats 0..6, 0x27 → 8 (exp), 0x28 → 7 (move).
static func stat_of_accessory(t: int) -> int:
	if t >= 0x20 and t <= 0x26: return t - 0x20
	if t == 0x27: return 8
	if t == 0x28: return 7
	return -1


static func _stat_matches(t: int, s: int) -> bool:
	return t == s or (t == 10 and (s == 0 or s == 2))


## Equipment bonus to stat s (0x407c29; 0..4 stats, 5 HP max, 6 MP max, 7 move, 8 exp %): weapon / armour main
## values flat (0x40b3d7), a treasure's special and an accessory as a percentage of the person's base (0x452825).
func equip_bonus(s: int) -> int:
	var b := 0
	for k in 2:
		var iid := Mem.r8(base + 0x2e + 3 * k)
		if iid == NONE:
			continue
		var it := _item(iid)
		if it.is_empty():
			continue
		var lvl := Mem.r8(base + 0x2f + 3 * k)
		if _stat_matches(stat_of_type(int(it["type"])), s):
			b += item_value_at(it, lvl)
		if is_treasure(it) and it.get("special") != null and stat_of_type(int(it["special"])) == s:
			b += scale_pct(s, Effects.value_at_level(it, lvl))
	var acc := Mem.r8(base + 0x34)
	if acc != NONE:
		var a := _item(acc)
		if not a.is_empty() and stat_of_type(int(a["type"])) == s:
			b += scale_pct(s, int(a.get("value", 0)))
	return b


## 0x452825: stats 0..6 (table 0x4cb6c0 = 2) take `v` % of the person's base word (HP: the base HP, MP: the base
## MP; with 神魔附体 the stats use grade·level + raw instead, 0x436e02); move and exp % stay flat.
func scale_pct(s: int, v: int) -> int:
	if s >= 7 or Mem.r8(0x4cb6c0 + s) != 2:
		return v
	var b := 0
	var smf := shenmo(s)
	if s < 5 and smf[0]:
		b = smf[2]
	elif s < 5:
		b = get_stat_word(s)
	elif s == 5:
		b = Mem.r32(base + 0x1b)
	else:
		b = Mem.r16(base + 0x1f)
	return b * v / 100


## 神魔附体 (0x436e02 → 0x407d48) for stat s < 5: QueryAny(61, 0x5c, 0, 0) with an item, or a value ≠ 0 (0xff
## counts as 0): grade = the value, or the class growth 0x4250b6 when 0; extra = max(grade·level + raw + 功勋 bonus,
## stat word) − stat word. Returns [active, extra, grade·level + raw].
func shenmo(s: int) -> Array:
	if s >= 5:
		return [false, 0, 0]
	var q := Effects.query_any(id, 61, 0x5c, 0, 0)
	var v: int = q[0] & 0xff
	if q[1] == 0:
		if v == 0:
			return [false, 0, 0]
		if v == 0xff:
			v = 0
	var g := v if v != 0 else growth(s)
	var gl := g * level + get_raw(s)
	var w := get_stat_word(s)
	return [true, maxi(gl + merit_bonus(s), w) - w, gl]


## Kill-count bonus 0x405b86 (EV 4046 殺敵數加成): k = 0x7f → +1 at 100 kills; else + v·(kills / k) %.
func kill_bonus(k: int, v: int) -> int:
	if Mem.r8(Mem.EV + 4 * 4046) == 0:
		return v
	if k == 0x7f:
		return v + (1 if kills > 99 else 0)
	return v + v * (kills / k) / 100


## BaseStat 0x43c4d3: kill bonus (per 30 kills), 破百加成 (EV 4073: raw ability above 100 adds that many %),
## at most 9999.
func base_stat(s: int) -> int:
	var b := kill_bonus(30, get_stat_word(s))
	var r := get_raw(s)
	if Mem.r8(Mem.EV + 4 * 4073) != 0 and r > 100:
		b += b * (r - 100) / 100
	return mini(b, 9999)


## 功勋 stat bonus 0x41055d: persons < 102 in the army, s16 word 0x508400 + 14·id + 2·s.
func merit_bonus(s: int) -> int:
	if id >= 0x66 or army != 0:
		return 0
	return Mem.r16s(0x508400 + 14 * id + 2 * s)


## Effect query on this person (QueryAny 0x42518f: the unit's query in a battle, else the sources).
func eff(sid: int, eid: int, m: int, a4: int) -> int:
	return Effects.any(id, sid, eid, m, a4)


## Presence of an item effect (0x4079da).
func has_effect(eid: int) -> bool:
	return Effects.has_item_effect(id, eid)


# ------------------------------------------------------------------ equipping
## Slot of an item by category (0x40b444): 0 weapon, 1 armour, 2 accessory, 3 consumable.
static func slot_of(it: Dictionary) -> int:
	return int(it.get("category_code", 3))


## Accessory family groups (0x420e83, table 0x44c341): a wearer of family 12 may also use family 18, 19 and 26
## accessories, family 2 also 4 and 19, family 3 also 12.
const ACC_GROUPS := {12: [0x12, 0x13, 0x1a], 2: [4, 0x13], 3: [0x0c]}


## Weapons and armour by the class's equip flags (class byte 9 + type, 0x41c60f); accessories by the family in
## the item's +0x17 byte (0xff = anyone) and the family groups.
func can_equip(iid: int) -> bool:
	var it := _item(iid)
	if it.is_empty():
		return false
	match slot_of(it):
		0, 1:
			var eq: Array = Game.cls(cls).get("equip_raw", [])
			var t := int(it["type"])
			return t < eq.size() and int(eq[t]) != 0
		2:
			var fam := int(it.get("growth", 0xff))
			return fam == 0xff or fam == family() or fam in ACC_GROUPS.get(family(), [])
	return false


## Automatic equipment level for a person level (0x407da3): treasures min(lv/6 + 1, 9); others (lv % 20)/4 + 1,
## 5 from level 60.
static func auto_level_at(it: Dictionary, lv: int) -> int:
	if is_treasure(it):
		return mini(lv / 6 + 1, 9)
	return (lv % 20) / 4 + 1 if lv < 60 else 5


func auto_item_level(it: Dictionary) -> int:
	return auto_level_at(it, level)


## EXP byte for a level (0x4201d5): below the maximum 0 (level 9 → 0xff), at the maximum 0xff (level 9 → 0xfe).
static func exp_at_level(lvl: int, maxl: int) -> int:
	if lvl < maxl:
		return 0xff if lvl == 9 else 0
	return 0xfe if lvl == 9 else 0xff


## 0x41ca49: slot k ← item, level, exp (the accessory slot holds the id only).
func _set_slot(slot: int, iid: int, lvl: int, xp: int) -> void:
	Mem.w8(base + 0x2e + 3 * slot, NONE if iid < 0 else iid)
	if slot < 2:
		Mem.w8(base + 0x2f + 3 * slot, lvl)
		Mem.w8(base + 0x30 + 3 * slot, xp)


## Equipment code of one slot as the battle setup decodes it (0x44299b): codes 0xff and above 0x95 do nothing;
## 0 = the default for the class and level (0x407fd4), 1 = take off (0x406cbc), otherwise an item (0x407df1).
## (Op 0x3e skips code 0 itself.)
func equip_code(slot: int, code: int, lvl: int) -> void:
	if code == 0xff or code > 0x95 or slot > 2:
		return
	if code == 0:
		default_equip(slot)
	elif code == 1:
		take_off(slot, lvl)
	else:
		equip_item_code(slot, code, lvl)


## 0x406cbc: take the slot's item off; with lvl 1 an army member's item goes back to the bag.
func take_off(slot: int, lvl: int) -> void:
	if lvl == 1 and army == 0:
		var iid := Mem.r8(base + 0x2e + 3 * slot)
		if iid != NONE:
			Game.add_item(iid, Mem.r8(base + 0x2f + 3 * slot), Mem.r8(base + 0x30 + 3 * slot))
	_set_slot(slot, -1, NONE, NONE)


## Default weapon / armour 0x407fd4: the first type the class may equip (weapons 0..19, armour 20..25) → the
## automatic shop's first item of that kind (table 0x482427) + tier (level / 20, ≤ 2); level (level % 20)/4 + 1,
## 5 from level 60. Accessories: nothing.
func default_equip(slot: int) -> void:
	if slot > 1:
		return
	var tier := mini(level / 20, 2)
	var lv := (level % 20) / 4 + 1 if level < 60 else 5
	var eq: Array = Game.cls(cls).get("equip_raw", [])
	var iid := NONE
	var lo := 0 if slot == 0 else 0x14
	var hi := 0x14 if slot == 0 else 0x1a
	for t in range(lo, hi):
		if t < eq.size() and int(eq[t]) != 0:
			iid = (Mem.r8(0x482427 + (t >> 1)) + tier) & 0xff
			break
	Mem.w8(base + 0x2e + 3 * slot, iid)
	Mem.w8(base + 0x2f + 3 * slot, lv)
	Mem.w8(base + 0x30 + 3 * slot, 0 if lv < 5 else 0xff)


## 0x407df1: item = code − 2 + {0, 70, 109} by slot, or the raw id when lvl is 0xfe (then automatic level); the
## item's category must be the slot's (no class check); level 0 → automatic (0x407da3), above the maximum → the
## maximum (0xff stays); accessories level 0xff.
func equip_item_code(slot: int, code: int, lvl: int) -> void:
	var iid: int
	if lvl == 0xfe:
		lvl = 0
		iid = code
	else:
		iid = code - 2 + [0, 0x46, 0x6d][slot]
	var it := _item(iid & 0xff)
	if it.is_empty() or slot_of(it) != slot:
		return
	var maxl := max_item_level(it)
	if lvl == 0:
		lvl = auto_level_at(it, level)
	elif lvl != NONE and lvl > maxl:
		lvl = maxl
	var xp := exp_at_level(lvl, maxl)
	if slot == 2:
		lvl = NONE
	_set_slot(slot, iid & 0xff, lvl, xp)


## Put item `iid` into `slot` from a menu (category and class checked); the level is capped at the item's maximum.
func equip_item(slot: int, iid: int, lvl: int) -> void:
	var it := _item(iid)
	if it.is_empty() or slot_of(it) != slot or not can_equip(iid):
		return
	var maxl := max_item_level(it)
	if lvl == 0:
		lvl = auto_item_level(it)
	elif lvl != NONE:
		lvl = mini(lvl, maxl)
	_set_slot(slot, iid, NONE if slot == 2 else lvl, exp_at_level(lvl, maxl))


# ------------------------------------------------------------------ derived stats
## Person stat s (0x40715a + 0x35·s): BaseStat + equipment bonus + 神魔附体, at most 9999. The unit's battle stat
## builds on this (Rules.unit_stat).
func stat(s: int) -> int:
	var x: Array = shenmo(s)
	return mini(base_stat(s) + equip_bonus(s) + int(x[1]), 9999)


## Max HP 0x407263: kill bonus (per 15 kills) on the base HP word + equipment, at most 0xffff.
func max_hp() -> int:
	return mini(equip_bonus(5) + kill_bonus(15, hp_base), 0xffff)


## Max MP 0x40728f: as max HP, at most 9999.
func max_mp() -> int:
	return mini(equip_bonus(6) + kill_bonus(15, mp_base), 9999)


## Move 0x4072bb: equipment + class move (+1 at 100 kills with EV 4046), at most 127.
func move_points() -> int:
	return mini(equip_bonus(7) + kill_bonus(0x7f, int(Game.cls(cls).get("move", 4))), 0x7f)


func family() -> int:
	return Game.family_of(cls)


func class_name_str() -> String:
	return str(Game.cls(cls).get("name", "?"))


## Battle sprite graphic (0x40685c / 0x4068a1): S-table value v = 0 → the class; 1..32 → 0x50 + 3(v−1) + class%3;
## from 33 on → v + 0x8f.
func graphic_id() -> int:
	var v := s_sprite
	if v == 0:
		return cls
	if v <= 32:
		return 0x50 + 3 * (v - 1) + cls % 3
	return v + 0x8f


## Unit sprite sheet entry for a colour variant (unit byte +5) (0x43fc48): graphics below 0x50 come in three
## colours; the others have one.
func sprite_entry(colour: int) -> int:
	var g := graphic_id()
	if g < 0x50:
		return g * 3 + mini(colour, 2)
	return g + 0xa0


func face_tex(small := false) -> Texture2D:
	return Game.person_face(id, small)


# ------------------------------------------------------------------ growth
## Growth grade of a raw ability (0x4072f2): ≥ 99 → 10, ≥ 90 → 8, ≥ 70 → 6, ≥ 50 → 4, else 2.
static func ability_grade(r: int) -> int:
	if r >= 99: return 10
	if r >= 90: return 8
	if r >= 70: return 6
	if r >= 50: return 4
	return 2


const GROWTH_KEYS := ["attack", "defense", "spirit", "agility", "morale", "hp", "mp"]


## Class growth byte class[2 + i] (0x40dbae): 0..4 the stats, 5 HP, 6 MP.
static func class_growth(c: int, i: int) -> int:
	var g: Dictionary = Game.cls(c).get("growth", {})
	return int(g.get(GROWTH_KEYS[i], 0))


## Per-person growth modifier (0x436e3d, list 0x507ec0 written by op 0x72 sub 36): the signed amount, a negative
## one counting one less.
func growth_adj(i: int) -> int:
	var e := Effects.stream_find(Effects.GROWTH_ADJ, i, id, 0)
	if e < 0:
		return 0
	var v := Mem.r8s(e)
	return v + 1 if v < 0 else v


## Growth per level (0x4250b6) with class c (default the person's): HP / MP the class byte; stats
## (class grade + ability grade) / 2, each term with the person's modifier. No randomness.
func growth(i: int, c := -1) -> int:
	if c < 0:
		c = cls
	var g := class_growth(c, i) + growth_adj(i)
	if i > 4:
		return g
	return maxi(g + ability_grade(get_raw(i)) + growth_adj(i), 0) >> 1


## AddStat 0x406eca (mode 0): stats ≤ 9999, base HP (dword) ≤ 9999, base MP (word) ≤ 9999.
func add_stat(i: int, v: int) -> void:
	if i <= 4:
		set_stat_word(i, mini(get_stat_word(i) + v, 9999))
	elif i == 5:
		Mem.w32(base + 0x1b, mini(Mem.r32(base + 0x1b) + v, 9999))
	elif i == 6:
		mp_base = mini(mp_base + v, 9999)
	elif i >= 10 and i <= 14:
		set_raw(i - 10, mini(get_raw(i - 10) + v, 100))


## LevelUp 0x4073f3 without its window: level += n (≤ 255), each of the 7 values grows by Growth(i) per level, or
## with EV 4094 (升級時能力會重新計算) the five stats are recalculated once. Returns the gains [5 stats, HP, MP].
## The unit's current HP/MP are not touched.
func level_up(n := 1) -> Array:
	n = mini(n, 255 - level)
	var gains := [0, 0, 0, 0, 0, 0, 0]
	if n <= 0:
		return gains
	level = level + n
	var recalc_on := Mem.r32(Mem.EV + 4 * 4094) != 0
	for i in 7:
		var before := get_stat_word(i) if i <= 4 else (hp_base if i == 5 else mp_base)
		var g := growth(i)
		if recalc_on and i <= 4:
			recalc(i)
		else:
			for k in n:
				add_stat(i, g)
		var after := get_stat_word(i) if i <= 4 else (hp_base if i == 5 else mp_base)
		gains[i] = after - before
	if level >= 100:
		exp = 0xff
	return gains


## Recalc 0x43a409 (EV 4094): stat = growth sum + raw + 功勋 bonus; an army member's stat is never lowered.
func recalc(s: int) -> void:
	var v := growth_sum(s) + get_raw(s) + merit_bonus(s)
	if army != 0 or v > get_stat_word(s):
		set_stat_word(s, mini(v, 9999))


## GrowthSum 0x408a60: 15 levels per lower tier with that tier's growth, the rest with the current class.
func growth_sum(s: int) -> int:
	var c := cls
	var l := level
	var tier := c % 3 if c <= 59 else 0
	var sum := 0
	if tier == 2 and l >= 30:
		c -= 1
		sum += growth(s, c) * 15
		l -= 15
	if tier >= 1 and l >= 15:
		c -= 1
		sum += growth(s, c) * 15
		l -= 15
	return sum + growth(s) * l


## SetExp 0x4088cd without the windows: no EXP at level ≥ 100; every 100 points one LevelUp. Returns the gains of
## each level-up in order (empty if none).
func add_exp(add: int) -> Array:
	var out := []
	if level >= 100:
		return out
	var total := (exp if exp != 0xff else 0) + add
	while total >= 100:
		out.append(level_up(1))
		total -= 100
	exp = 0xff if level >= 100 else total & 0xff
	return out


## Equipment EXP 0x4082dd for slot 0 weapon / 1 armour: 100 per level (treasures 200), levels 5 (treasures 9);
## EXP 0xff at the maximum. Returns the number of levels gained.
func equip_exp_add(k: int, add: int) -> int:
	var iid := Mem.r8(base + 0x2e + 3 * k)
	if iid == NONE or add <= 0:
		return 0
	var it := _item(iid)
	var need := 200 if is_treasure(it) else 100
	var maxl := 9 if is_treasure(it) else 5
	var l := Mem.r8(base + 0x2f + 3 * k)
	var e := Mem.r8(base + 0x30 + 3 * k) + add
	var n := 0
	while e >= need and l < maxl:
		l += 1
		n += 1
		e -= need
	Mem.w8(base + 0x2f + 3 * k, l)
	Mem.w8(base + 0x30 + 3 * k, 0xff if l >= maxl else e & 0xff)
	return n


## CanPromote 0x41d3dc: "" when the class can be raised, else the original's message.
func promote_refusal() -> String:
	if cls > 59:
		return "这是不能提升兵种的部队。"
	if cls % 3 == 2:
		return "不能再提升兵种了。"
	var need := (cls % 3 + 1) * 15
	if level < need:
		return "下一个兵种需要等级%d以上。" % need
	return ""


## Promote 0x41d468 (person part): class + 1, base HP / MP + 2·(new class growth + modifier) for army members whose
## new class is a higher tier (0x413fac). The caller refills the unit and shows "%s的兵种提升为%s！".
func promote() -> void:
	cls = cls + 1
	for i in [5, 6]:
		if army != NONE and cls <= 59 and cls % 3 != 0:
			add_stat(i, 2 * (class_growth(cls, i) + growth_adj(i)))
