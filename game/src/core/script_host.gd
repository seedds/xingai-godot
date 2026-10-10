class_name ScriptHost
extends Node
## Opcode handlers shared by story (R) and battle (S) scripts. Stages extend this.
## Handler naming: op_<name>(ins) where name comes from tools/eex.py; tests return bool.

signal finished

var vm: EexVM
var ui: GameUI
var choice_result := 0
var result_value := 0
var fast := false


func _ready() -> void:
	ui = Game.main.ui


## Touch shell: true while the scene waits at its top level, where its 菜单 button opens the system menu.
func menu_ready() -> bool:
	return false


func open_menu() -> void:
	pass


# ------------------------------------------------------------------ argument helpers
## Integer argument with the mod's EV indirection resolved ({"var": n} -> EV[n]).
func arg(ins: Dictionary, i: int) -> int:
	var a: Array = ins["args"]
	if i >= a.size():
		return 0
	var v: Variant = a[i]
	if v is Dictionary:
		return Mem.ev(int(v.get("var", 0)))
	if v is String:
		return 0
	return int(v)


func sarg(ins: Dictionary, i: int) -> String:
	var a: Array = ins["args"]
	return str(a[i]) if i < a.size() else ""


## Signed 16-bit view (0xffff -> -1) for person/unit args.
func arg16(ins: Dictionary, i: int) -> int:
	var v := arg(ins, i)
	if v >= 0x8000 and v <= 0xffff:
		v -= 0x10000
	return v


# ------------------------------------------------------------------ flow control
func op_comment(_ins: Dictionary) -> bool:
	return true


func op_else(_ins: Dictionary) -> bool:
	return true


func op_nop(_ins: Dictionary) -> void:
	pass


func op_exit_section(_ins: Dictionary) -> void:
	pass


func op_next_scene(_ins: Dictionary) -> void:
	pass


func op_rewind(_ins: Dictionary) -> void:
	pass


func op_goto_scenario(ins: Dictionary) -> void:
	# GS+7 = arg; the file ends and scenario arg+1 is loaded next
	Game.scenario = arg(ins, 0)
	Mem.w8(Mem.GS + 7, Game.scenario)
	Game.scenario_jumped = true


func op_set_result(ins: Dictionary) -> void:
	result_value = arg(ins, 0)


# ------------------------------------------------------------------ flags & variables
func op_set_flag(ins: Dictionary) -> void:
	Mem.set_flag(arg(ins, 0), arg(ins, 1) != 0)


func op_test_flags(ins: Dictionary) -> bool:
	var a: Array = ins["args"]
	for f in a[0]:
		if not Mem.flag(int(f)):
			return false
	for f in a[1]:
		if Mem.flag(int(f)):
			return false
	return true


func op_clear_flags(_ins: Dictionary) -> void:
	for i in 256:
		Mem.set_flag(i, false)
	Mem.fill(0x569f00, 115, 0)
	Mem.w16(0x55ac06, 0)
	Mem.w32(0x55e9d4, 1)


func _src_value(kind: int, v: int) -> int:
	match kind:
		0: return v & 0xffffffff
		1: return Mem.r32(Mem.pt(v))
		2: return Mem.pt(v)
		3: return Mem.PT + 4 * v
		4: return Mem.ev(v)
		5: return Mem.EV + 4 * v
	return 0


func op_int_var_op(ins: Dictionary) -> void:
	var dk := arg(ins, 0)
	var di := arg(ins, 1)
	var opn := arg(ins, 2)
	var sk := arg(ins, 3)
	var sv := arg(ins, 4)
	var dst := 0
	match dk:
		0: dst = Mem.pt(di)
		1: dst = Mem.PT + 4 * di
		2: dst = Mem.EV + 4 * di
	var src := _src_value(sk, sv)
	var cur := Mem.r32(dst)
	var res := cur
	match opn:
		0: res = cur + src
		1: res = cur - src if cur > src else 0
		2: res = src
		3: res = cur * src
		4: res = cur / src if src != 0 else cur
		5: res = cur % src if src != 0 else cur
	Mem.w32(dst, res & 0xffffffff)
	_after_poke(dst)


## Hook for stages to react to raw memory writes (e.g. redraw units).
func _after_poke(_addr: int) -> void:
	pass


## Hook after op 0x78 wrote a field (stages refresh sprites/HP bars).
func on_field_written(_field: int, _id: int) -> void:
	pass


func op_test_int_var(ins: Dictionary) -> bool:
	var a := _src_value(arg(ins, 0), arg(ins, 1))
	var b := _src_value(arg(ins, 3), arg(ins, 4))
	match arg(ins, 2):
		0: return a == b
		1: return a >= b
		2: return a < b
	return false


func op_set_byte_var(ins: Dictionary) -> void:
	Mem.w8(Mem.BYTEVARS + arg(ins, 0), arg(ins, 1))
	_after_poke(Mem.BYTEVARS + arg(ins, 0))


func op_set_4ce004(ins: Dictionary) -> void:
	Mem.w32(0x4ce004, arg(ins, 0))


func op_copy_person_byte(ins: Dictionary) -> bool:
	var off := arg(ins, 2)
	if off >= Mem.PERSON_SIZE:
		return false
	Mem.w8(Mem.person_addr(arg(ins, 1)) + off, Mem.r8(Mem.person_addr(arg(ins, 0)) + off))
	return true


func op_test_random(ins: Dictionary) -> bool:
	return Rules.chance(mini(arg(ins, 0), 100))


func op_data_transfer(ins: Dictionary) -> void:
	DataTransfer.run(self, ins)


# ------------------------------------------------------------------ timing / screen
func wait(sec: float) -> void:
	if fast or sec <= 0 or Game.autoplay:
		return
	await get_tree().create_timer(sec).timeout


## delay unit = 100 ms (ticks = GetTickCount/50, delay n waits 2n ticks: 0x42c522).
func op_delay(ins: Dictionary) -> void:
	await wait(arg(ins, 0) * 0.1)


func op_wait_frame(_ins: Dictionary) -> void:
	await get_tree().process_frame


func op_fade_out(_ins: Dictionary) -> void:
	# CCZ naming: 淡出 = fade the screen IN from black (scene appears)
	await ui.fade_from_black()


func op_fade_in(_ins: Dictionary) -> void:
	await ui.fade_to_black()


# ------------------------------------------------------------------ audio
## op 0x23 (parser name "play_music") is really the sound-effect player.
func op_play_music(ins: Dictionary) -> void:
	SoundMap.play_se_id(arg(ins, 0), arg(ins, 1))


## op 0x24 (parser name "play_sound") is really the BGM (CD track id+2) player.
func op_play_sound(ins: Dictionary) -> void:
	SoundMap.play_bgm_id(arg(ins, 0))


# ------------------------------------------------------------------ text
## Resolve a speaker name to a person id (first person with that name; -1 if none).
func person_by_name(n: String) -> int:
	return Game.person_id_by_name(n)


func speaker_face(pid: int) -> Texture2D:
	if pid < 0:
		return null
	return Game.person(pid).face_tex()


## "&Name\ntext\ntext&Name2\ntext" -> boxes
func parse_dialog(s: String) -> Array:
	var boxes := []
	s = Game.substitute_names(s)
	if not s.begins_with("&"):
		boxes.append({"name": "", "text": s})
		return boxes
	for seg in s.split("&", false):
		var nl := seg.find("\n")
		var nm := seg if nl < 0 else seg.substr(0, nl)
		var tx := "" if nl < 0 else seg.substr(nl + 1)
		boxes.append({"name": nm, "text": tx.strip_edges(false, true)})
	return boxes


func show_dialog(s: String, top_hint := -1) -> void:
	for b in parse_dialog(s):
		var pid := person_by_name(b["name"]) if b["name"] != "" else -1
		var top := _dialog_top(pid) if top_hint < 0 else top_hint == 1
		await on_speaker(pid)
		await ui.dialog.talk(speaker_face(pid), b["name"], b["text"], top)


## Stages override to choose top/bottom placement from the speaker's screen position.
func _dialog_top(_pid: int) -> bool:
	return false


## Stages override to e.g. highlight/scroll to the speaking unit.
func on_speaker(_pid: int) -> void:
	pass


func op_dialog(ins: Dictionary) -> void:
	await show_dialog(sarg(ins, 0))


## op 0x16 (0x413a57): a message box, unless EV[4095] (u32 @0x55effc) is set: then the mod adds the text
## to its chronicle (史录) with that category instead of showing it. EV[4095] is cleared either way.
func op_info(ins: Dictionary) -> void:
	var t := Game.substitute_names(sarg(ins, 0))
	var cat := Mem.r32(0x55effc)
	Mem.w32(0x55effc, 0)
	if cat != 0:
		Game.add_history(cat & 0xff, t)
		return
	await ui.dialog.talk(null, "", t, false)


## op 0x69 (0x413a05 → 0x4335d0): "|name" shows the mod's special-technique banner (0x4d6366),
## other text a message box.
func op_popup(ins: Dictionary) -> void:
	var t := Game.substitute_names(sarg(ins, 0))
	if t.begins_with("|"):
		await ui.skill_banner(t.substr(1))
		return
	await ui.popup(t)


func op_choice(ins: Dictionary) -> void:
	var opts := sarg(ins, 0).split("\n", false)
	var clean: Array = []
	for o in opts:
		clean.append(o)
	var i := await ui.menu.choose(clean, Vector2(-1, -1), false)
	choice_result = i + 1


func op_test_choice(ins: Dictionary) -> bool:
	return choice_result == arg(ins, 0)


func op_test_yes_no(ins: Dictionary) -> bool:
	var i := await ui.menu.choose(["是", "否"], Vector2(-1, -1), false, "可以吗？")
	var ans := 1 if i == 0 else 0
	return ans == arg(ins, 0)


func op_chapter_title(ins: Dictionary) -> void:
	Game.chapter_title = sarg(ins, 1)
	await ui.chapter_title(arg(ins, 0), sarg(ins, 1))


func op_title_text(ins: Dictionary) -> void:
	await ui.banner(sarg(ins, 0), 0)


func op_place_name(ins: Dictionary) -> void:
	await ui.banner(sarg(ins, 0), 1)


func op_caption(ins: Dictionary) -> void:
	await ui.caption(sarg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3))


# ------------------------------------------------------------------ party / items / money
func op_join(ins: Dictionary) -> void:
	Game.join_party(arg(ins, 0) & 0xffff, arg(ins, 1) & 0xffff, arg(ins, 2) & 0xffff)


## op 0x3d (0x4143c2): item (ids above 0x67 ignored), level (0 / 0xffff = by the party's level,
## 0x40c14f), flag, person. A weapon or armour at its maximum level comes fully grown. Outside a battle
## the original always says what was found (message style 2); in a battle only when the flag is set.
func op_get_item(ins: Dictionary) -> void:
	var iid := arg(ins, 0)
	if iid > 0x67:
		return
	var it := Game.item(iid)
	var lvl := arg(ins, 1)
	if lvl == 0xffff:
		lvl = 0
	var xp := 0
	if Person.slot_of(it) < 2:
		var maxl := 10 if bool(it.get("treasure", false)) else 3
		if lvl == 0:
			lvl = Person.auto_level_at(it, Game.party_avg_level())
		if lvl >= maxl:
			lvl = maxl
			xp = 0xff
	Game.add_item(iid, maxi(lvl, 1), xp)
	if not in_battle() or arg16(ins, 2) != 0:
		await ui.popup("得到了%s。" % str(it.get("name", "?")))
	if int(it.get("unk_18", 0)) != 0:
		SpecialFuncs.write_niuniu(iid + 3, 1)


func op_lose_item(ins: Dictionary) -> bool:
	return Game.remove_item_id(arg(ins, 0))


func op_set_resource(ins: Dictionary) -> void:
	Game.change_resource(arg(ins, 0), arg(ins, 1), arg(ins, 2))


func op_test_resource(ins: Dictionary) -> bool:
	return Game.compare(Game.get_resource(arg(ins, 0)), arg(ins, 1), arg(ins, 2))


## op 0x3e (0x416319): equipment codes as in Person.equip_code (0xffff → 0), 0 leaves the slot alone.
## In a battle the person must be on the field and codes above 0x67 are ignored (0x4429f9); outside a
## battle a weapon code of 1 takes off every slot that has a code (the original tests the weapon code
## for all three).
func op_set_equipment(ins: Dictionary) -> void:
	var pid := arg(ins, 0)
	var p := Game.person(pid)
	if p == null or pid > 0x3ff:
		return
	var codes := [arg(ins, 1), arg(ins, 3), arg(ins, 5)]
	var lvls := [arg(ins, 2), arg(ins, 4), 0xff]
	for i in 3:
		if codes[i] == 0xffff: codes[i] = 0
		if lvls[i] == 0xffff: lvls[i] = 0
	var battle := in_battle()
	if battle and DataTransfer.unit_slot_of(pid) < 0:
		return
	for i in 3:
		var c: int = codes[i]
		if c == 0 or (battle and c > 0x67):
			continue
		p.equip_code(i, 1 if not battle and codes[0] == 1 else c, lvls[i] & 0xff)
	on_field_written(0x2e, pid)


## Stages override: true in a battle (0x40b922).
func in_battle() -> bool:
	return false


func op_special_func(ins: Dictionary) -> void:
	SpecialFuncs.run(self, arg(ins, 0))


# ------------------------------------------------------------------ sortie parameters (ops 0x06 / 0x4a)
const SORTIE_MAX := 0x4b09ec     # u8 max units
const SORTIE_FORCED := 0x4b09f0  # u32[9] forced persons (0/0xffff = none)
const SORTIE_FLAGS := 0x4b0a04   # u32[9]; all non-zero → protagonist sorties (overlaps forced[5..8])


## op 0x06 (story file): store sortie parameters for the next battle (0x415b45).
func op_battle_select_units(ins: Dictionary) -> void:
	var n := arg(ins, 1)
	for k in 5:
		Mem.w32(SORTIE_FORCED + 4 * k, arg(ins, 2 + k))
	for k in 5:
		Mem.w32(SORTIE_FLAGS + 4 * k, arg(ins, 7 + k))
	Mem.w8(SORTIE_MAX, 1 if n == 0 else n)


## Sortie list builder (0x41856a): forced persons that are party members (5 from op 0x06 / 0x4a)
## first; the protagonist is included when all 9 dwords at 0x4b0a04 are non-zero; if the stored max
## exceeds that count the player picks the rest. Writes the 0x48b350 list. Returns false if empty.
func build_sortie() -> bool:
	var forced: Array[int] = []
	var all_flags := true
	for k in 9:
		if Mem.r32(SORTIE_FLAGS + 4 * k) == 0:
			all_flags = false
	if all_flags:
		forced.append(0)
	for k in 9:
		var f := Mem.r32(SORTIE_FORCED + 4 * k)
		if f != 0 and f != 0xffff and f < 0x400 and Game.is_member(f) and not forced.has(f):
			forced.append(f)
	var maxn := Mem.r8(SORTIE_MAX)
	if maxn < forced.size():
		maxn = forced.size()
		Mem.w8(SORTIE_MAX, maxn)
	var lst: Array[int] = forced
	if maxn != forced.size():
		lst = await SortieScreen.choose(ui, self, maxn, forced, [])
	if lst.is_empty() and Game.is_member(0):
		lst.append(0)
	for k in lst.size():
		Mem.w32(0x48b350 + 4 * k, lst[k])
	Mem.w32(0x48b350 + 4 * lst.size(), 0xffff)
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("  sortie forced=%s max=%d -> %s" % [forced, maxn, lst])
	return not lst.is_empty()


## op 0x07 (0x415c46): true once after the player chose 出征 (flag 0x4ae4c0), which is then cleared.
func op_test_pending(_ins: Dictionary) -> bool:
	if Mem.r32(0x4ae4c0) != 0:
		Mem.w32(0x4ae4c0, 0)
		return true
	return false


## op 0x52: change a person's class; equipment the new class cannot use goes back to the bag.
func op_op_52(ins: Dictionary) -> void:
	var pid := arg(ins, 0)
	var p := Game.person(pid)
	if p == null:
		return
	p.cls = arg(ins, 1)
	var eq: Array = Game.cls(p.cls).get("equip_raw", [])
	if p.weapon >= 0:
		var t := int(Game.item(p.weapon).get("type", 0))
		if t < eq.size() and int(eq[t]) == 0:
			Game.add_item(p.weapon, p.weapon_lvl)
			p.weapon = -1
	if p.armor >= 0:
		var t2 := int(Game.item(p.armor).get("type", 0))
		if t2 < eq.size() and int(eq[t2]) == 0:
			Game.add_item(p.armor, p.armor_lvl)
			p.armor = -1
	on_field_written(17, pid)


## op 0x4b outside a battle (0x415e31): with [0x55e9d4] != 0 the position is stored in the mod
## table 0x55e9d8 (3 bytes per player entry: x, y, hidden|0xff00) for the next battle.
func op_op_4b(ins: Dictionary) -> void:
	var k := arg(ins, 0)
	if k < 0 or k >= 15:
		return
	var a := 0x55e9d8 + 3 * k
	Mem.w8(a, arg(ins, 1))
	Mem.w8(a + 1, arg(ins, 2))
	Mem.w8(a + 2, 1 if arg(ins, 4) not in [0, 0xffff] else 0)


## op 0x20 (0x416fd8): GS+0x11 = (GS+0x11 & 0xf0) | v ; v == 0xff clears bit 4 and the low nibble.
func op_op_20(ins: Dictionary) -> void:
	var b := Mem.r8(Mem.GS + 0x11) & 0xf0
	var v := arg(ins, 0) & 0xffff
	if (v & 0xff) == 0xff:
		Mem.w8(Mem.GS + 0x11, b & 0xef)
	else:
		Mem.w8(Mem.GS + 0x11, (b | v) & 0xff)


## op 0x6c (0x410c3e): copy person bytes 0x11..0x33 (except 0x26, 0x2a) from p1 to p2.
func op_op_6c(ins: Dictionary) -> bool:
	var a := arg(ins, 0)
	var b := arg(ins, 1)
	if a >= 0x400 or b >= 0x400:
		return false
	for off in range(0x11, 0x34):
		if off == 0x26 or off == 0x2a:
			continue
		Mem.w8(Mem.person_addr(b) + off, Mem.r8(Mem.person_addr(a) + off))
	return true


## op 0x0f (0x4158af): ending reached — record it in Niuniu.wa (byte v = 1), then credits → title
## (0x42b7c6).
func op_screen_mode(ins: Dictionary) -> void:
	var v := arg(ins, 0)
	if v < 3:
		SpecialFuncs.write_niuniu(v, 1)
	Game.ending_reached = true
	Audio.stop_bgm()
	SoundMap.stop_loop()
	await ui.chapter_title(-1, "全剧终")
	if vm:
		vm.abort = true
		vm.active = false
	Game.main.to_title()


## op 0x22 (0x42f754): play cutscene video n (name table 0x555060: 0 LOG.avi, 1 OPE.avi, 2 END.wmv,
## 3 PRE.wmv, 4.. 001.wmv..040.wmv). Music and sound effects are stopped first.
func op_set_weather(ins: Dictionary) -> void:
	var v := arg(ins, 0)
	var name := ""
	match v:
		2: name = "end"
		3: name = "pre"
		_:
			if v >= 4 and v < 0x7f:
				name = "%03d" % (v - 3)
	Audio.stop_bgm()
	SoundMap.stop_loop()
	if name != "":
		await ui.video.play(name)


## ops 0x36/0x38 outside a battle: person attributes only.
func op_test_attr(ins: Dictionary) -> bool:
	return Game.compare(PersonAttrs.get_attr(arg(ins, 0), arg(ins, 1)), arg(ins, 2), arg(ins, 3))


func op_set_attr(ins: Dictionary) -> void:
	PersonAttrs.set_attr(arg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3))
