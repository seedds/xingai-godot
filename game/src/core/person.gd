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
	var nb := p.name.to_multibyte_char_buffer("GBK")
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


## Value at an equipment level (0x40b3d7): value + growth per level above 1 for equipment; accessories: value.
static func item_value_at(it: Dictionary, lvl: int) -> int:
	var v := int(it.get("value", 0))
	if int(it.get("category_code", 3)) <= 1:
		v += int(it.get("growth", 0)) * (maxi(lvl, 1) - 1)
	return v


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


## PENDING: treasure specials (0x40678e, table 0x4067c5) are not yet added.
func equip_bonus(s: int) -> int:
	var b := 0
	for slot in [[weapon, weapon_lvl], [armor, armor_lvl]]:
		var iid: int = slot[0]
		if iid < 0:
			continue
		var it := _item(iid)
		if it.is_empty():
			continue
		if s in stats_of_kind(int(it["type"]) >> 1):
			b += item_value_at(it, slot[1])
	if accessory >= 0:
		var a := _item(accessory)
		if not a.is_empty() and stat_of_accessory(int(a["type"])) == s:
			b += int(a.get("value", 0))
	return b


## PENDING: the 6.6 effect query (docs/skills.md) replaces this item-effect check.
func has_effect(eid: int) -> bool:
	for iid in [weapon, armor, accessory]:
		if iid >= 0 and _item(iid).get("effect") != null and int(_item(iid)["effect"]) == eid:
			return true
	return false


func effect_value(eid: int) -> int:
	for iid in [weapon, armor, accessory]:
		if iid >= 0 and _item(iid).get("effect") != null and int(_item(iid)["effect"]) == eid:
			return int(_item(iid).get("special_value", 0))
	return 0


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


## PENDING: level an item gets when none is given (wg2025 0x407dec rule).
static func auto_level_at(it: Dictionary, lv: int) -> int:
	if is_treasure(it):
		return mini(lv / 7 + 1, 10)
	return (lv % 18) / 6 + 1 if lv < 48 else 3


func auto_item_level(it: Dictionary) -> int:
	return auto_level_at(it, level)


func _set_slot(slot: int, iid: int, lvl: int, xp: int) -> void:
	Mem.w8(base + 0x2e + 3 * slot, NONE if iid < 0 else iid)
	Mem.w8(base + 0x2f + 3 * slot, lvl)
	if slot < 2:
		Mem.w8(base + 0x30 + 3 * slot, xp)


## Equipment code of ops 0x3e / 0x48 for one slot (0x407df1): 0 = the default for the class and level, 1 = take it
## off, otherwise code − 2 + the slot's first id (weapons 0, armour 70, accessories 109). PENDING: verify the
## code offsets and default equipment (table 0x482427) in docs/eex.md.
func equip_code(slot: int, code: int, lvl: int) -> void:
	if code == 0:
		default_equip(slot)
	elif code == 1:
		_set_slot(slot, -1, NONE, NONE)
	else:
		equip_item(slot, code - 2 + [0, 70, 109][slot], lvl)


## PENDING: the class's default weapon / armour (default-equipment table 0x482427).
func default_equip(slot: int) -> void:
	pass


## Put item `iid` into `slot` if it is that kind of item and this person can use it; the level is capped at the
## item's maximum.
func equip_item(slot: int, iid: int, lvl: int) -> void:
	var it := _item(iid)
	if it.is_empty() or slot_of(it) != slot or not can_equip(iid):
		return
	var maxl := max_item_level(it)
	if lvl == 0:
		lvl = auto_item_level(it)
	elif lvl != NONE:
		lvl = mini(lvl, maxl)
	var xp := 0 if lvl < maxl else NONE
	_set_slot(slot, iid, NONE if slot == 2 else lvl, xp)


# ------------------------------------------------------------------ derived stats
func stat(s: int) -> int:
	return mini(get_stat_word(s) + equip_bonus(s), 9999)


func max_hp() -> int:
	return mini(hp_base + equip_bonus(5), 9999)


func max_mp() -> int:
	return mini(mp_base + equip_bonus(6), 9999)


func move_points() -> int:
	return mini(int(Game.cls(cls).get("move", 4)) + equip_bonus(7), 255)


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


## Level-up by n levels. PENDING: LevelUp 0x4073f3 (class growth, grade, modifier table 0x507ec0) from
## docs/battle.md; until then class growth + grade / 2 per level. Returns per-stat gains [atk,def,spi,agi,mor,hp,mp].
func level_up(n := 1) -> Array:
	n = mini(n, 255 - level)
	var gains := [0, 0, 0, 0, 0, 0, 0]
	if n <= 0:
		return gains
	var growth: Dictionary = Game.cls(cls).get("growth", {})
	var gkeys := ["attack", "defense", "spirit", "agility", "morale", "hp", "mp"]
	for i in 7:
		var g := int(growth.get(gkeys[i], 0))
		if i <= 4:
			g = maxi((g + ability_grade(get_raw(i))) >> 1, 1)
		for k in n:
			gains[i] += g
			_add_stat(i, g)
	level = level + n
	if level >= 100:
		exp = 0xff
	return gains


func _add_stat(i: int, g: int) -> void:
	if i <= 4:
		set_stat_word(i, mini(get_stat_word(i) + g, 9999))
	elif i == 5:
		hp_base = maxi(1, mini(hp_base + g, 9999))
	elif i == 6:
		mp_base = maxi(0, mini(mp_base + g, 9999))
