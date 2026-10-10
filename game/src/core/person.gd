class_name Person
extends RefCounted
## View of one character (武将) record in emulated memory (0x48-byte struct at [0x4d0048] + id*0x48).
## Stat index order everywhere: 0 攻击(武艺) 1 防御(统制) 2 精神(智谋) 3 爆发/反应(感知) 4 士气(胆魄)
## 5 HP max, 6 MP max, 7 move, 8 exp gain.

const STAT_KEYS := ["attack", "defense", "spirit", "agility", "morale"]
const NONE := 0xff

var id := 0
var name := ""

var base: int:
	get: return Mem.person_addr(id)

var face: int:
	get: return Mem.r32(base + 0x04)
	set(v): Mem.w32(base + 0x04, v)
var sprite: int:
	get: return Mem.r8(base + 0x02)
	set(v): Mem.w8(base + 0x02, v)
var cls: int:
	get: return Mem.r8(base + 0x2b)
	set(v): Mem.w8(base + 0x2b, v)
var level: int:
	get: return Mem.r8(base + 0x2c)
	set(v): Mem.w8(base + 0x2c, v)
var exp: int:
	get: return Mem.r8(base + 0x2d)
	set(v): Mem.w8(base + 0x2d, v)
var hp_base: int:
	get: return Mem.r32(base + 0x1c)
	set(v): Mem.w32(base + 0x1c, v)
var mp_base: int:
	get: return Mem.r8(base + 0x20)
	set(v): Mem.w8(base + 0x20, v)
var fixed_growth_flag: int:
	get: return Mem.r8(base + 0x2a)
	set(v): Mem.w8(base + 0x2a, v)
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
var bonus_counter := 0


func _item_slot(off: int) -> int:
	var v := Mem.r8(base + off)
	return -1 if v == NONE else v


func get_stat_word(i: int) -> int:
	return Mem.r16(base + 0x11 + 2 * i)


func set_stat_word(i: int, v: int) -> void:
	Mem.w16(base + 0x11 + 2 * i, v)


func get_raw(i: int) -> int:
	return Mem.r8(base + 0x21 + i)


func set_raw(i: int, v: int) -> void:
	Mem.w8(base + 0x21 + i, v)


## Initialise the memory record from a data.wa person record (parser 0x408be3).
static func init_record(r: Dictionary) -> Person:
	var p := Person.new()
	p.id = int(r["id"])
	p.name = str(r["name"])
	var b := p.base
	Mem.fill(b, Mem.PERSON_SIZE, 0)
	Mem.w16(b, p.id | 0x1000)
	p.face = int(r["face"])
	p.sprite = int(r["sprite"])
	Mem.w8(b + 0x26, int(r.get("unk_10", 0)))
	p.fixed_growth_flag = int(r.get("fixed_growth_flag", 255))
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
	p.weapon_lvl = NONE if r["weapon"] == null else 1
	p.weapon_exp = 0
	p.armor = -1 if r["armor"] == null else int(r["armor"])
	p.armor_lvl = NONE if r["armor"] == null else 1
	p.armor_exp = 0
	p.accessory = -1 if r["accessory"] == null else int(r["accessory"])
	Mem.w8(b + 0x35, NONE)
	Mem.w8(b + 0x36, NONE)
	if p.level >= 70:
		p.exp = 0xff
	return p


static func view(pid: int, pname: String) -> Person:
	var p := Person.new()
	p.id = pid
	p.name = pname
	return p


# ------------------------------------------------------------------ equipment math
func _item(i: int) -> Dictionary:
	return Game.item(i)


## Value of a weapon/armor at an equipment level: base + growth per extra level, capped 255.
static func item_value_at(it: Dictionary, lvl: int) -> int:
	var v := int(it.get("value", 0))
	for k in range(clampi(lvl, 1, 255) - 1):
		v = mini(v + int(it.get("growth", 0)), 255)
	return v


static func stat_of_type(t: int) -> int:
	if t <= 9 or t == 24: return 0
	if (t >= 10 and t <= 13) or t == 25: return 2
	if (t >= 14 and t <= 17) or t == 26: return 1
	match t:
		27: return 3
		28: return 4
		20, 29: return 5
		30: return 6
		32: return 7
		31: return 8
	return -1


static func stat_of_special(s: int) -> int:
	match s:
		20, 29: return 5
		24: return 0
		25: return 2
		26: return 1
		27: return 3
		28: return 4
		30: return 6
		31: return 8
		32: return 7
	return -1


func equip_bonus(s: int) -> int:
	var b := 0
	for slot in [[weapon, weapon_lvl], [armor, armor_lvl]]:
		var iid: int = slot[0]
		if iid < 0:
			continue
		var it := _item(iid)
		if it.is_empty():
			continue
		if stat_of_type(int(it["type"])) == s:
			b += item_value_at(it, slot[1])
		if it.get("treasure", false) and it.get("special") != null and stat_of_special(int(it["special"])) == s:
			b += _treasure_effect_value(it, slot[1])
	if accessory >= 0:
		var a := _item(accessory)
		if not a.is_empty() and stat_of_type(int(a["type"])) == s:
			b += int(a.get("value", 0))
	return b


func _treasure_effect_value(it: Dictionary, lvl: int) -> int:
	var sp := int(it.get("special", -1))
	var v := int(it.get("special_value", 0))
	if sp in [24, 25, 26]:
		v *= (lvl + 1)
	elif sp == 85:
		v *= (lvl + 4)
	return v


## Does this person have item effect `eid` (weapon/armor treasure special or accessory type)?
func has_effect(eid: int) -> bool:
	for iid in [weapon, armor]:
		if iid >= 0:
			var it := _item(iid)
			if it.get("treasure", false) and it.get("special") != null and int(it["special"]) == eid:
				return true
	if accessory >= 0:
		var a := _item(accessory)
		if not a.is_empty() and int(a["type"]) == eid:
			return true
	return false


func effect_value(eid: int) -> int:
	for slot in [[weapon, weapon_lvl], [armor, armor_lvl]]:
		var iid: int = slot[0]
		if iid >= 0:
			var it := _item(iid)
			if it.get("treasure", false) and it.get("special") != null and int(it["special"]) == eid:
				return _treasure_effect_value(it, slot[1])
	if accessory >= 0:
		var a := _item(accessory)
		if not a.is_empty() and int(a["type"]) == eid:
			return int(a.get("value", 0))
	return 0


# ------------------------------------------------------------------ equipping
## Slot of an item (0x40c6ea): 0 weapon, 1 armour, 2 accessory, 3 consumable.
static func slot_of(it: Dictionary) -> int:
	var t := int(it.get("type", 0xff))
	if t < 0xe: return 0
	if t < 0x12: return 1
	if t < 0x3f or t > 0x50: return 2
	return 3


## 0x407907: weapons and armour by the class's equip table, accessories by the family in the item's
## +0x17 byte (0xff = anyone; the mod lets families 8, 9, 18 and 24 wear item 0x4c, 0x4da23b).
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
			if fam == 0xff or fam == family():
				return true
			return iid == 0x4c and family() in [8, 9, 0x12, 0x18]
	return false


## Level an item gets when none is given (0x407dec / 0x4143c2), from a character level: normal items
## (level mod 18) / 6 + 1 below 48, else 3; treasures level / 7 + 1, at most 10.
static func auto_level_at(it: Dictionary, lv: int) -> int:
	if bool(it.get("treasure", false)):
		return mini(lv / 7 + 1, 10)
	return (lv % 18) / 6 + 1 if lv < 48 else 3


func auto_item_level(it: Dictionary) -> int:
	return auto_level_at(it, level)


func _set_slot(slot: int, iid: int, lvl: int, xp: int) -> void:
	Mem.w8(base + 0x2e + 3 * slot, NONE if iid < 0 else iid)
	Mem.w8(base + 0x2f + 3 * slot, lvl)
	if slot < 2:
		Mem.w8(base + 0x30 + 3 * slot, xp)


## Equipment code of ops 0x3e / 0x48 for one slot (0x4429f9): 0 = the default for the class and level,
## 1 = take it off, otherwise item code − 2 (weapon), code + 0x24 (armour) or code + 0x33 (accessory).
## `lvl` 0 = automatic.
func equip_code(slot: int, code: int, lvl: int) -> void:
	if code == 0:
		default_equip(slot)
	elif code == 1:
		_set_slot(slot, -1, NONE, NONE)
	else:
		equip_item(slot, code + [-2, 0x24, 0x33][slot], lvl)


## 0x407fe7: the first weapon (armour) kind the class can use, tier by level (0-17, 18-35, 36+).
func default_equip(slot: int) -> void:
	if slot > 1:
		return
	var eq: Array = Game.cls(cls).get("equip_raw", [])
	var tier := mini(level / 18, 2)
	var lvl := (level % 18) / 6 + 1 if level < 48 else 3
	var kinds := range(0, 14) if slot == 0 else range(14, 18)
	for t in kinds:
		if t < eq.size() and int(eq[t]) != 0:
			var iid: int = tier + (t / 2) * 3 if slot == 0 else 0x26 + tier + ((t - 14) / 2) * 3
			_set_slot(slot, iid, lvl, 0 if lvl < 3 else NONE)
			return


## 0x407dec: put item `iid` into `slot` if it is that kind of item and this person can use it.
## The level is capped at the item's maximum (3, treasures 10); a maxed item has no experience to gain.
func equip_item(slot: int, iid: int, lvl: int) -> void:
	var it := _item(iid)
	if it.is_empty() or slot_of(it) != slot or not can_equip(iid):
		return
	var maxl := 10 if bool(it.get("treasure", false)) else 3
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
	return mini(mp_base + equip_bonus(6), 255)


func move_points() -> int:
	return mini(int(Game.cls(cls).get("move", 4)) + equip_bonus(7), 255)


func family() -> int:
	return Game.family_of(cls)


func class_name_str() -> String:
	return str(Game.cls(cls).get("name", "?"))


## Battle sprite graphic id (0x406a75). Override table = person.wa bytes at 0x55a000.
func graphic_id() -> int:
	var v := Mem.r8(Mem.BYTEVARS + id) if id < 1024 else 0
	var tier := cls % 3
	if v == 0:
		var t: Array = Game.unit_index["entry_index"]["class_to_graphic"]
		return int(t[cls]) if cls < t.size() else 0x45
	if v <= 5:
		return 0x35 + 3 * (v - 1) + tier
	if v == 6:
		return 0x44 if cls < 0x28 else 0x45
	return v + 0x3f


## Sprite sheet entry for a colour variant (0 red, 1 green, 2 blue) (0x43fc48).
func sprite_entry(colour: int) -> int:
	var g := graphic_id()
	if g < 43:
		return g * 3 + mini(colour, 2)
	return g + 86


func face_tex(small := false) -> Texture2D:
	return Game.person_face(id, small)


# ------------------------------------------------------------------ growth
static func ability_grade(r: int) -> int:
	if r >= 100: return 5
	if r >= 90: return 4
	if r >= 80: return 3
	if r >= 70: return 2
	if r >= 60: return 1
	return 0


## Level-up by n levels (0x4073b9). Returns per-stat gains [atk,def,spi,agi,mor,hp,mp].
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
			if fixed_growth_flag == 0 and bonus_counter == 0:
				g = _jitter(g)
			var grade := ability_grade(get_raw(i))
			if bonus_counter > 0:
				bonus_counter -= 1
				grade += 1
			g = (grade + g) >> 1
		for k in n:
			if i <= 4 and g == 0:
				g = 1
			gains[i] += g
			_add_stat(i, g)
	level = level + n
	if level >= 70:
		exp = 0xff
	return gains


func _jitter(g: int) -> int:
	if Rules.chance(50):
		g += 1
	if Rules.chance(50):
		g = (g - 2) & 0xff
	return g


func _add_stat(i: int, g: int) -> void:
	if i <= 4:
		set_stat_word(i, mini(get_stat_word(i) + g, 9999))
	elif i == 5:
		hp_base = maxi(1, mini(hp_base + g, 9999))
	elif i == 6:
		if mp_base != 1:
			mp_base = maxi(1, mini(mp_base + g, 255))
