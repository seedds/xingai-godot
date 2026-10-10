class_name ScriptHost
extends Node
## Opcode handlers shared by story (R) and battle (S) scripts, after the 6.6 engine Ekd5.exe (docs/eex.md §5–§11).
## Stages extend this: StoryStage adds the RPG-scene ops, BattleStage the battle ops and the battle variants of the
## shared ones. Handler naming: op_<name>(ins) where name comes from tools/eex.py; tests return bool.
## Status codes of the original: handlers returning nothing count as 1 ("ok"), as in the original.

signal finished

var vm: EexVM
var ui: GameUI
var fast := false

## Choice register reader+0x2038 (i32): op 0x12 / 0x72 sub 34 write index + 1, op 0x13 compares and resets it to −1 on
## a match (0x4184a0). Kept in emulated memory (0x492f90 + 0x2038) so a save holds it.
const CHOICE := 0x494fc8
var choice_result: int:
	get: return Mem.r32s(CHOICE)
	set(v): Mem.w32(CHOICE, v)


func _ready() -> void:
	ui = Game.main.ui


## Touch shell: true while the scene waits at its top level, where its 菜单 button opens the system menu.
func menu_ready() -> bool:
	return false


func open_menu() -> void:
	pass


# ------------------------------------------------------------------ argument helpers
## Integer argument with the EV indirection resolved ({"var": n} → EV[n], docs/eex.md §2). u16 args come as 0..0xffff,
## int32 args unsigned (0..0xffffffff) for ops > 0x6d.
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


## Low word of an argument (what a handler reading a u16 parameter sees).
func u16(ins: Dictionary, i: int) -> int:
	return arg(ins, i) & 0xffff


## Signed 16-bit view (0xffff → −1) for person/unit args.
func arg16(ins: Dictionary, i: int) -> int:
	var v := arg(ins, i) & 0xffff
	return v - 0x10000 if v >= 0x8000 else v


## Signed 32-bit view of an int32 argument.
func arg32(ins: Dictionary, i: int) -> int:
	var v := arg(ins, i) & 0xffffffff
	return v - 0x100000000 if v >= 0x80000000 else v


## Copy a string into a fixed engine buffer (NUL-terminated, at most `n` bytes incl. the NUL).
func write_cstr(addr: int, text: String, n: int) -> void:
	var b := TextExpand.gbk(text)
	var k := mini(b.size(), n - 1)
	for i in k:
		Mem.w8(addr + i, b[i])
	Mem.w8(addr + k, 0)


## Read a NUL-terminated GBK string from engine memory.
static func read_cstr(addr: int, n: int) -> String:
	var b := PackedByteArray()
	for i in n:
		var c := Mem.r8(addr + i)
		if c == 0:
			break
		b.append(c)
	return TextExpand.from_gbk(b)


# ------------------------------------------------------------------ stage hooks (overridden by the stages)
## True in a battle (0x40b922: scene mode 3).
func in_battle() -> bool:
	return false


## After a raw memory write by a script (op 0x77 / 0x78): stages refresh what they show.
func _after_poke(_addr: int) -> void:
	pass


## After op 0x78 wrote a field (stages refresh sprites / HP bars).
func on_field_written(_field: int, _id: int) -> void:
	pass


## Battle parts of 0x72 sub-functions (1/2/3 casts, 11, 12 pictures, 14 tint redraw, 16, 17, 21 redraw …): BattleStage.
func ext_battle(_sub: int, _nums: Array, _text: String) -> void:
	pass


## Screen anchor of a speaker for the talk window (StoryStage: the actor's foot point; BattleStage: the unit).
func talk_anchor(_pid: int) -> Variant:
	return null


## Person of the battle unit acting now ([0x4b5df0] via 0x418ce0); story: −1.
func current_unit_person() -> int:
	return -1


## Battle HP / MP change of a person's unit through 0x45aa37 with byte EV[4044] = mode (0 sub floor 1, 1 add,
## 2 set; clamped to the unit's maximum, never kills) — op 0x38 attrs 7 / 8. BattleStage; no units outside a battle.
func unit_hp_mp_op(_pid: int, _attr: int, _v: int, _mode: int) -> void:
	pass


# ------------------------------------------------------------------ UI wrappers (new GameUI API, old one as fallback)
func ui_talk(pid: int, text: String, flags := 0x20) -> void:
	if ui.has_method("talk"):
		await ui.talk(pid, text, flags)
		return
	var face: Texture2D = Game.person_face(pid) if pid >= 0 and pid < 0x400 else null
	var nm := TextExpand.display_name(pid) if pid >= 0 and pid < 0x400 else ""
	var top := false
	var an: Variant = talk_anchor(pid)
	if an is Dictionary:
		top = float(an.get("y", 0)) > 300
	await ui.dialog.talk(face, nm, text.replace("\r", ""), top)


func ui_message(style: int, text: String) -> void:
	if ui.has_method("message"):
		await ui.message(style, text)
		return
	await ui.popup(text.replace("\r", ""))


func ui_yes_no(text: String) -> bool:
	if ui.has_method("yes_no"):
		return await ui.yes_no(text)
	var i: int = await ui.menu.choose(["是", "否"], Vector2(-1, -1), false, text)
	return i == 0


func ui_choose(options: Array, pid: int) -> int:
	var avoid := OS.get_environment("WG_CHOOSE_AVOID")
	if (Game.autoplay or Game.demo) and avoid != "":
		# test harness: autoplay keeps off options naming one of these words (side games, skips) when it can
		var ok := []
		for k in options.size():
			var bad := false
			for w in avoid.split(",", false):
				if str(options[k]).contains(w):
					bad = true
			if not bad:
				ok.append(k)
		if not ok.is_empty() and ok.size() < options.size():
			var pick: int = ok[Rules.rand(ok.size())] if OS.get_environment("WG_RANDOM") != "" else ok[0]
			if OS.get_environment("WG_TRACE_TEXT") != "":
				print("  [menu] %s -> %d (avoiding %s)" % [options, pick + 1, avoid])
			return pick
	if ui.has_method("choose_dialog"):
		return await ui.choose_dialog(options, pid)
	var lab := []
	for k in options.size():
		lab.append("%d.%s" % [k + 1, options[k]])
	return await ui.menu.choose(lab, Vector2(-1, -1), false)


func ui_choice_modal(options: Array, checkboxes: bool, max_checked: int) -> Array:
	if ui.has_method("choice_modal"):
		return await ui.choice_modal(options, checkboxes, max_checked)
	var i: int = await ui.menu.choose(options, Vector2(-1, -1), false)
	return [i]


# ------------------------------------------------------------------ flow control
func op_comment(_ins: Dictionary) -> bool:
	return true


func op_else(_ins: Dictionary) -> bool:
	return true


## 0x10 许子将指导 (0x42bce9): advice UI; unused by the scripts.
func op_nop(_ins: Dictionary) -> void:
	pass


func op_exit_section(_ins: Dictionary) -> void:
	pass


## 0x0d (0x4103ac): menu flag GS+0x10 = 0 (0x41196c); the VM advances the scene at the block's END.
func op_next_scene(_ins: Dictionary) -> void:
	set_menu_flag(0)


## 0x11 (0x42547a): all 128 RPG actors cleared (0x426bb2); GS+6 (u16) = EV[4051]·200 + v; EV[4051] = 0 (0x418ab1).
## The file ends at the block's END and the manager loads counter + 1.
func op_goto_scenario(ins: Dictionary) -> void:
	clear_actors()
	Game.scenario = (Mem.ev(4051) * 200 + u16(ins, 0)) & 0xffff
	Mem.set_ev(4051, 0)
	Game.scenario_jumped = true


## Stages with actors clear them (0x426bb2).
func clear_actors() -> void:
	pass


## 0x08 菜单处理 (0x41431d): GS+0x10 = v (0x41196c); v ≠ 0 and the toolbar exists → re-show it (0x411991).
func op_set_menu(ins: Dictionary) -> void:
	var v := u16(ins, 0)
	set_menu_flag(v)
	if v != 0:
		toolbar_reshow_if_menu()


## 0x41196c: GS+0x10 = v (scene mode 2 also redraws, 0x40dff9).
func set_menu_flag(v: int) -> void:
	Mem.w8(Mem.GS + 0x10, v)


## 0x411991: outside a battle with the menu flag GS+0x10 set, show the toolbar again — its buttons only when the sortie
## flag [0x501fff] is set (0x419959(tb, [0x501fff] == 0)).
func toolbar_reshow_if_menu() -> void:
	if not in_battle() and Mem.r8(Mem.GS + 0x10) != 0:
		toolbar_show(Mem.r8(0x501fff) != 0)


## 0x4137cd: while a message window is up the toolbar is hidden, if the sortie flag is set. StoryStage.
func toolbar_hide_for_dialog() -> void:
	pass


## 0x420660 (close the toolbar windows) / 0x419959 (position and, with buttons, show them): StoryStage.
func toolbar_close() -> void:
	pass


func toolbar_show(_with_buttons: bool) -> void:
	pass


# ------------------------------------------------------------------ flags & variables
## 0x0b (0x401925): flag[a0] = (a1 ≠ 0); a0 is an int32 (negative → EV[-v], resolved by the converter).
func op_set_flag(ins: Dictionary) -> void:
	Mem.set_flag(arg(ins, 0) & 0xffff, u16(ins, 1) != 0)


## 0x05 (0x41179f): all flags of the first list set and all of the second clear.
func op_test_flags(ins: Dictionary) -> bool:
	var a: Array = ins["args"]
	for f in a[0]:
		if not Mem.flag(int(f)):
			return false
	for f in a[1]:
		if Mem.flag(int(f)):
			return false
	return true


## 0x0a 初始化局部变量 (0x415aca): flags 0..255 cleared; 0x501b00..0x501fff zeroed (battle bytes, the SP table
## 0x501c00, the toolbar flag 0x501fff); 0x473de1: the 3 animation records 0x501aac (0x40dd0b) and 0x510000
## (0xc80 bytes); timed 特技 grants (0x72 sub 35, turns < 100) purged (0x42fc8c).
func op_clear_flags(_ins: Dictionary) -> void:
	for i in 256:
		Mem.set_flag(i, false)
	Mem.fill(0x501b00, 0x500, 0)
	for k in 3:
		Mem.w32(0x501aac + 12 * k, 0)
	Mem.fill(0x510000, 0xc80, 0)
	purge_timed_grants()


## 0x42fc8c: drop the 0x512dc0 entries whose turns are < 100 (permanent grants stay).
static func purge_timed_grants() -> void:
	var base := ExtCommand.ADDED
	var p := base
	var guard := 0
	while guard < 0x900:
		guard += 1
		if Mem.r8(p) != 0xff:
			p += 1
			continue
		if Mem.r8(p + 1) == 0xff:
			return
		var e := p + 2
		while Mem.r8(e) != 0xff and guard < 0x900:
			guard += 1
			if Mem.r8(e + 1) < 100:
				# remove the 4-byte entry: the rest of the list (to the FF FF end) moves down
				var end := e
				while not (Mem.r8(end) == 0xff and Mem.r8(end + 1) == 0xff) and end < base + 0x800:
					end += 1
				end += 2
				for a in range(e, end - 4):
					Mem.w8(a, Mem.r8(a + 4))
				for a in range(end - 4, end):
					Mem.w8(a, 0)
			else:
				e += 4
		p = e


## Store of op 0x77 (0x41046a): EV[4076] low byte 1 = byte, 2 = word, else dword — only when the destination is not
## &PT (dk ≠ 1) and the source is an immediate or *PT (sk < 2). op 0 add / 1 sub (wrap within the width) / 2 store.
static func _store(dst: int, v: int, op: int, sk: int, dk: int) -> void:
	var w := 4
	if dk != 1 and sk < 2:
		match Mem.ev(4076) & 0xff:
			1: w = 1
			2: w = 2
	var cur: int
	match w:
		1: cur = Mem.r8(dst)
		2: cur = Mem.r16(dst)
		_: cur = Mem.r32(dst)
	var res := v
	if op == 0:
		res = cur + v
	elif op == 1:
		res = cur - v
	match w:
		1: Mem.w8(dst, res & 0xff)
		2: Mem.w16(dst, res & 0xffff)
		_: Mem.w32(dst, res & 0xffffffff)


## 0x77 变量运算 `int_var_op dk, di, op, sk, sv` (0x416c87; all int args raw):
## destination dk 0 = *PT[di], 1 = &PT[di], 2 = &EV[di]; source sk 0 imm, 1 *(u32*)PT[sv], 2 PT[sv], 3 &PT[sv],
## 4 EV[sv], 5 &EV[sv]; op 0 +=, 1 −=, 2 =, 3 *=, even ≥ 4 unsigned /, 6 unsigned %, odd ≥ 5 dst·v/100 (0x425ad9);
## out-of-range indices → the error box "变量值溢出" (0x500cc0). PT patch record afterwards (0x413604).
func op_int_var_op(ins: Dictionary) -> void:
	var dk := u16(ins, 0)
	var di := arg(ins, 1)
	var opn := u16(ins, 2)
	var sk := u16(ins, 3)
	var sv := arg(ins, 4)
	var dst := 0
	if dk < 2:
		if di > 0x1e0:
			await _var_overflow()
			return
		dst = Mem.PT + 4 * di
		if dk == 0:
			dst = Mem.r32(dst)
	elif dk == 2 and di <= 0xfff:
		dst = Mem.EV + 4 * di
	else:
		await _var_overflow()
		return
	var src := sv & 0xffffffff
	if sk != 0:
		if sk < 4:
			if sv > 0x1e0:
				await _var_overflow()
				return
			src = Mem.PT + 4 * sv
			if sk == 1:
				src = Mem.r32(Mem.r32(src))
			elif sk == 2:
				src = Mem.r32(src)
		else:
			if sv > 0xfff:
				await _var_overflow()
				return
			src = Mem.EV + 4 * sv
			if sk == 4:
				src = Mem.r32(src)
			elif sk != 5:
				await _var_overflow()
				return
	var old := Mem.r32(dst)
	var o := opn & 0xff
	if o > 2:
		var res := 0
		if o & 1 == 0:
			if src == 0:
				push_warning("int_var_op: division by 0 (the original crashes) in %s" % (vm.name if vm else "?"))
				return
			res = old / src if opn != 6 else old % src
		else:
			res = (old * src) & 0xffffffff
			if o != 3:
				res = res / 100
		_store(dst, res, 2, sk, dk)
	else:
		_store(dst, src, o, sk, dk)
	# 0x413604: a write through PT[di] (di ≥ 200) is recorded so a load can re-apply it
	if dk == 0 and (di & 0xffff) >= 200:
		Mem.w32(0x506464 + 4 * di, Mem.r32(dst))
		Mem.w8(0x506f84 + di, Mem.ev(4076) & 0xff)
		if Mem.r32(0x5068c8 + 4 * di) == 0:
			Mem.w32(0x5068c8 + 4 * di, old)
	_after_poke(dst)


func _var_overflow() -> void:
	await ui_message(0, "变量值溢出")


## Value resolver of op 0x79 (0x415133): 0 imm; kinds 1..3 with (v & 0xffff) < 0x1e1: 1 *(u32*)PT[v] masked by
## EV[4076] (1 byte, 2 word), 2 PT[v], 3 &PT[v]; kinds ≥ 4 with (v & 0xffff) < 0x1000: 4 EV[v], ≥ 5 &EV[v]; an index
## out of range yields v itself.
static func _test_value(kind: int, v: int) -> int:
	v &= 0xffffffff
	if kind == 0:
		return v
	var k := kind & 0xff
	if k < 4:
		if (v & 0xffff) >= 0x1e1:
			return v
		var p := Mem.PT + 4 * v
		match k:
			1:
				var x := Mem.r32(Mem.r32(p))
				match Mem.ev(4076) & 0xff:
					1: x &= 0xff
					2: x &= 0xffff
				return x
			2:
				return Mem.r32(p)
		return p
	if (v & 0xffff) >= 0x1000:
		return v
	var q := Mem.EV + 4 * v
	return Mem.r32(q) if k == 4 else q


## 0x79 变量测试 `test_int_var ka, va, mode, kb, vb` (0x415093): unsigned compare, mode (low byte) 0 ==, 1 >=, 2 <=,
## 3 !=, 4 <, other >.
func op_test_int_var(ins: Dictionary) -> bool:
	var a := _test_value(u16(ins, 0), arg(ins, 1))
	var b := _test_value(u16(ins, 3), arg(ins, 4))
	match u16(ins, 2) & 0xff:
		0: return a == b
		1: return a >= b
		2: return a <= b
		3: return a != b
		4: return a < b
	return a > b


## 0x78 整型变量赋值 (0x416dcd → 0x4202d8).
func op_data_transfer(ins: Dictionary) -> void:
	await DataTransfer.run(self, ins)


## 0x75 S特殊形象指定 (0x465d8a): u16 0x501000[id] = v (no range check), then re-skin the unit in battle (0x40523a).
func op_set_s_image(ins: Dictionary) -> void:
	var id := u16(ins, 0)
	Mem.w16(Mem.S_SPRITE + 2 * id, u16(ins, 1))
	on_field_written(27, id)


## 0x35 武将形象改变 (0x411f2d): u16 0x50f800[person] = v (R image; no bounds check).
func op_set_r_image(ins: Dictionary) -> void:
	var id := u16(ins, 0)
	Mem.w16(Mem.R_SPRITE + 2 * id, u16(ins, 1))
	on_field_written(0, id)


## 0x70 能力选择复制 (0x40f2ea, unused): off < 0x48 (signed) → copy the word person[a]+off → person[b]+off.
func op_copy_person_word(ins: Dictionary) -> bool:
	var off := arg32(ins, 2)
	if off >= Mem.PERSON_SIZE:
		return false
	Mem.w16(Mem.person_addr(u16(ins, 1)) + off, Mem.r16(Mem.person_addr(u16(ins, 0)) + off))
	return true


## 0x73 人物五围和测试 (0x40f244, unused): sum of the abilities 10..14 whose flag is set, cmp 0 ≥ v, 1 < v, else ==.
func op_test_sum(ins: Dictionary) -> bool:
	var pid := u16(ins, 0)
	var s := 0
	for k in 5:
		var fl := u16(ins, 3 + k)
		if fl != 0 and fl != 0xffff:
			s += PersonAttrs.get_attr(pid, 10 + k)
	return Game.compare(s, arg(ins, 1), u16(ins, 2))


## 0x74 开/禁存档 (0x41dd26, unused): u8 0x500fff = v (save allowed; set to 1 by a load, 0x4188eb).
func op_set_save_enabled(ins: Dictionary) -> void:
	Mem.w8(0x500fff, u16(ins, 0))


## 0x6e 概率测试 (0x41741e): p = low byte of the (raw) int arg, > 99 → 100; chance(p) 0x47fb32.
func op_test_random(ins: Dictionary) -> bool:
	var p := arg(ins, 0) & 0xff
	if p > 99:
		p = 100
	return Rules.chance(p)


## 0x72 信息传送 (0x47d89e).
func op_ext_command(ins: Dictionary) -> void:
	await ExtCommand.run(self, ins)


## 0x7b 信息传送测试 (0x47e9f0, unused).
func op_test_ext_command(ins: Dictionary) -> bool:
	return ExtCommand.test(self, ins)


## 0x71 特效请求 (0x403936, unused): custom-person dialogs.
func op_special_func(ins: Dictionary) -> void:
	await SpecialFuncs.run(self, arg(ins, 0))


# ------------------------------------------------------------------ timing / screen
func wait(sec: float) -> void:
	if fast or sec <= 0 or Game.autoplay:
		return
	await get_tree().create_timer(sec).timeout


## 0x09 延时 (0x415b21): blocking delay v × 100 ms (timer ticks + 2v, tick = GetTickCount/50).
func op_delay(ins: Dictionary) -> void:
	await wait(arg(ins, 0) * 0.1)


## 0x1e 武将重绘 (0x41e1a5): yield until the actors are idle (StoryStage waits for walks).
func op_wait_frame(_ins: Dictionary) -> void:
	await get_tree().process_frame


## 0x1c 绘图 (0x413e49): show the composed scene (scene mode 2: [0x501bfb] = 1 and the picture shown, 0x41c39d).
func op_fade_out(_ins: Dictionary) -> void:
	Mem.w8(0x501bfb, 1)
	await ui.fade_from_black()


## 0x1d 调色板设定 (0x413ec7): the scene goes black (mode 2 clears the picture buffer, 0x426c3b / 0x481107); then
## 0x411600 clears [0x501bfb].
func op_fade_in(_ins: Dictionary) -> void:
	await ui.fade_to_black()
	Mem.w8(0x501bfb, 0)


# ------------------------------------------------------------------ audio / video
## 0x23 音效 (0x4157b9 → 0x474a44): sound effect id (0–99 SE%02u, 100–199 SE_M_%02u, 200+ SE_E_%02u); mode 0 loop,
## 1 once, 0xff stop, n ≥ 2 play n times.
func op_play_music(ins: Dictionary) -> void:
	await SoundMap.play_se_id(u16(ins, 0), arg(ins, 1))


## 0x24 CD音轨 (0x4157fa): BGM track id + 2; 0xff stops.
func op_play_sound(ins: Dictionary) -> void:
	SoundMap.play_bgm_id(u16(ins, 0))


## 0x22 动画 (0x42c3c7 → 0x42f5c9): video 0 Logo.Avi, 1 Open.Avi, 2 End.Avi, 3 Press.Avi, ≥ 4 Mov%03u.Avi (id − 3);
## id 1 cannot be skipped. Music and sound are stopped first.
func op_set_weather(ins: Dictionary) -> void:
	await play_video(u16(ins, 0))


func play_video(v: int) -> void:
	var name := ""
	match v:
		0: name = "logo"
		1: name = "open"
		2: name = "end"
		3: name = "press"
		_: name = "mov%03d" % (v - 3)
	Audio.stop_bgm()
	SoundMap.stop_loop()
	if OS.get_environment("WG_NOVIDEO") != "" or not Assets.exists("video/%s.ogv" % name):
		return
	await ui.video.play(name)


# ------------------------------------------------------------------ text
## 0x14 对话 (0x4136ad): segments `&speaker\ntext`, a new one at each "\n&". Story: speaker by name (0x413656) or
## `&*.N`; battle: `&\n` = current unit, `&` + ≤ 3 digits = unit index (unit not on the map → the op ends). Story, or
## speaker −1 → talk window 0x42d5b0(text, person, 0x20) (toolbar hidden first, 0x4137cd); battle with a speaker →
## 0x45965d. After the last segment the toolbar comes back if the next op is not another dialog (0x4137e1).
func op_dialog(ins: Dictionary) -> void:
	var b := TextExpand.gbk(sarg(ins, 0))
	var battle := in_battle()
	var p := 0
	var speaker := -1
	while true:
		if p < b.size() and b[p] == 0x26:
			p += 1
			if battle and p < b.size() and b[p] == 0x0a:
				speaker = current_unit_person()
				p += 1
			elif battle and p < b.size() and b[p] >= 0x30 and b[p] <= 0x39:
				var num := 0
				var k := 0
				while k < 3 and p < b.size() and b[p] != 0x0a:
					num = num * 10 + (b[p] - 0x30)
					p += 1
					k += 1
				var u := Mem.unit_addr(num)
				if num >= Mem.UNIT_SLOTS or Mem.r8(u + 0xc) != 2:
					return
				speaker = Mem.r16(u)
				p += 1
			else:
				var hd := PackedByteArray()
				while p < b.size() and b[p] != 0x0a:
					hd.append(b[p])
					p += 1
				speaker = TextExpand.speaker_of(TextExpand.from_gbk(hd))
				p += 1
		var text := TextExpand.from_gbk(TextExpand.expand_bytes(b.slice(p)))
		if not battle or speaker < 0 or speaker == 0xffff:
			toolbar_hide_for_dialog()
			await ui_talk(speaker if speaker != 0xffff else -1, text, 0x20)
		else:
			await battle_talk(speaker, text)
		# the next segment starts after "\n&"
		var q := p
		var found := false
		while q < b.size():
			if b[q] == 0x0a and q + 1 < b.size() and b[q + 1] == 0x26:
				found = true
				break
			q += 1
		if not found:
			break
		p = q + 1
	if vm == null or vm.next_op != 0x14:
		toolbar_reshow_if_menu()


## Battle dialog with a speaker (0x45965d): BattleStage may override; GameUI.battle_bubble when it exists.
func battle_talk(pid: int, text: String) -> void:
	if ui.has_method("battle_bubble"):
		await ui.battle_bubble(pid, text)
	else:
		await ui_talk(pid, text, 0x20)


## 0x15 对话2 (0x41396a): story → talk window 0x42d5b0(text, a0, 0); battle: a1 ≠ −1 → bubble at a0's unit
## (0x45972e), else nothing.
func op_unit_say(ins: Dictionary) -> void:
	var text := TextExpand.expand(sarg(ins, 2))
	if not in_battle():
		await ui_talk(u16(ins, 0), text, 0)
	elif u16(ins, 1) != 0xffff:
		await battle_unit_say(u16(ins, 0), u16(ins, 1), text)


func battle_unit_say(pid: int, _a1: int, text: String) -> void:
	await battle_talk(pid, text)


## 0x16 信息 (0x413a35): EV[4071] = 0 → message without portrait 0x42d5b0(text, −1, 0x20); ≠ 0 → 历史情报 record
## (§11.3, Game.history_add). EV[4071] = 0 afterwards.
func op_info(ins: Dictionary) -> void:
	var cat := Mem.ev(4071)
	if cat == 0:
		var text := TextExpand.expand(sarg(ins, 0))
		await ui_talk(-1, text, 0x20)
		Mem.set_ev(4071, 0)
		return
	Game.history_add(cat & 0xff, sarg(ins, 0))
	Mem.set_ev(4071, 0)


## 0x69 旁白 (0x4139f9): expanded text → message box style 2 (0x42f699(2, text)).
func op_popup(ins: Dictionary) -> void:
	await ui_message(2, TextExpand.expand(sarg(ins, 0)))


## 0x12 选择框 (0x411aa6): options = the expanded text lines (≤ 6, numbered by the engine, 0x42c9fc); arg1 = portrait
## person (0xffff → 0); result index + 1 → the choice register. arg1 == 0x3ff with EV[4083] ≠ 0 starts the S-form
## duel / 舌战 instead (unused).
func op_choice(ins: Dictionary) -> void:
	var opts := []
	for line in TextExpand.expand(sarg(ins, 0)).split("\n", false):
		opts.append(line.replace("\r", ""))
		if opts.size() >= 6:
			break
	var pid := u16(ins, 1)
	if pid == 0xffff:
		pid = 0
	if opts.is_empty():
		return
	var i := await ui_choose(opts, pid)
	choice_result = i + 1


## 0x13 case (0x41173b): choice == arg; a match resets the register to −1 (0x4184a0).
func op_test_choice(ins: Dictionary) -> bool:
	if arg32(ins, 0) == choice_result:
		choice_result = -1
		return true
	return false


## 0x04 询问测试 (0x4116ff): yes/no box 0x42f699(1, "可以吗？") (yes = 1) == arg.
func op_test_yes_no(ins: Dictionary) -> bool:
	var yes := await ui_yes_no("可以吗？")
	return (1 if yes else 0) == u16(ins, 0)


## 0x67 章名 (0x413b1b): u8 0x510cf9 = max(n − 1, 0) (0x47fad0); title 0x40b935(n, expanded text).
func op_chapter_title(ins: Dictionary) -> void:
	var n := arg(ins, 0) & 0xffff
	var text := TextExpand.expand(sarg(ins, 1))
	Mem.w8(0x510cf9, maxi((n & 0xff) - 1, 0))
	Game.chapter_title = text
	await ui.chapter_title(n, text)


## 0x18 事件名称设定 (0x417dc8): expand into 0x49f1cc (scenario title, shown in the save list), draw 0x47650f; with
## [0x501bfb] ≠ 0 also a message box (style 2).
func op_title_text(ins: Dictionary) -> void:
	var text := TextExpand.expand(sarg(ins, 0))
	write_cstr(0x49f1cc, text, 22)
	Game.chapter_title = text
	if ui.has_method("title_text"):
		await ui.title_text(text)
	if Mem.r8(0x501bfb) != 0:
		await ui_message(2, text)


## 0x17 场所名 (0x417d6c): expand into 0x4b0758, draw 0x476612; with [0x501bfb] ≠ 0 also a message box (style 2).
func op_place_name(ins: Dictionary) -> void:
	var text := TextExpand.expand(sarg(ins, 0))
	write_cstr(0x4b0758, text, 23)
	if ui.has_method("place_name"):
		await ui.place_name(text)
	if Mem.r8(0x501bfb) != 0:
		await ui_message(2, text)


## 0x2c 地图文字显示 (0x417235 → 0x4332a6): map text (0xffff → 0), `*` escapes.
func op_caption(ins: Dictionary) -> void:
	var a := [u16(ins, 1), u16(ins, 2), u16(ins, 3)]
	for k in 3:
		if a[k] == 0xffff:
			a[k] = 0
	await ui.caption(TextExpand.expand(sarg(ins, 0)), a[0], a[1], a[2])


## 0x7a 对话3 (0x4284a2 → 0x42db2c): segments `&f0,f1,f2,f3,f4\n<text>`; fields: a byte ≤ '9' starts a number
## (`*N` allowed), else a person name (≤ 16 bytes up to '\n' / ','); values ≥ 0x400 (and −1) → −1; '&' ends the header
## early. f0 = speaker mask, f1 → EV[4031] while the window is up, f2..f4 = left / middle / right. The window stays
## open while the next op is 0x7a; otherwise it is closed after the last segment (0x4137e1-like look-ahead).
func op_dialog3(ins: Dictionary) -> void:
	var b := TextExpand.gbk(sarg(ins, 0))
	var save4031 := Mem.ev(4031)
	toolbar_hide_for_dialog()
	var p := 0
	while p < b.size():
		if b[p] != 0x26:
			break
		p += 1
		var f := [0, 0, -1, -1, -1]
		var k := 0
		while k < 5 and p < b.size() and b[p] != 0x0a and b[p] != 0x26:
			var v := -1
			if b[p] <= 0x39:
				var neg := false
				var star := false
				while p < b.size() and (b[p] == 0x2d or b[p] == 0x2a):
					if b[p] == 0x2d:
						neg = true
					else:
						star = true
					p += 1
				var num := 0
				while p < b.size() and b[p] >= 0x30 and b[p] <= 0x39:
					num = num * 10 + (b[p] - 0x30)
					p += 1
				v = Mem.r32s(Mem.EV + 4 * num) if star else num
				if neg:
					v = -v
			else:
				var nm := PackedByteArray()
				while p < b.size() and b[p] != 0x0a and b[p] != 0x2c and nm.size() < 16:
					nm.append(b[p])
					p += 1
				v = TextExpand.person_by_name(TextExpand.from_gbk(nm))
			if k >= 2 and (v < 0 or v >= 0x400):
				v = -1
			f[k] = v
			k += 1
			if p < b.size() and b[p] == 0x2c:
				p += 1
		while p < b.size() and b[p] != 0x0a:
			p += 1
		p += 1
		var q := p
		while q < b.size() and not (b[q] == 0x0a and q + 1 < b.size() and b[q + 1] == 0x26):
			q += 1
		var text := TextExpand.from_gbk(TextExpand.expand_bytes(b.slice(p, q)))
		Mem.set_ev(4031, int(f[1]) & 0xff)
		var persons := [f[2], f[3], f[4]]
		if in_battle():
			persons = await dialog3_battle_persons(persons, int(f[0]))
		if not persons.is_empty():
			if ui.has_method("dialog3"):
				await ui.dialog3(persons, int(f[0]), text)
			else:
				var who := -1
				for j in 3:
					if int(f[0]) & (4 >> j) and int(persons[j]) >= 0:
						who = int(persons[j])
						break
				await ui_talk(who, text, 0x20)
		Mem.set_ev(4031, save4031)
		p = q + 1
	if vm == null or vm.next_op != 0x7a:
		if ui.has_method("dialog3_close"):
			ui.dialog3_close()
		toolbar_reshow_if_menu()


## Battle (0x42d8bf): f2..f4 go through the unit selector (with EV[4031] = f1 set by the caller) to persons; the first
## one whose unit is on the map (state 2) is focused (0x4596bd, the stage's `talk_focus`); when none is on the map the
## segment is skipped silently ([] returned) unless f2 == f3 == f4 ≠ −1, and then the slots outside the speaker mask
## are emptied (the scripts' `837,837,837` form).
func dialog3_battle_persons(persons: Array, mask := 7) -> Array:
	var out := []
	var focus := -1
	for v in persons:
		var u := unit_select(int(v)) if int(v) >= 0 else -1
		var pid := -1
		if u >= 0:
			pid = Mem.r16(u)
			if focus < 0 and Mem.r8(u + 0xc) == 2:
				focus = pid
		out.append(pid)
	if focus < 0:
		if int(persons[0]) >= 0 and persons[0] == persons[1] and persons[1] == persons[2]:
			for j in 3:
				if mask & (4 >> j) == 0:
					out[j] = -1
				else:
					out[j] = persons[j]
			return out
		return []
	if has_method("talk_focus"):
		await call("talk_focus", focus)
	return out


## Unit selector 0x41b882(v): v ≥ 0x404 → unit v − 0x404; byte EV[4031] ≠ 0 and v < 250 → unit v; else v is a person →
## the first unit with that person and state ≠ 0 (0x456079). Returns the unit address or −1 (empty slot / none).
static func unit_select(v: int) -> int:
	var slot := -1
	if v >= 0x404:
		slot = v - 0x404
	elif Mem.ev(4031) & 0xff != 0 and v < 250:
		slot = v
	else:
		for s in Mem.UNIT_SLOTS:
			var a := Mem.unit_addr(s)
			if Mem.r32(a) == v and Mem.r8(a + 0xc) != 0:
				return a
		return -1
	if slot < 0 or slot >= Mem.UNIT_SLOTS:
		return -1
	var u := Mem.unit_addr(slot)
	return -1 if Mem.r16(u) == 0xffff else u


# ------------------------------------------------------------------ party / items / money
## 0x3b 武将加入 (0x414790): person, mode (0xffff → 0xff), arg (0xffff → 0); story 0x40c2e7, battle 0x45b771.
func op_join(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if pid == 0xffff:
		return
	var mode := u16(ins, 1)
	if mode == 0xffff:
		mode = 0xff
	var a := u16(ins, 2)
	if a == 0xffff:
		a = 0
	if in_battle():
		await battle_join(pid, mode & 0xff)
	else:
		Game.join(pid, mode, a)


## Battle part of op 0x3b (0x45b771: the person's unit moves to side `mode`): BattleStage.
func battle_join(_pid: int, _side: int) -> void:
	pass


## 0x3d 获得物品 (0x4143cb): item 0xffff → EV[4025]; level / flag 0xffff → 0; equipment with level 0 gets the level for
## the party average (0x407da3(item, 0x40c231)); story 0x4144ef, battle 0x459950; then the item record 0x408b0d.
func op_get_item(ins: Dictionary) -> void:
	var iid := u16(ins, 0)
	if iid == 0xffff:
		iid = Mem.ev(4025) & 0xffff
	var lvl := u16(ins, 1)
	if lvl == 0xffff:
		lvl = 0
	var flag := u16(ins, 2)
	if flag == 0xffff:
		flag = 0
	var it := Game.item(iid & 0xff)
	if it.is_empty():
		return
	if Person.slot_of(it) <= 1 and lvl == 0:
		lvl = Game.auto_item_level(iid & 0xff, Game.party_avg_level())
	if in_battle():
		await battle_get_item(iid, lvl, flag, u16(ins, 3))
	else:
		await story_get_item(iid & 0xff, lvl, true)
	Game.record_item(iid)


## 0x4144ef(item, level, record, show): consumables (category 3): count += level + 1 (0x43e093) and its message
## (0x414a7e); other items: "得到了%s！" (0x48e39c) box (style 2), level capped at the item's maximum, accessories with
## level / exp 0xff, into the bag (0x40d693).
func story_get_item(iid: int, lvl: int, show: bool) -> void:
	var it := Game.item(iid)
	if Person.slot_of(it) == 3:
		Game.consumable_add(iid, lvl + 1)
		if show:
			await ui_message(2, "得到了%s！" % str(it.get("name", "")))
		return
	if show:
		await ui_message(2, "得到了%s！" % str(it.get("name", "")))
	var maxl := Person.max_item_level(it)
	if lvl > maxl:
		lvl = maxl
	var xp := 0
	if Person.slot_of(it) == 2:
		lvl = 0xff
		xp = 0xff
	Game.add_item(iid, lvl, xp)


## Battle part of op 0x3d (0x459950: fly-to-unit animation when flag ≠ 0, selectors ≥ 0x400): BattleStage.
func battle_get_item(iid: int, lvl: int, flag: int, _person: int) -> void:
	await story_get_item(iid & 0xff, lvl, flag != 0)


## 0x6f 丢弃物品 (0x40c603, §10.5): always returns 1.
func op_lose_item(ins: Dictionary) -> bool:
	Game.lose_item(u16(ins, 0))
	return true


## 0x3a 钱、章节编号、忠奸设置 (0x41481f): kind (low byte) 0 gold (op 0 set ≤ 999,999 0x40e1a4, 1 add 0x40da71, 2 sub
## saturating 0x40d7ee); 1 → u8 0x510cf9 = v whatever the op; 2 忠奸: op 0 set min(v, 100) (0x418cb3), 1 / 2 add / sub
## with the gauge animation (0x40d3bc).
func op_set_resource(ins: Dictionary) -> void:
	var kind := u16(ins, 0) & 0xff
	var op := u16(ins, 1) & 0xff
	var v := arg(ins, 2)
	if kind == 2 and op != 0 and op < 3:
		await Game.loyalty_change(v, op - 1, ui)
		return
	Game.change_resource(kind, op, v)


## 0x37 钱、章节编号、忠奸测试 (0x4118bd): kind 0 gold, 1 min(GS+6 / 2, 127), 2 忠奸; cmp 0 ≥, 1 <, else ==.
func op_test_resource(ins: Dictionary) -> bool:
	return Game.compare(Game.get_resource(u16(ins, 0)), arg(ins, 1), u16(ins, 2))


## 0x3e 加入装备设定 (0x416326, §11.7): person < 0x400; 0xffff → 0 for the 5 codes; story: 0x412db6 per slot.
func op_set_equipment(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if pid == 0xffff or pid >= 0x400:
		return
	var c := []
	for k in 5:
		var v := u16(ins, 1 + k)
		c.append(0 if v == 0xffff else v)
	if in_battle():
		await battle_set_equipment(pid, c)
		return
	for slot in 3:
		var lvl: int = c[slot * 2 + 1] if slot < 2 else 0xff
		Game.equip_by_code(pid, slot, c[slot * 2], lvl & 0xff, c[1])
	on_field_written(0x2e, pid)


## Battle part of op 0x3e (the unit must exist; codes > 0x95 ignored, 0x44299b): BattleStage.
func battle_set_equipment(pid: int, c: Array) -> void:
	for slot in 3:
		var code: int = c[slot * 2]
		if code == 0 or code > 0x95:
			continue
		var lvl: int = c[1] if code == 1 else (c[slot * 2 + 1] if slot < 2 else 0xff)
		Game.equip_by_code(pid, slot, code, lvl & 0xff, c[1])
	on_field_written(0x2e, pid)


## 0x52 兵种改变 (0x414bd4): person (battle 0x400..0x402 = current unit; other ≥ 0x400 ignored) → class (0x40e01f);
## unusable items back to the bag (0x414b93); byte EV[4081] ≠ 0 → abilities recomputed (0x4149cf); battle: the unit
## refreshed; popup 0x479a01.
func op_op_52(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if in_battle() and pid >= 0x400 and pid < 0x403:
		pid = current_unit_person()
	if pid < 0 or pid >= 0x400:
		return
	Game.change_class(pid, u16(ins, 1) & 0xff)
	on_field_written(17, pid)


## 0x39 武将等级提升 (0x4148f8): silent level-up 0x4073f3(rec, n, 0) (n = low byte); battle 0x400..0x402 = current unit;
## a battle unit's max HP/MP refreshed (BattleStage via on_field_written).
func op_level_up(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if in_battle() and pid >= 0x400 and pid < 0x403:
		pid = current_unit_person()
	if pid < 0 or pid >= 0x400:
		return
	Game.person(pid).level_up(arg(ins, 1) & 0xff)
	on_field_written(18, pid)


## ops 0x36 / 0x38 (attribute getter 0x422e9d, §11.5); BattleStage overrides for its selectors and unit HP/MP.
func op_test_attr(ins: Dictionary) -> bool:
	return PersonAttrs.test(self, u16(ins, 0), u16(ins, 1), arg(ins, 2), u16(ins, 3))


func op_set_attr(ins: Dictionary) -> void:
	PersonAttrs.set_attr(self, u16(ins, 0), u16(ins, 1), u16(ins, 2), arg(ins, 3))


# ------------------------------------------------------------------ sortie (ops 0x06 / 0x4a / toolbar 出征)
## Sortie list builder 0x418597(param): candidates = the protagonist first unless the "may not sortie" ring 0x4b0a04
## holds a 0, then the forced persons of the ring 0x4b09dc that are members (0 / 0xffff skipped); max = byte 0x4b09db
## raised to the count; if they differ, the other members (person order, not in 0x4b0a04) are offered by the selection
## window 0x45e6b3. The result goes to u16[] 0x48b350 (0xffff end). param ≠ 1 counts one more forced entry (the
## original's list keeps a null there, so nobody can be added) and resets the rings when [0x4b0a30] == 0.
func build_sortie(param := 1) -> bool:
	var excl: Array[int] = []
	var any_zero := false
	for i in 20:
		var e := Mem.r16(Game.SORTIE_EXCLUDED + 2 * i)
		if e == 0:
			any_zero = true
		excl.append(e)
	var forced: Array[int] = []
	if not any_zero:
		forced.append(0)
	for i in 20:
		var f := Mem.r16(Game.SORTIE_FORCED + 2 * i)
		if f != 0 and f != 0xffff and f < 0x400 and Game.is_member(f):
			forced.append(f)
	var count := forced.size() + (0 if param == 1 else 1)
	if Mem.r8(Game.SORTIE_MAX) < count:
		Mem.w8(Game.SORTIE_MAX, count)
	var maxn := Mem.r8(Game.SORTIE_MAX)
	var lst: Array[int] = forced.duplicate()
	if maxn != count and param == 1:
		lst = await SortieScreen.choose(ui, self, maxn, forced, excl)
	for k in lst.size():
		Mem.w16(Game.SORTIE_LIST + 2 * k, lst[k])
	Mem.w16(Game.SORTIE_LIST + 2 * lst.size(), 0xffff)
	if param != 1 and Mem.r32(Game.SORTIE_RING + 4) == 0:
		Game.reset_sortie_params()
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("  sortie forced=%s max=%d -> %s" % [forced, maxn, lst])
	return not lst.is_empty()


## 0x06 我军出场限制 (0x415b4f + 0x415c0d): enable, max (0 → 1), then 5 forced persons → the ring 0x4b09dc and 5 → the
## ring 0x4b0a04 (bases wrap at 20). enable = 0: max = 1, rings reset (0x41c96d), toolbar dialogs closed (0x420660);
## else [0x501fff] = 1 and the toolbar shown with its buttons (0x419959(tb, 0)).
func op_battle_select_units(ins: Dictionary) -> void:
	var en := u16(ins, 0)
	var mx := arg(ins, 1)
	var base := Mem.r32(Game.SORTIE_RING)
	var last := base
	for k in 5:
		last = k + base
		Mem.w16(Game.SORTIE_FORCED + 2 * last, u16(ins, 2 + k))
	last += 1
	Mem.w32(Game.SORTIE_RING, 0 if last == 20 else last)
	var base2 := Mem.r32(Game.SORTIE_RING + 4)
	var last2 := base2
	for k in 5:
		last2 = k + base2
		Mem.w16(Game.SORTIE_EXCLUDED + 2 * last2, u16(ins, 7 + k))
	last2 += 1
	Mem.w32(Game.SORTIE_RING + 4, 0 if last2 == 20 else last2)
	Mem.w8(Game.SORTIE_MAX, 1 if mx == 0 else mx & 0xff)
	if en & 0xff == 0:
		Mem.w8(Game.SORTIE_MAX, 1)
		Game.reset_sortie_params()
		toolbar_close()
	else:
		Mem.w8(0x501fff, 1)
		toolbar_show(true)


## 0x07 出战测试 (0x40b900): true once after 出征 (flag 0x4ae4c0, cleared when read).
func op_test_pending(_ins: Dictionary) -> bool:
	if Mem.r32(0x4ae4c0) != 0:
		Mem.w32(0x4ae4c0, 0)
		return true
	return false


## 0x4b 我军出场设定 (0x415e33): slot, x, y (int32), dir, hidden (u16, −1 → 0). Word EV[4057] == 0xffff (battle): the
## deployment entry of the slot (person ≠ 0xffff, flags & 3 == 0) gets x, y and flags = dir bits | hidden·4. Else the
## R-file sortie preview: u32 at 0x507680 + 3·slot = {x, y, hidden, 0xff}.
func op_op_4b(ins: Dictionary) -> void:
	var slot := arg(ins, 0)
	var x := arg(ins, 1) & 0xff
	var y := arg(ins, 2) & 0xff
	var d := u16(ins, 3)
	var hidden := u16(ins, 4)
	if hidden == 0xffff:
		hidden = 0
	if Mem.r16(Mem.EV + 4 * 4057) == 0xffff:
		var e := 0x494fd4 + 16 * slot
		if Mem.r32(e) != 0xffff and Mem.r32(e + 8) & 3 == 0:
			Mem.w16(e + 4, x | (y << 8))
			Mem.w32(e + 8, (4 if hidden != 0 else 0) | dir_bits(d))
	else:
		Mem.w32(0x507680 + 3 * slot, x | (y << 8) | ((hidden & 0xff) << 16) | 0xff000000)


## Deployment direction bits 0x449b29: dir 0 → 0x20, 1 → 8, 3 → 0x10, else 0x40.
static func dir_bits(d: int) -> int:
	match d & 0xff:
		0: return 0x20
		1: return 8
		3: return 0x10
	return 0x40


# ------------------------------------------------------------------ duel / endings / game over
## 0x68 单挑开始 (0x4103ee): A, B < 0x400 and A ≠ B (else status 0); byte EV[4087] == 0 → the classic duel (System A,
## DuelLayer), ≠ 0 → the 练武场 small-window fight (battle/training.gd, docs/duel.md §3).
func op_duel_setup(ins: Dictionary) -> void:
	var a := u16(ins, 0)
	var b := u16(ins, 1)
	if a >= 0x400 or b >= 0x400 or a == b:
		return
	if Mem.ev(4087) & 0xff != 0:
		await training_fight(a, b, u16(ins, 2))
		return
	await story_duel(a, b, u16(ins, 2))


## The 练武场 fight of op 0x68 (0x41e6a4); its result goes to EV[4084] (0 lose, 1 win, 2 draw).
func training_fight(a: int, b: int, c: int) -> void:
	if ResourceLoader.exists("res://src/battle/training.gd"):
		var tr: Variant = load("res://src/battle/training.gd")
		if tr != null and tr.has_method("script_fight"):
			await tr.script_fight(self, a, b, c)
			return
	push_warning("练武场 fight not available yet: EV[4084] stays %d" % Mem.ev(4084))


## Classic duel outside a battle (System A): StoryStage hosts the DuelLayer.
func story_duel(_a: int, _b: int, _backdrop: int) -> void:
	pass


## 0x0f 结局设定 (0x4158af → 0x414050(0, v)).
func op_screen_mode(ins: Dictionary) -> void:
	await ending_routine(0, u16(ins, 0))


## 0x414050(mode, v): v ≤ 2 → ending emblem byte v of SV\SV.E5S = 1 (0x41a1c6); 0x42bed5(v, mode): audio stopped;
## mode 0 → video 2 (End.Avi); mode ≠ 1 → the ending show 0x4317ab(v); mode 0 → program exit (0x415692; the port
## returns to the title).
func ending_routine(mode: int, v: int) -> void:
	if v & 0xff <= 2:
		SpecialFuncs.sv_write(v & 0xff, 1)
	Audio.stop_bgm()
	SoundMap.stop_loop()
	if mode == 0:
		await play_video(2)
	if mode != 1:
		await Game.main.ending_show(v)
	if mode == 0:
		Game.ending_reached = true
		if vm:
			vm.abort = true
			vm.active = false
		Game.main.to_title()


## 0x6a Game Over指令 (0x415692 → 0x42b5e1(0)): the original tears down and exits the program; the port returns to the
## title.
func op_op_6a(_ins: Dictionary) -> void:
	Audio.stop_bgm()
	SoundMap.stop_loop()
	Game.ending_reached = true
	if vm:
		vm.abort = true
		vm.active = false
	Game.main.to_title()
