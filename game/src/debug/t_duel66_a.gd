extends Node
## Scripted duel (system A, docs/duel.md §1) hosted outside a battle: the op sequence of a typical script
## (0x68, 0x60 ×2, 0x61, 0x63, 0x64, 0x65 kinds 0..4, 0x66 kinds 0..2, 0x62, 0x5f) through DuelLayer.
## Headless: autoplay, checks the borrowed units 60/11, the EXP award and that the layer closes.
## With SHOTS=dir (and a window, no autoplay) it saves screenshots of the intro, a bubble and the result.
##   tools/gtest.sh t_duel66_a
##   cd game && SHOTS=/tmp/duel TEST=res://src/debug/t_duel66_a.gd godot --path . res://src/debug/test_runner.tscn

var ui: GameUI
var stage = null


class FakeBattle:
	extends ScriptHost
	func in_battle() -> bool:
		return true
var shots := ""


func _shot(n: String) -> void:
	if shots == "":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shots, n])


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
	# 曹操 (0) is a member after this; 1 is not
	Mem.w8(Mem.person_addr(0) + 0x2a, 0)
	Mem.w8(Mem.person_addr(1) + 0x2a, 0xff)
	var lv0 := Mem.r8(Mem.person_addr(0) + 0x2c)
	Mem.w8(Mem.person_addr(1) + 0x2c, lv0 + 5)
	var exp0 := Mem.r8(Mem.person_addr(0) + 0x2d)
	var d := DuelLayer.attach(host)
	var done := [false]
	var f1 := func() -> void:
		await d.setup(1, 0, 15)
		done[0] = true
	f1.call()
	if shots != "":
		await get_tree().create_timer(2.0).timeout
		await _shot("1_intro")
	while not done[0]:
		await get_tree().process_frame
	if not d.active or d.pids != [1, 0] or d.slots != [60, 11]:
		print("t_duel66_a: FAIL setup active=%s pids=%s slots=%s" % [d.active, d.pids, d.slots])
		ok = false
	if (Mem.r32(Mem.UNITS + 60 * 0x30) & 0xfff) != 1 or Mem.r8(Mem.UNITS + 60 * 0x30 + 5) != 2:
		print("t_duel66_a: FAIL unit 60 not borrowed for side 0")
		ok = false
	await d.appear_say(0, "曹操！\n今天就在这里分个高下吧！", 0)
	done[0] = false
	var f2 := func() -> void:
		await d.appear_say(1, "来吧！看我的厉害！", 2)
		done[0] = true
	f2.call()
	if shots != "":
		await get_tree().create_timer(1.5).timeout
		await _shot("2_bubble")
	while not done[0]:
		await get_tree().process_frame
	await d.open()
	for k in 5:
		await d.exchange(1, k, k & 1)
		await d.exchange(0, k, 0)
	for k in 3:
		await d.special(1, k, 0)
	for a in 16:
		await d.action(0, a)
	await d.result(1)
	await _shot("3_result")
	var want := mini(5 * 8 + 32, 200)
	if d.exp_award != want:
		print("t_duel66_a: FAIL exp award %d, want %d" % [d.exp_award, want])
		ok = false
	await d.close()
	if d.visible or d.active:
		print("t_duel66_a: FAIL layer still shown")
		ok = false
	var exp1 := Mem.r8(Mem.person_addr(0) + 0x2d)
	if exp1 == exp0 and Mem.r8(Mem.person_addr(0) + 0x2c) == lv0:
		print("t_duel66_a: FAIL no EXP given (exp %d → %d)" % [exp0, exp1])
		ok = false
	# in-battle path: the persons' own units (0x477adc: first slot with state ≠ 0); no unit → inactive
	var bh := FakeBattle.new()
	add_child(bh)
	await get_tree().process_frame
	var bd := DuelLayer.attach(bh)
	Mem.fill(Mem.UNITS, 250 * 0x30, 0)
	await bd.setup(0, 5, 20)
	if bd.active:
		print("t_duel66_a: FAIL battle duel active without units")
		ok = false
	for e in [[3, 0, 0], [70, 5, 2]]:
		var ua: int = Mem.UNITS + e[0] * 0x30
		Mem.w32(ua, e[1])
		Mem.w8(ua + 5, e[2])
		Mem.w8(ua + 0xc, 2)
	await bd.setup(0, 5, 20)
	if not bd.active or bd.slots != [70, 3] or bd.box != Vector2(8, 84):
		print("t_duel66_a: FAIL battle duel setup active=%s slots=%s box=%s" % [bd.active, bd.slots, bd.box])
		ok = false
	await bd.result(1)
	await bd.close()
	print("t_duel66_a: PASS" if ok else "t_duel66_a: FAILED")
