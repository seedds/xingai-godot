extends Node
## Window resizing: run the real game, resize the window like a user would (one edge, then the other) and
## check it snaps back to 4:3 with the picture filling it. Needs a window:
##   cd game && OUT=dir TEST=res://src/debug/t_resize.gd godot --path . res://src/debug/test_runner.tscn
func run() -> void:
	var m: Node = load("res://src/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(m)
	await get_tree().create_timer(3.0).timeout
	var out := OS.get_environment("OUT")
	var w := get_window()
	var ok := true
	for step in [["width", Vector2i(w.size.x - 500, w.size.y)], ["height", Vector2i(1100, 1100)], ["both", Vector2i(1000, 700)]]:
		w.size = step[1]
		await get_tree().create_timer(0.8).timeout
		var shot := get_viewport().get_texture().get_image()
		var fills := absi(shot.get_width() - w.size.x) <= 2 and absi(shot.get_height() - w.size.y) <= 2
		var four_three := absi(w.size.x * 3 - w.size.y * 4) <= 4
		ok = ok and fills and four_three
		print("t_resize %s: set %s → window %s, picture %s %s" % [step[0], step[1], w.size, shot.get_size(),
				"ok" if fills and four_three else "BAD"])
		if out != "":
			shot.save_png("%s/%s.png" % [out, step[0]])
	print("t_resize: ", "PASS" if ok else "FAIL")
