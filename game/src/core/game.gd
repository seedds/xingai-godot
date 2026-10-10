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
	var s := b.get_string_from_multibyte_char("GBK") if not b.is_empty() else ""
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


## Average level of party members among persons 0..25 (0x40c14f).
## 0x40c14f: average level of the 15 highest-levelled party members among persons 0..25 (at least 1).
func party_avg_level() -> int:
	var lv: Array[int] = []
	for i in 26:
		if is_member(i):
			lv.append(person(i).level)
	if lv.is_empty():
		return 1
	lv.sort()
	lv.reverse()
	lv = lv.slice(0, 15)
	var tot := 0
	for v in lv:
		tot += v
	return maxi(tot / lv.size(), 1)


## EEX op 0x3b (0x40c28c): mode 0 = join, levelled to min(avg+arg, 70) with class tier by level
## (>=40 top tier, >=20 middle tier); mode 1 = join as is; mode 0xff/0xffff = leave (equipment to bag).
func join_party(pid: int, mode := 1, arg := 0xff) -> void:
	if pid < 0 or pid >= 1024:
		return
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("  join pid %d mode %d arg %d (member before: %s)" % [pid, mode, arg, is_member(pid)])
	var p := person(pid)
	if mode == 0xff or mode == 0xffff:
		if is_member(pid):
			for e in [[p.weapon, p.weapon_lvl], [p.armor, p.armor_lvl], [p.accessory, 0]]:
				if e[0] >= 0:
					add_item(e[0], maxi(e[1], 1))
			p.weapon = -1
			p.armor = -1
			p.accessory = -1
			Mem.w8(p.base + 0x2a, 0xff)
		return
	if is_member(pid):
		return
	if mode == 0 and arg <= 99:
		var target := mini(party_avg_level() + arg, 70)
		if p.level < target:
			p.level_up(target - p.level)
		if p.cls <= 38:
			var tier := 2 if p.level >= 40 else (1 if p.level >= 20 else 0)
			p.cls = (p.cls / 3) * 3 + tier
	Mem.w8(p.base + 0x2a, 0)
	if not party.has(pid):
		party.append(pid)


func leave_party(pid: int) -> void:
	join_party(pid, 0xff)
	party.erase(pid)


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


func add_item(id: int, lvl := 1, xp := 0) -> bool:
	var i := bag_free_slot()
	if i < 0:
		return false
	var equip := int(item(id).get("category_code", 3)) <= 1
	Mem.w8(BAG + 3 * i, id)
	Mem.w8(BAG + 3 * i + 1, lvl if equip else 0)
	Mem.w8(BAG + 3 * i + 2, xp if equip else 0)
	return true


func remove_bag_slot(i: int) -> void:
	Mem.fill(BAG + 3 * i, 3, 0xff)


## Remove one item: the bag first, then party members' equipment. PENDING: check against op 0x3f's handler.
func remove_item_id(id: int) -> bool:
	for i in BAG_SLOTS:
		if Mem.r8(BAG + 3 * i) == id:
			remove_bag_slot(i)
			return true
	for p in persons:
		if not is_member(p.id):
			continue
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
		"history": history,
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
	history.clear()
	for h in d.get("history", []):
		if h is Dictionary:
			history.append(h)
		else:
			add_history(1, str(h))      # saves before the categories: "<number><text>"
	Mem.restore(d["mem"])
	scenario = int(d["scenario"])
	return d.get("extra", {})


# ------------------------------------------------------------------ chronicle (史录)
## An entry of the mod's chronicle (op 0x16 with EV[4095] = category): the text starts with the entry
## number. Category 0xff replaces the entry with that number (0x4d1679); otherwise a number that is
## already there is not added again.
func add_history(cat: int, text: String) -> void:
	var n := 0
	while n < text.length() and text[n] >= "0" and text[n] <= "9":
		n += 1
	var id := int(text.substr(0, n)) if n > 0 else -1
	var e := {"id": id, "cat": cat, "text": text.substr(n)}
	for i in history.size():
		if id >= 0 and int(history[i]["id"]) == id:
			if cat == 0xff:
				e["cat"] = history[i]["cat"]
				history[i] = e
			return
	if cat == 0xff:
		e["cat"] = 1
	history.append(e)


# ------------------------------------------------------------------ names / text
func person_id_by_name(n: String) -> int:
	return int(_name_index.get(n, -1))


## Text substitution hook (engine 0x4179a5). Plain pass-through for now.
func substitute_names(s: String) -> String:
	return s


# ------------------------------------------------------------------ resources (EEX 0x3a / 0x37)
## kind 0 = gold (GS+0xc), kind 2 = 0..100 value at GS+0x12, kind 1 = byte GS+6 (0x418c70).
func get_resource(kind: int) -> int:
	match kind:
		0: return gold
		1: return Mem.r8(Mem.GS + 6)
		2: return Mem.r8(Mem.GS + 0x12)
	return 0


## op: 0 set, 1 add, 2 subtract.
func change_resource(kind: int, op: int, v: int) -> void:
	match kind:
		0:
			match op:
				0: gold = v
				1: gold = gold + v
				2: gold = 0 if v > gold else gold - v
		1:
			Mem.w8(Mem.GS + 6, v)
		2:
			var cur := Mem.r8(Mem.GS + 0x12)
			match op:
				0: cur = v if v <= 100 else cur
				1: cur = mini(cur + v, 100)
				2: cur = maxi(cur - v, 0)
			Mem.w8(Mem.GS + 0x12, cur)


## Comparison mode (tag 0x24, ops 0x3f/0x41/0x36/0x37): 0 → a >= b, 1 → a < b, other → a == b.
func compare(a: int, b: int, cmp: int) -> bool:
	match cmp:
		0: return a >= b
		1: return a < b
	return a == b
