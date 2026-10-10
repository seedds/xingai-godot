extends Node
## Global game state: static data tables, runtime persons, party, inventory, variables.

const MAX_PERSONS := 1024
const INVENTORY_MAX := 100

# static tables
var items_db: Array = []
var classes_db: Array = []
var families_db: Array = []
var strategies_db: Array = []
var shops_db: Array = []
var names_db: Dictionary = {}
var texts_db: Dictionary = {}
var terrain_names: Array = []
var unit_index: Dictionary = {}
var portraits: Dictionary = {}

# runtime state
var persons: Array[Person] = []
var party: Array[int] = []            # person ids in the player's army (我军)
var inventory: Array = []             # [{id, lvl, exp}]
var flags: Dictionary = {}            # (unused; flags live in Mem)
var ivars: Dictionary = {}            # integer variables, key "kind:index"
var scenario_jumped := false
var autoplay := OS.get_environment("WG_AUTO") != ""
var demo := OS.get_environment("WG_DEMO") != ""
var god := OS.get_environment("WG_GOD") != ""   # debug: player side invulnerable & strong
var history: Array = []
var ending_reached := false
var skip_battle_scenario := -1   # flow-test: skip this battle (jump to its aftermath)
var _name_index: Dictionary = {}

## GS+6 (u16): scenario counter. even = R_(n/2) story file, odd = S_(n/2) battle file.
var scenario: int:
	get: return Mem.r16(Mem.GS + 6)
	set(v): Mem.w16(Mem.GS + 6, v)

## GS+0xc: gold (u32, max 999,999; setter 0x40e1a4).
var gold: int:
	get: return Mem.r32(Mem.GS + 0xc)
	set(v): Mem.w32(Mem.GS + 0xc, clampi(v, 0, 999999))
var chapter_title := ""
var play_time := 0.0
var loaded := false
var clicks := 0                  # count of click / confirm presses; waits compare it to see a new press
var main = null                  # the Main node (src/main.gd); inside the touch shell it is not /root/Main
var shell = null                 # TouchShell when the game runs in it (mobile), else null
var touch := false               # touch controls: tap on release, drag pans the map / scrolls lists
var fast_toggle := false         # the touch shell's 快进 button: acts like holding Ctrl


func _ready() -> void:
	load_data()


func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if shell and not shell.over_game(ev.position):
			return       # a touch-shell button beside the picture, not a click in the game
		if ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			clicks += 1
	elif ev.is_action_pressed("ui_accept") or ev.is_action_pressed("ui_cancel"):
		clicks += 1


## Ctrl held (or the touch shell's 快进 on): type text fast and skip waits.
func skip_held() -> bool:
	return fast_toggle or Input.is_key_pressed(KEY_CTRL)


func load_data() -> void:
	items_db = Assets.json("data/items.json")
	classes_db = Assets.json("data/classes.json")
	families_db = Assets.json("data/class_families.json")
	strategies_db = Assets.json("data/strategies.json")
	shops_db = Assets.json("data/shops.json")
	names_db = Assets.json("data/names.json")
	texts_db = Assets.json("data/texts.json")
	var t: Variant = Assets.json("data/terrain.json")
	terrain_names = t["names"] if t else []
	var ui: Variant = Assets.json("gfx/units/index.json")
	unit_index = ui if ui else {}
	var pi: Variant = Assets.json("gfx/portraits/index.json")
	portraits = pi if pi else {}
	new_game_state()
	loaded = true


## Reset a person from Data.e5 (0x41b617 → 0x408c0c with flag 1): like the boot load, but the face comes back
## from the face table instead of the file.
func reset_person(pid: int) -> void:
	var recs: Array = Assets.json("data/persons.json")
	if pid < 0 or pid >= recs.size():
		return
	var keep_face := Mem.r16(Mem.FACE_TABLE + 2 * pid)
	Person.init_record(recs[pid])
	person(pid).face = keep_face


## Sortie parameters (GS+0x26b..): maximum, forced persons u16[20] and excluded persons u16[20], each list
## written 5 at a time at a ring offset (u32 0x4b0a2c / 0x4b0a30).
const SORTIE_MAX := 0x4b09db
const SORTIE_FORCED := 0x4b09dc
const SORTIE_EXCLUDED := 0x4b0a04
const SORTIE_RING := 0x4b0a2c
const SORTIE_LIST := 0x48b350     # u16 person ids, 0xffff-terminated


## Sortie defaults (0x41c96d): both lists 0xffff, ring offsets 0.
func reset_sortie_params() -> void:
	Mem.fill(SORTIE_FORCED, SORTIE_RING - SORTIE_FORCED, 0xff)
	Mem.w32(SORTIE_RING, 0)
	Mem.w32(SORTIE_RING + 4, 0)


## A new game: the state the original has after booting (Data.e5 loaded, 0x41b639) and the title's new-game
## initialisation (0x42baf8).
func new_game_state() -> void:
	Mem.reset()
	persons.clear()
	var recs: Array = Assets.json("data/persons.json")
	for r in recs:
		persons.append(Person.init_record(r))
	party.clear()
	inventory.clear()
	history.clear()
	init_bag()
	# 0x42baf8: GS+0..3 = 1f 01 01 00 (then the settings bytes 4..7 of SV\SV.E5S), GS+4 = 0xff, the bytes of flags 22848..25663 cleared
	for k in 4:
		Mem.w8(Mem.GS + k, [0x1f, 1, 1, 0][k])
	Mem.w32(Mem.GS + 4, 0xff)
	Mem.fill(0x493af0, 352, 0)
	Mem.w8(SORTIE_MAX, 1)
	reset_sortie_params()
	ivars.clear()
	play_time = 0.0
	TextExpand.invalidate()
	_name_index.clear()
	for p in persons:
		if p.name != "" and not _name_index.has(p.name):
			_name_index[p.name] = p.id


func _process(delta: float) -> void:
	play_time += delta / maxf(Engine.time_scale, 0.01)    # real time, also while fast-forwarding


# ------------------------------------------------------------------ lookups
func person(id: int) -> Person:
	if id < 0 or id >= persons.size():
		return null
	return persons[id]


func item(id: int) -> Dictionary:
	if id < 0 or id >= items_db.size():
		return {}
	return items_db[id]


func cls(id: int) -> Dictionary:
	if id < 0 or id >= classes_db.size():
		return {}
	return classes_db[id]


func strategy(id: int) -> Dictionary:
	if id < 0 or id >= strategies_db.size():
		return {}
	return strategies_db[id]


## Class family (0x40bf0c): class <= 59 -> class/3 (20 three-tier families), 60..79 -> class-40, else 40 (none).
func family_of(c: int) -> int:
	if c <= 59:
		return c / 3
	if c <= 79:
		return c - 40
	return 40


func family(f: int) -> Dictionary:
	if f < 0 or f >= families_db.size():
		return {}
	return families_db[f]


func text(index: int) -> String:
	var arr: Array = texts_db.get("texts", [])
	if index < 0 or index >= arr.size():
		return ""
	var v: Variant = arr[index]
	return "" if v == null else str(v)


## Terrain name from the executable's GBK name table (pointers at 0x48bdb0), which scripts may overwrite
## (S_12 renames 大河 to 海洋); the converted names are the fallback.
func terrain_name(t: int) -> String:
	if t < 0 or t >= terrain_names.size():
		return ""
	var p := Mem.r32(0x48bdb0 + 4 * t)
	var b := PackedByteArray()
	for k in 16:
		var c := Mem.r8(p + k)
		if c == 0:
			break
		b.append(c)
	var s := TextExpand.from_gbk(b)
	return s if s != "" else str(terrain_names[t])


## Portrait entry of a person (0x40765c): v = the face table entry 0x50f000[pid]; Face.e5 entry v + 7, or 0 when
## v is 0.
func resolved_face(pid: int) -> int:
	if pid < 0 or pid >= MAX_PERSONS:
		return -1
	var v := Mem.r16(Mem.FACE_TABLE + 2 * pid)
	return v + 7 if v != 0 else 0


## Face.e5 picture (120x120, dialog and status windows); `big` = the Fb.e5 picture (192x272) of the
## three-portrait dialog 0x42d8bf where one differs.
func face_texture(face: int, big := false) -> Texture2D:
	if face < 0:
		return null
	var rel := "gfx/portraits/large/%03d.png" % face
	if big and Assets.exists("gfx/portraits/fb/%03d.png" % face):
		rel = "gfx/portraits/fb/%03d.png" % face
	if not Assets.exists(rel):
		return null
	return Assets.tex(rel)


func person_face(pid: int, small := false) -> Texture2D:
	return face_texture(resolved_face(pid), small)


# ------------------------------------------------------------------ party / inventory
## Party membership = person byte +0x2a (0 = member, 0xff = not) (0x41a190).
func is_member(pid: int) -> bool:
	if pid < 0 or pid >= 1024:
		return false
	return Mem.r8(Mem.person_addr(pid) + 0x2a) == 0


func party_ids() -> Array[int]:
	var out: Array[int] = []
	for p in persons:
		if Mem.r8(p.base + 0x2a) == 0:
			out.append(p.id)
	return out


## Party average level 0x40c231: the mean level of the members (0x42ac58: +0x2a ≠ 0xff) among persons 0..126; 1 when
## there are none or the mean is below 2.
func party_avg_level() -> int:
	var tot := 0
	var n := 0
	for i in 127:
		if is_member(i):
			tot += Mem.r8(Mem.person_addr(i) + 0x2c)
			n += 1
	if n == 0 or tot / n < 2:
		return 1
	return tot / n


## Level code of joins and allies 0x4123c8(code, base, 0): code < 101 → min(base + code, 100); ≥ 101 →
## base − (code − 100) (saturating, 0 → 1); byte arithmetic.
static func level_code(code: int, base: int) -> int:
	if code < 0x65:
		return mini((base & 0xff) + (code & 0xff), 100)
	var d := (code + 0x9c) & 0xff
	var v := (base & 0xff) - d if (base & 0xff) > d else 0
	return 1 if v & 0xff == 0 else v & 0xff


## Class of a person who joins at level T (0x40c2e7): family (0x40bf0c) → base class family·3 (families < 20) or
## family + 40; three-tier classes (base < 59) add 0 / 1 / 2 for T < 15 / 15..29 / ≥ 30.
static func join_class(fam: int, t: int) -> int:
	var c := fam * 3 if fam < 20 else fam + 40
	if c < 59:
		c += 2 if t >= 30 else (1 if t > 14 else 0)
	return c & 0xff


## EEX op 0x3b story part (0x40c2e7): `mode` 0xff = leave (arg 0: a member's equipment goes to the bag first,
## 0x40c436); mode 0 = join (nothing if already a member): reload from DATA.E5 (0x46206c), level 0, class by T, level
## up to T (0x4073f3, silent); mode 1 = keep the record: arg 101 → membership only, else class + level-up only when
## Lv < T; other modes reload like 0. Then the default weapon / armour (0x407fd4 ×2) and membership 0 (0x4095b9).
## T = level_code(arg, party average).
func join(pid: int, mode: int, arg: int) -> void:
	if pid < 0 or pid > 0x3ff:
		return
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("  join pid %d mode %d arg %d (member before: %s)" % [pid, mode, arg, is_member(pid)])
	var p := person(pid)
	if mode == 0xffff or mode & 0xff == 0xff:
		if arg == 0:
			if not is_member(pid):
				return
			for slot in 3:
				take_off(pid, slot, true)
		set_membership(pid, 0xff, mode & 0xff)
		party.erase(pid)
		return
	if mode == 0 and is_member(pid):
		return
	var t := level_code(arg, party_avg_level())
	if mode != 1:
		reload_person(pid)
	var c := join_class(family_of(p.cls), t)
	var skip := false
	if mode == 1:
		if arg == 0x65:
			skip = true
		elif p.level < t:
			p.cls = c
			p.level_up(t - p.level)
	else:
		p.level = 0
		p.cls = c
		p.level_up(t)
	if not skip:
		default_equipment(pid, 0, true)
		default_equipment(pid, 1, true)
	set_membership(pid, 0, mode & 0xff)
	if not party.has(pid):
		party.append(pid)


## Debug / compatibility: join keeping the record (mode 1, arg 101 = membership only) or leave.
func join_party(pid: int, mode := 1, arg := 0x65) -> void:
	join(pid, mode, arg)


func leave_party(pid: int) -> void:
	join(pid, 0xff, 0)


## Reload a person's record from DATA.E5 (0x46206c(pid, 0x32, 0) → 0x41b617(…, 1): the face comes from the face
## table). With EV[4075] and the stage counter u8 0x5083fc the original then adds a growth bonus to the raw abilities
## ([G] not ported: R_072 is the only file that sets EV[4075], around one join).
func reload_person(pid: int) -> void:
	reset_person(pid)
	TextExpand.invalidate()


## 0x4095b9(record, value, mode): membership byte +0x2a = value; when it changes, the join history 0x501800 (count byte,
## ≤ 0x67 × 6 B {u16 person, u8 stage counter, …}) gets the person's entry (appended if new), whose byte +2 takes
## u8 0x5083fc. (Mode 1 also re-reads the person with mode 2 — the EV[4075] growth step only, [G] not ported.)
func set_membership(pid: int, value: int, _mode: int) -> void:
	var a := Mem.person_addr(pid) + 0x2a
	if Mem.r8(a) == value:
		return
	Mem.w8(a, value)
	var k := 0
	while Mem.r8(0x501800) < 0x67 and k < 0x67:
		var e := 0x501801 + 6 * k
		var who := Mem.r16(e)
		if who == pid:
			Mem.w8(e + 2, Mem.r8(0x5083fc))
			return
		if who == 0xffff:
			Mem.w8(0x501800, Mem.r8(0x501800) + 1)
			Mem.w16(e, pid)
			if Mem.r8(0x501800) < 0x67:
				Mem.w16(e + 6, 0xffff)
			Mem.w8(e + 2, Mem.r8(0x5083fc))
			return
		k += 1


## Default equipment 0x407fd4(record, slot, lower): tier = min(Lv / 20, 2); level = Lv < 60 ? (Lv % 20) / 4 + 1 : 5;
## `lower` takes one level off (below 1: tier 0 keeps level 1, else level 5 of the tier below). Weapon: the first of the
## 20 weapon types (0..19) the class may use (0x41c60f), armour: types 20..25; item = table 0x482427[type >> 1] + tier
## (0xff if the class uses none). Exp = 0xff from level 5 on. Slot 2: nothing.
func default_equipment(pid: int, slot: int, lower: bool) -> void:
	if slot > 1:
		return
	var p := person(pid)
	var lv := p.level
	var tier := mini(lv / 20, 2)
	var l := (lv % 20) / 4 + 1 if lv < 60 else 5
	if lower:
		l = l - 1 if l > 1 else 0
		if l < 1:
			if tier == 0:
				l = 1
			else:
				l = 5
				tier -= 1
	var eq: Array = cls(p.cls).get("equip_raw", [])
	var item_id := 0xff
	var t0 := 0 if slot == 0 else 20
	for t in range(t0, t0 + (20 if slot == 0 else 6)):
		if t < eq.size() and int(eq[t]) != 0:
			item_id = (Mem.r8(0x482427 + (t >> 1)) + tier) & 0xff
			break
	var b := p.base + 0x2e + 3 * slot
	Mem.w8(b, item_id)
	Mem.w8(b + 1, l)
	Mem.w8(b + 2, 0 if l < 5 else 0xff)


## Take off 0x406cbc(record, slot, flag): with flag 1 a member's item goes to the bag first (0x419316); then the slot
## is cleared (0x420649).
func take_off(pid: int, slot: int, to_bag: bool) -> void:
	var b := Mem.person_addr(pid) + 0x2e + 3 * slot
	if to_bag and Mem.r8(Mem.person_addr(pid) + 0x2a) == 0:
		bag_put(Mem.r8(b), Mem.r8(b + 1), Mem.r8(b + 2))
	Mem.w8(b, 0xff)
	if slot < 2:
		Mem.w8(b + 1, 0)
		Mem.w8(b + 2, 0)


## Equipment code of op 0x3e (0x412db6 per slot): 0 leaves the slot, 1 takes the item off (to the bag when `wl`, the
## op's weapon-level argument, is 1), else 0x407df1: item = code − 2 + {0, 70, 109} by slot, or with level 0xfe the
## code itself (level 0); the item's category must be the slot; level 0 → automatic for the person's level (0x407da3),
## 0xff kept, otherwise capped at the item's maximum; accessories get level 0xff; exp = 0xff at the maximum (0x4201d5);
## the item is written over the slot (0x41ca49) and recorded (0x408b0d) for members.
func equip_by_code(pid: int, slot: int, code: int, lvl: int, wl := 0) -> void:
	if code == 0:
		return
	if code == 1:
		take_off(pid, slot, wl == 1)
		return
	var iid := code
	if lvl == 0xfe:
		lvl = 0
	else:
		iid = (code - 2 + [0, 70, 109][slot]) & 0xff
	var it := item(iid)
	if it.is_empty() or Person.slot_of(it) != slot:
		return
	var maxl := Person.max_item_level(it)
	if lvl == 0:
		lvl = auto_item_level(iid, person(pid).level)
	elif lvl != 0xff and lvl > maxl:
		lvl = maxl
	var xp := 0 if lvl < maxl else 0xff
	if lvl == 9 and lvl >= maxl:
		xp = 0xfe
	if slot == 2:
		lvl = 0xff
	var b := Mem.person_addr(pid) + 0x2e + 3 * slot
	Mem.w8(b, iid)
	if slot != 2:
		Mem.w8(b + 1, lvl)
		Mem.w8(b + 2, xp)
	if is_member(pid):
		record_item(iid)


## Automatic equipment level 0x407da3(item, Lv): treasures min(Lv / 6 + 1, 9); others Lv ≥ 60 → 5, else
## (Lv % 20) / 4 + 1.
func auto_item_level(iid: int, lv: int) -> int:
	lv &= 0xff
	if Person.is_treasure(item(iid)):
		return mini(lv / 6 + 1, 9)
	if lv >= 60:
		return 5
	return (lv % 20) / 4 + 1


## Class change 0x40e01f + 0x414b93 (a weapon / armour the new class cannot use (0x407961) is replaced by the default
## equipment, 0x407fd4(…, 1); the old item is lost) + with byte EV[4081] ≠ 0 the abilities recomputed (0x4149cf).
func change_class(pid: int, c: int) -> void:
	var p := person(pid)
	p.cls = c
	for slot in 3:
		var iid := Mem.r8(p.base + 0x2e + 3 * slot)
		if not _can_use(p, iid):
			default_equipment(pid, slot, true)
	if Mem.ev(4081) & 0xff != 0:
		recompute_abilities(pid)


## 0x407961(record, item): empty slot → yes; consumable → no; accessory → the family groups (0x420e83); weapons and
## armour → the class's equip flags (0x41c60f).
func _can_use(p: Person, iid: int) -> bool:
	if iid == 0xff:
		return true
	var it := item(iid)
	if it.is_empty():
		return true
	if Person.slot_of(it) == 3:
		return false
	return p.can_equip(iid)


## 0x4149cf(0, record, pid): stats 0..4 = 功勋 bonus (0x41055d) + growth sum (0x408a60) + raw ability; HP / MP =
## promotion bonus 0x413fac (2 · tier · class growth, members of three-tier classes) + growth sum + 功勋 bonus + the
## DATA.E5 value.
func recompute_abilities(pid: int) -> void:
	var p := person(pid)
	var recs: Array = Assets.json("data/persons.json")
	var r: Dictionary = recs[pid] if pid < recs.size() else {}
	for s in 7:
		var gs := p.growth_sum(s)
		var mb := p.merit_bonus(s)
		if s < 5:
			p.set_stat_word(s, (mb + gs + p.get_raw(s)) & 0xffff)
		else:
			var promo := 0
			if p.army != 0xff and p.cls <= 59:
				promo = 2 * (p.cls % 3) * p.growth(s)
			var v := promo + gs + mb
			if s == 5:
				Mem.w16(p.base + 0x1b, (v + int(r.get("hp", 0))) & 0xffff)
			else:
				Mem.w16(p.base + 0x1f, (v + int(r.get("mp", 0))) & 0xffff)


## Item bag in GS: 200 slots × {id, level, exp} at 0x4b0783 (GS+0x13); an empty slot is ff ff ff (0x41606a).
## The 6.6 engine has no item stacks: every item takes a slot.
const BAG := 0x4b0783
const BAG_SLOTS := 200


## Slot of the battle unit holding a person (0x477adc), or -1. PENDING: verify the search order in 0x477adc.
func unit_slot_of_person(pid: int) -> int:
	for s in Mem.UNIT_SLOTS:
		var v := Mem.r16(Mem.unit_addr(s))
		if v != 0xffff and (v & 0xfff) == pid:
			return s
	return -1


func bag_entries() -> Array:
	var out := []
	for i in BAG_SLOTS:
		var a := BAG + 3 * i
		var id := Mem.r8(a)
		if id != 0xff:
			out.append({"slot": i, "id": id, "lvl": Mem.r8(a + 1), "exp": Mem.r8(a + 2)})
	return out


func bag_free_slot() -> int:
	for i in BAG_SLOTS:
		if Mem.r8(BAG + 3 * i) == 0xff:
			return i
	return -1


func init_bag() -> void:
	Mem.fill(BAG, 3 * BAG_SLOTS, 0xff)


## Put an item into the first free bag slot (0x40d693(item, level, exp)); a full bag shows the error box and the
## discard window (0x4301b2) in the original — here the item is dropped with a warning.
func bag_put(id: int, lvl: int, xp: int) -> bool:
	if id == 0xff:
		return false
	var i := bag_free_slot()
	if i < 0:
		push_warning("bag full: item %d dropped" % id)
		return false
	Mem.w8(BAG + 3 * i, id)
	Mem.w8(BAG + 3 * i + 1, lvl)
	Mem.w8(BAG + 3 * i + 2, xp)
	return true


## Compatibility (battle / menus): equipment keeps level and exp, other items 0.
func add_item(id: int, lvl := 1, xp := 0) -> bool:
	var equip := int(item(id).get("category_code", 3)) <= 1
	return bag_put(id, lvl if equip else (0xff if int(item(id).get("category_code", 3)) == 2 else 0), xp if equip else (0xff if int(item(id).get("category_code", 3)) == 2 else 0))


func remove_bag_slot(i: int) -> void:
	Mem.fill(BAG + 3 * i, 3, 0xff)


## Consumable counts (items ≥ 0xa0): u8 table 0x493af0 + (item − 0xa0), changed by 0x420299 (cl = 0: +1 unless 0xff,
## cl ≠ 0: −1 if ≥ 1).
const CONSUMABLES := 0x493af0


func consumable_count(id: int) -> int:
	if id < 0xa0:
		return 0
	return Mem.r8(CONSUMABLES + id - 0xa0)


## 0x43e093: n × 0x420299(item, 0).
func consumable_add(id: int, n: int) -> void:
	if id < 0xa0:
		return
	var a := CONSUMABLES + id - 0xa0
	for k in n:
		if Mem.r8(a) != 0xff:
			Mem.w8(a, Mem.r8(a) + 1)


## Op 0x6f 丢弃物品 (0x40c603): item < 0xa0: the bag (low byte compared) then the members' slots +0x2e / +0x31 / +0x34
## of persons 0..0x3ff; the item byte becomes 0xff unless byte EV[4067] ≠ 0 (test only); 0x418096: EV[4068] = holder
## (0x400 = bag, else the person), EV[4069] / EV[4070] = the two bytes after the item byte (level / exp; for an
## accessory slot these are the kill-count bytes). item ≥ 0xa0: its count − 1 if ≥ 1 (0x420299). Not found or a
## consumable → EV[4068] = 0x401.
func lose_item(id: int) -> void:
	if id < 0xa0:
		var test_only := Mem.ev(4067) & 0xff != 0
		for i in BAG_SLOTS:
			var a := BAG + 3 * i
			if Mem.r8(a) == (id & 0xff):
				if not test_only:
					Mem.w8(a, 0xff)
				_holder(0x400, a)
				return
		for pid in 0x400:
			var base := Mem.person_addr(pid)
			if Mem.r8(base + 0x2a) != 0:
				continue
			for off in [0x2e, 0x31, 0x34]:
				if Mem.r8(base + off) == (id & 0xff):
					if not test_only:
						Mem.w8(base + off, 0xff)
					_holder(pid, base + off)
					return
	else:
		var c := CONSUMABLES + id - 0xa0
		if Mem.r8(c) >= 1:
			Mem.w8(c, Mem.r8(c) - 1)
	Mem.set_ev(4068, 0x401)


func _holder(who: int, a: int) -> void:
	Mem.set_ev(4068, who)
	Mem.set_ev(4069, Mem.r8(a + 1))
	Mem.set_ev(4070, Mem.r8(a + 2))


## Compatibility for the menus: remove one item of this id (bag first, then the members' equipment).
func remove_item_id(id: int) -> bool:
	for i in BAG_SLOTS:
		if Mem.r8(BAG + 3 * i) == id:
			remove_bag_slot(i)
			return true
	for pid in party_ids():
		var p := person(pid)
		if p.weapon == id:
			p.weapon = -1
			return true
		if p.armor == id:
			p.armor = -1
			return true
		if p.accessory == id:
			p.accessory = -1
			return true
	return false


func has_item(id: int) -> bool:
	for i in BAG_SLOTS:
		if Mem.r8(BAG + 3 * i) == id:
			return true
	for pid in party_ids():
		var p := person(pid)
		if p.weapon == id or p.armor == id or p.accessory == id:
			return true
	return false


## Item record 0x408b0d: an item < 0xff whose record byte +0x18 has bit 0 set is noted in SV\SV.E5S (byte item + 0x10,
## 0x41a1c6) — the collection record that outlives the playthrough.
func record_item(id: int) -> void:
	if id >= 0xff:
		return
	if int(item(id).get("unk_18", 0)) & 1:
		SpecialFuncs.sv_write(id + 0x10, 1)


## Width-aware store used by the PT patch records (u8 width 1 = byte, 2 = word, else dword).
static func write_width(addr: int, v: int, w: int) -> void:
	match w:
		1: Mem.w8(addr, v)
		2: Mem.w16(addr, v)
		_: Mem.w32(addr, v)


## After a load the original re-applies the PT[200..480] patches (0x417020(1) → 0x42913f): the recorded value goes to
## the address in PT[i] with the recorded width.
func reapply_pt_patches() -> void:
	for i in range(200, 481):
		var a := Mem.pt(i)
		if a != 0:
			write_width(a, Mem.r32(0x506464 + 4 * i), Mem.r8(0x506f84 + i))


# ------------------------------------------------------------------ variables
func get_flag(i: int) -> bool:
	return Mem.flag(i)


func set_flag(i: int, v: bool) -> void:
	Mem.set_flag(i, v)


func get_ivar(kind: int, i: int) -> int:
	return int(ivars.get("%d:%d" % [kind, i], 0))


func set_ivar(kind: int, i: int, v: int) -> void:
	ivars["%d:%d" % [kind, i]] = v


# ------------------------------------------------------------------ save / load
const SAVE_VERSION := 1
const AUTO_SLOT := -1          # the autosave (继续游戏), a file of its own beside the numbered slots


func save_path(slot: int) -> String:
	if slot == AUTO_SLOT:
		return "user://autosave.json"
	return "user://save_%02d.json" % slot


## Small summary next to each save so the slot list does not have to parse whole saves.
func _info_path(slot: int) -> String:
	if slot == AUTO_SLOT:
		return "user://autosave.info.json"
	return "user://save_%02d.info.json" % slot


## Write `text` to `path` through a temporary file, so a crash mid-write cannot destroy the old file.
static func _write_atomic(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	if f.get_error() != OK:
		return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) == OK


func save_game(slot: int, extra: Dictionary = {}) -> bool:
	return write_capture(slot, capture_save(extra))


## The current state as save text, taken now (so later changes do not leak in) and written by write_capture.
func capture_save(extra: Dictionary = {}) -> Dictionary:
	var info := {
		"version": SAVE_VERSION,
		"time": Time.get_datetime_string_from_system(),
		"scenario": scenario,
		"chapter_title": chapter_title,
	}
	var d := info.duplicate()
	d.merge({
		"play_time": play_time,
		"party": party,
		"inventory": inventory,
		"ivars": ivars,
		"mem": Mem.snapshot(),
		"extra": extra,
	})
	return {"data": JSON.stringify(d), "info": JSON.stringify(info)}


func write_capture(slot: int, cap: Dictionary) -> bool:
	if not _write_atomic(save_path(slot), cap["data"]):
		return false
	_write_atomic(_info_path(slot), cap["info"])
	return true


func delete_save(slot: int) -> void:
	for p in [save_path(slot), _info_path(slot)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func save_info(slot: int) -> Dictionary:
	var p := save_path(slot)
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = null
	if FileAccess.file_exists(_info_path(slot)) \
			and FileAccess.get_modified_time(_info_path(slot)) >= FileAccess.get_modified_time(p):
		d = JSON.parse_string(FileAccess.get_file_as_string(_info_path(slot)))
	if not d is Dictionary:
		d = read_save(slot)
		if d == null:
			return {}
	return {"time": d.get("time", ""), "scenario": d.get("scenario", 0), "chapter_title": d.get("chapter_title", "")}


## The parsed save in `slot`, or null if it is missing, damaged or from a newer version of the game.
func read_save(slot: int) -> Variant:
	var p := save_path(slot)
	if not FileAccess.file_exists(p):
		return null
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not d is Dictionary or int(d.get("version", 0)) > SAVE_VERSION:
		return null
	for k in ["mem", "party", "inventory", "ivars", "scenario"]:
		if not d.has(k):
			return null
	return d


## Load the save in `slot`; returns its stage state ("extra"), or null (and changes nothing) if the save
## cannot be read.
func load_game(slot: int) -> Variant:
	var d: Variant = read_save(slot)
	if d == null:
		return null
	chapter_title = str(d.get("chapter_title", ""))
	play_time = float(d.get("play_time", 0))
	party.clear()
	for x in d["party"]:
		party.append(int(x))
	inventory = d["inventory"]
	ivars = d["ivars"]
	Mem.restore(d["mem"])
	reapply_pt_patches()
	TextExpand.invalidate()
	for p in persons:
		p.name = TextExpand.full_name(p.id)
	scenario = int(d["scenario"])
	return d.get("extra", {})


# ------------------------------------------------------------------ 历史情报 records (op 0x16 with EV[4071])
const HISTORY := 0x509000          # records "&" + colour byte + text, NUL-terminated, back to back
const HISTORY_END := 0x50dc00
const HISTORY_LEN := 0x508994      # u32 byte length


## Op 0x16 with EV[4071] ≠ 0 (0x413a35): low byte 255 → edit / delete the record with the text's leading number
## (0x47826a: text = only the number → the record is removed, else its text is replaced; nothing if absent or the
## buffer is empty); otherwise append "&" + colour + the expanded text (`*/N` stays unexpanded while EV[4071] ≠ 0) when
## it fits below 0x50dc00. An open history window refreshes (0x41c21c).
func history_add(cat: int, raw: String) -> void:
	var n := Mem.r32(HISTORY_LEN)
	if cat & 0xff == 0xff:
		if n != 0:
			_history_edit(TextExpand.gbk(raw))
		history_changed.emit()
		return
	if HISTORY + n >= HISTORY_END:
		return
	var body := TextExpand.expand_bytes(TextExpand.gbk(raw))
	Mem.w8(HISTORY + n, 0x26)
	Mem.w8(HISTORY + n + 1, cat & 0xff)
	for i in body.size():
		Mem.w8(HISTORY + n + 2 + i, body[i])
	Mem.w8(HISTORY + n + 2 + body.size(), 0)
	Mem.w32(HISTORY_LEN, n + body.size() + 2)
	history_changed.emit()


signal history_changed


static func _lead_number(b: PackedByteArray, p: int) -> Array:
	var v := 0
	var k := 0
	while p + k < b.size() and b[p + k] >= 0x30 and b[p + k] <= 0x39:
		v = v * 10 + b[p + k] - 0x30
		k += 1
	return [v, k]


func _history_bytes() -> PackedByteArray:
	var n := Mem.r32(HISTORY_LEN)
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[i] = Mem.r8(HISTORY + i)
	return b


## 0x47826a: records are "&" + colour + text back to back (no NULs between them; one NUL after the last). Find the
## record whose text starts with the same number as `t`; a `t` that is only the number removes the record (with its
## two header bytes), otherwise `t` replaces the record's text.
func _history_edit(t: PackedByteArray) -> void:
	var want: Array = _lead_number(t, 0)
	var buf := _history_bytes()
	var p := 0
	while p + 2 <= buf.size():
		var start := p + 2
		var end := start
		while end < buf.size() and buf[end] != 0x26 and buf[end] != 0:
			end += 1
		if int(_lead_number(buf, start)[0]) == int(want[0]):
			var out: PackedByteArray
			if t.size() == int(want[1]):
				out = buf.slice(0, p) + buf.slice(end)
			else:
				out = buf.slice(0, start) + t + buf.slice(end)
			_history_store(out)
			return
		p = end
		if p < buf.size() and buf[p] != 0x26:
			return


func _history_store(b: PackedByteArray) -> void:
	var old := Mem.r32(HISTORY_LEN)
	for i in b.size():
		Mem.w8(HISTORY + i, b[i])
	for i in range(b.size(), maxi(old, b.size()) + 1):
		Mem.w8(HISTORY + i, 0)
	Mem.w32(HISTORY_LEN, b.size())


## The records in buffer order: [{colour, number, text}] (text with its `*` escapes).
func history_entries() -> Array:
	var out := []
	var buf := _history_bytes()
	var p := 0
	while p + 2 <= buf.size() and buf[p] == 0x26:
		var col := buf[p + 1]
		var start := p + 2
		var end := start
		while end < buf.size() and buf[end] != 0x26 and buf[end] != 0:
			end += 1
		var txt := buf.slice(start, end)
		var num: Array = _lead_number(txt, 0)
		out.append({"colour": col, "number": int(num[0]) if int(num[1]) > 0 else -1,
			"text": TextExpand.from_gbk(txt)})
		p = end
	return out


# ------------------------------------------------------------------ names / text
## Speaker / name lookup 0x44deef (see TextExpand).
func person_id_by_name(n: String) -> int:
	return TextExpand.person_by_name(n)


## Display name of a person as the engine prints it (GetName 0x407775, renames included).
func display_name(pid: int) -> String:
	return TextExpand.display_name(pid)


## Text expansion 0x417df6 (`*` escapes).
func substitute_names(s: String) -> String:
	return TextExpand.expand(s)


# ------------------------------------------------------------------ resources (EEX 0x3a / 0x37)
## Op 0x37 (0x4118bd): kind 0 gold GS+0xc (0x40e1d0), 1 = min(GS+6 / 2, 127) (0x415e13: the current file number),
## 2 忠奸 GS+0x12 (0x40687a).
func get_resource(kind: int) -> int:
	match kind & 0xffff:
		0: return gold
		1: return mini(Mem.r16(Mem.GS + 6) >> 1, 127)
		2: return Mem.r8(Mem.GS + 0x12)
	return 0


## Op 0x3a (0x41481f) without the gauge: kind 0 gold op 0 set (≤ 999,999, 0x40e1a4), 1 add (capped, 0x40da71), 2 sub
## (saturating, 0x40d7ee); kind 1 → u8 0x510cf9 (chapter byte) = v; kind 2 op 0 → GS+0x12 = min(v, 100) (0x418cb3).
func change_resource(kind: int, op: int, v: int) -> void:
	v &= 0xffffffff
	match kind & 0xff:
		0:
			match op & 0xff:
				0: Mem.w32(Mem.GS + 0xc, mini(v, 999999))
				1: Mem.w32(Mem.GS + 0xc, mini(gold + v, 999999))
				2: Mem.w32(Mem.GS + 0xc, 0 if v > gold else gold - v)
		1:
			Mem.w8(0x510cf9, v & 0xff)
		2:
			if op & 0xff == 0:
				Mem.w8(Mem.GS + 0x12, mini(v, 100))


## 忠奸 add / sub with the gauge (0x40d3bc(v, sub)): add: v + cur ≥ 101 → v = 100 − cur (saturating); sub: v > cur →
## v = cur; the gauge steps 5 times, then GS+0x12 = cur ± v.
func loyalty_change(v: int, sub: int, ui_layer: Node) -> void:
	var cur := Mem.r8(Mem.GS + 0x12)
	if sub == 1:
		if v > cur:
			v = cur
	else:
		if v + cur >= 0x65:
			v = 100 - cur if 100 > cur else 0
	var nv := (cur - v if sub == 1 else cur + v) & 0xff
	if ui_layer != null and ui_layer.has_method("loyalty_gauge"):
		await ui_layer.loyalty_gauge(cur, nv)
	Mem.w8(Mem.GS + 0x12, nv)


## Comparison mode (tag 0x24, ops 0x3f/0x41/0x36/0x37): 0 → a >= b, 1 → a < b, other → a == b.
func compare(a: int, b: int, cmp: int) -> bool:
	match cmp:
		0: return a >= b
		1: return a < b
	return a == b
