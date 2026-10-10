extends Node
## The 6.6 script windows (ui/windows66.gd): opens each one, checks that it waits and closes on clicks, and with
## OUT=dir (run with a window, not --headless) saves a screenshot of each to dir/NN_name.png.
##   cd game && OUT=/tmp/ui66 TEST=res://src/debug/t_ui66_windows.gd godot --path . res://src/debug/test_runner.tscn
## Prints "t_ui66_windows: PASS".

class FakeStage:
	extends Node
	var battle := false
	var anchors := {}

	func talk_anchor(pid: int) -> Variant:
		return anchors.get(pid, null)

	func in_battle() -> bool:
		return battle


class FakeMain:
	extends Node
	var stage: Node


var ok := true
var out := ""
var shot := 0
var ui: GameUI


func run() -> void:
	out = OS.get_environment("OUT")
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var main := FakeMain.new()
	var st := FakeStage.new()
	main.stage = st
	add_child(main)
	main.add_child(st)
	Game.main = main
	var bg := Sprite2D.new()
	bg.centered = false
	bg.position = Vector2(0, 40)
	bg.texture = Assets.tex("gfx/backgrounds/052.jpg") if Assets.exists("gfx/backgrounds/052.jpg") else null
	add_child(bg)
	ui = GameUI.new()
	add_child(ui)
	await get_tree().process_frame
	st.anchors = {0: {"x": 300, "y": 330, "dir": 1}, 1: {"x": 200, "y": 160, "dir": 2}}

	ui.title_text("二龙的天下")
	ui.place_name("陈留　曹操军大本营")

	# talk windows: person 0 (forced left, actor low → window on top), person 1 (other side), no portrait
	await _window("talk_p0", func() -> void: await ui.talk(0, "我是[C0D曹操]，字孟德。\n天下大乱，正是英雄用武之时。\n第三行。\n第四行在下一页。"), 2)
	await _window("talk_p1", func() -> void: await ui.talk(1, "主公，夏侯惇在此！"), 1)
	await _window("talk_plain", func() -> void: await ui.talk(-1, "这是没有头像的信息框。\n第二行\n第三行\n第四行"), 1)
	await _window("message2", func() -> void: await ui.message(2, "得到了倚天剑。"), 1, false, false, false, 0.8)
	var r := [-1]
	await _window("choice", func() -> void: r[0] = await ui.choose_dialog(["是", "否", "再想想"], 0), 0, true)
	if r[0] != 1:
		_fail("choice returned %d, want 1" % r[0])
	await _window("yes_no", func() -> void: r[0] = 1 if await ui.yes_no("可以吗？") else 0, 0, false, true)
	await _window("dialog3", func() -> void: await ui.dialog3([804, 837, -1], 4, "先生，[C0D请]。\n第二行。"), 1)
	await _window("dialog3_b", func() -> void: await ui.dialog3([0, 1, 2], 2, "三人对话的文字。"), 1)
	await _window("modal", func() -> void: await ui.choice_modal(["普通模式", "困难模式", "地狱模式"], true, 2), 0, false, false, true)
	await _window("caption", func() -> void:
		await ui.caption("行刺失败后，曹操为了躲避董卓的追捕，", 0, 0, 0)
		await ui.caption("逃离了洛阳。", 1, 0, 0)
		await ui.caption("稍作休息后，他就把檄文发往各地。", 1, 1, 1), 1)
	await ui.portrait_show(0, 496, 124)
	await ui.portrait_move(0, 400, 200)
	await _shoot("portrait")
	await ui.portrait_hide(0)
	# 历史情报: two records written as op 0x16 does ("&" + category + text)
	var recs := PackedByteArray()
	for e in [[1, "1曹操起兵。\n讨伐董卓。"], [2, "2得到[C0D倚天剑]。"], [1, "3攻下*/5座城。"]]:
		recs.append(0x26)
		recs.append(e[0])
		recs.append_array(str(e[1]).to_multibyte_char_buffer("GBK"))
	Mem.set_ev(5, 12)
	for i in recs.size():
		Mem.w8(HistoryWin66.BUF + i, recs[i])
	Mem.w32(HistoryWin66.LEN, recs.size())
	var hl := HistoryWin66.ordered()
	if hl.size() != 4 or str(hl[2][1]) != "攻下12座城。":
		_fail("history lines %s" % [hl])
	var hdone := [false]
	var hrun := func() -> void:
		await ui.history_window()
		hdone[0] = true
	hrun.call()
	await get_tree().create_timer(0.5).timeout
	await _shoot("history")
	(_last_window() as HistoryWin66).closed.emit()
	await get_tree().process_frame
	if not hdone[0]:
		_fail("history window did not close")
	await _window("chapter", func() -> void: await ui.chapter_title(2, "河北之争"), 2)
	Game.main = null
	print("t_ui66_windows: PASS" if ok else "t_ui66_windows: FAILED")


func _fail(msg: String) -> void:
	ok = false
	print("t_ui66_windows: FAIL ", msg)


## Open a window with `f`, screenshot it, then click `clicks` times (or pick choice row 1 / press 是 / tick the
## sub-34 boxes and press 确定) and check that it closed.
func _window(name: String, f: Callable, clicks: int, choice := false, yesno := false, modal := false, delay := 2.5) -> void:
	var done := [false]
	var runner := func() -> void:
		await f.call()
		done[0] = true
	runner.call()
	await get_tree().create_timer(delay).timeout
	await _shoot(name)
	if choice:
		var c: ChoiceWin66 = _last_window()
		c.picked.emit(1)
	elif yesno or modal:
		var d: SysDialog66 = _last_window()
		if modal:
			d._toggle(0)
			d._toggle(2)
			await get_tree().process_frame
			await _shoot(name + "_ticked")
		d._click(0)
	for k in clicks:
		Game.clicks += 1
		await get_tree().create_timer(0.6).timeout
	var t := 0.0
	while not done[0] and t < 8.0:
		await get_tree().create_timer(0.2).timeout
		t += 0.2
	if not done[0]:
		_fail("%s did not close" % name)


func _last_window() -> Node:
	var root: Control = ui._win_root
	return root.get_child(root.get_child_count() - 1)


func _shoot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	shot += 1
	get_viewport().get_texture().get_image().save_png("%s/%02d_%s.png" % [out, shot, name])
