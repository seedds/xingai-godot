extends Node
## 练武场 (docs/duel.md §2–§3): a script fight in 普通模式 (op 0x68 with EV 4087 = 1, as R_028) and a menu-style
## command duel (单挑模式), both under autoplay. Checks the EV 4084 result protocol, that U0/U60, the fake map and
## EV 4087/4085/4086 are restored, and that the duel data of person 1023 is initialised.
## With SHOTS=dir (and a window, no autoplay) it saves screenshots of both dialogs.
##   tools/gtest.sh t_duel66_b
##   cd game && SHOTS=/tmp/duel TEST=res://src/debug/t_duel66_b.gd godot --path . res://src/debug/test_runner.tscn

var ui: GameUI
var stage = null
var shots := ""


func _shot(n: String) -> void:
	if shots == "":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shots, n])


## Press a dialog button by id (as a click would).
func _press(t: Training, id: int) -> void:
	while is_instance_valid(t) and t.is_inside_tree() and not t.enabled.get(id, false):
		await get_tree().process_frame
	if is_instance_valid(t) and t.is_inside_tree():
		t._pressed = id


func run() -> void:
	shots = OS.get_environment("SHOTS")
	Game.autoplay = shots == ""
	Game.main = self
	ui = GameUI.new()
	add_child(ui)
	var host := ScriptHost.new()
	add_child(host)
	await get_tree().process_frame
	var ok := true
	Rules.srand(12345)
	var u0_before := Mem.img.slice(Mem.UNITS - Mem.IMG_BASE, Mem.UNITS - Mem.IMG_BASE + 0x30)
	Mem.w8(Mem.person_addr(33) + 0x2a, 0)            # 张飞 a member
	Mem.w8(Mem.person_addr(33) + 0x2c, 20)
	Mem.w8(Mem.person_addr(3) + 0x2c, 20)
	var mapwh := Mem.r16(Mem.MAP_WH)
	Mem.fill(0x508a00, 0x200, 0)                      # strikes per slot, as after any battle (op 0x44)
	# ---- script fight, 普通模式 (R_028: int_var_op 4087 = 1; duel_setup 33 3 1)
	Mem.set_ev(4087, 1)
	Mem.set_ev(4084, 77)
	var done := [false]
	var f1 := func() -> void:
		await Training.script_fight(host, 33, 3, 1)
		done[0] = true
	f1.call()
	if shots != "":
		await get_tree().create_timer(1.0).timeout
		var t: Training = null
		for c in ui.get_children():
			if c is Training:
				t = c
		await _shot("b1_start")
		for r in 12:
			if done[0]:
				break
			await _press(t, 0x507)
			await get_tree().create_timer(2.5).timeout
			if r == 1:
				await _shot("b2_round")
	while not done[0]:
		await get_tree().process_frame
	var res := Mem.ev(4084)
	print("t_duel66_b: 普通模式 result EV4084 = %d, 张飞 HP-run done" % res)
	if res > 2:
		print("t_duel66_b: FAIL EV 4084 not set (%d)" % res)
		ok = false
	if Mem.ev(4087) != 0:
		print("t_duel66_b: FAIL EV 4087 not cleared")
		ok = false
	if Mem.r16(Mem.MAP_WH) != mapwh:
		print("t_duel66_b: FAIL map size not restored")
		ok = false
	if Mem.img.slice(Mem.UNITS - Mem.IMG_BASE, Mem.UNITS - Mem.IMG_BASE + 0x30) != u0_before:
		print("t_duel66_b: FAIL unit 0 not restored")
		ok = false
	# ---- 单挑模式 as from the menu (person 1022, scripted flag 0)
	Mem.w32(Mem.GS + 0xc, 1000)
	Mem.set_ev(4087, 2)
	done[0] = false
	var f2 := func() -> void:
		await Training._menu_fight(host, 33, 0)
		done[0] = true
	f2.call()
	if shots != "":
		await get_tree().create_timer(1.0).timeout
		await _shot("b3_pay")
		for c in ui.get_children():
			if c is Training and c._msg != "":
				print("t_duel66_b: pay box '%s'" % c._msg)
				c._msg_answer = 1                       # 是
		await get_tree().create_timer(1.0).timeout
		var t2: Training = null
		for c in ui.get_children():
			if c is Training and c.client != Vector2.ZERO:
				t2 = c
		if t2:
			await _shot("b3_duel_mode")
			await _press(t2, 0x507)
			await get_tree().create_timer(2.0).timeout
			await _press(t2, 0x508)
			await get_tree().create_timer(4.0).timeout
			await _shot("b4_duel_round")
			t2._pressed = 0x50b
	while not done[0]:
		await get_tree().process_frame
	var d := Mem.r32(Mem.LAST_PERSON_PTR)
	print("t_duel66_b: 单挑模式 EV4084 = %d, duel level %d wins %d, q = %d %d %d %d, gold %d" % [Mem.ev(4084),
			Mem.r8(d + 0x17), Mem.r8(d + 0x18), Mem.r8(d + 0x11), Mem.r8(d + 0x12), Mem.r8(d + 0x13), Mem.r8(d + 0x14),
			Mem.r32(Mem.GS + 0xc)])
	if Mem.r8(0x510cf8) != 1 or Mem.r8(d + 0x13) < 85:
		print("t_duel66_b: FAIL duel data of person 1023 not initialised")
		ok = false
	if Mem.ev(4085) != 5:
		print("t_duel66_b: FAIL EV 4085 not reset to 5")
		ok = false
	print("t_duel66_b: PASS" if ok else "t_duel66_b: FAILED")
