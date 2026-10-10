extends Node
## The message box grows to fit long texts (it measured the typewriter's still-hidden text as one line, so a
## 9-line 胜利条件 window was cut off). Prints "t_dialog: PASS". With OUT=file.png (and a window) it also
## saves a screenshot of the box.

const TEXT := "胜利条件\n★·击退尚师徒\n★·我军部队到达指定地点\n\n失败条件\n☆·秦琼败退\n☆·管毅败退\n☆·大本营被敌军占领\n☆·回合数超过25"


func run() -> void:
	var ok := true
	var ui := GameUI.new()
	add_child(ui)
	await get_tree().process_frame
	var d: DialogBox = ui.dialog
	var closed := [false]                 # lambdas capture locals by value: share a reference instead
	var talk := func() -> void:
		await d.talk(null, "", TEXT, false)   # as the 胜利条件 menu entry and op 0x19 show it
		closed[0] = true
	talk.call()
	await get_tree().process_frame
	var lh := Assets.font().get_height(UIStyle.FONT_SIZE) + 4
	var lines := d._label.get_line_count()
	if lines != 9:
		print("t_dialog: FAIL measured %d lines, want 9" % lines)
		ok = false
	if d._box.size.y < 9 * lh or not Rect2(0, 0, 640, 480).encloses(d._box):
		print("t_dialog: FAIL box %s does not hold 9 lines of %.0f px on the screen" % [d._box, lh])
		ok = false
	var out := OS.get_environment("OUT")
	if out != "":
		await get_tree().create_timer(1.6).timeout     # let the typewriter finish
		get_viewport().get_texture().get_image().save_png(out)
	for k in 2:                                         # first click shows the rest, the second closes
		var ev := InputEventAction.new()
		ev.action = "ui_accept"
		ev.pressed = true
		get_viewport().push_input(ev, true)
		await get_tree().process_frame
	if not closed[0]:
		print("t_dialog: FAIL the box did not close")
		ok = false
	print("t_dialog: PASS" if ok else "t_dialog: FAILED")
