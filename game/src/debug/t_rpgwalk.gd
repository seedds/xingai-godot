extends Node
## Story-scene walking as in the original (op 0x32 → 0x429159): step codes 0 = -Y, 1 = +X, 2 = +Y, 3 = -X, the
## axis with the larger distance first (X on a tie), facing each step, a final facing above 3 → 0.
## Prints "t_rpgwalk: PASS".

var _ok := true


func _check(ok: bool, what: String) -> void:
	if not ok:
		print("t_rpgwalk: FAIL ", what)
		_ok = false


func run() -> void:
	_check(RpgActor.walk_steps(0, 0, 2, -5) == [0, 0, 0, 0, 0, 1, 1], "longer -Y first: %s" % [RpgActor.walk_steps(0, 0, 2, -5)])
	_check(RpgActor.walk_steps(0, 0, 3, 3) == [1, 1, 1, 2, 2, 2], "tie: X first: %s" % [RpgActor.walk_steps(0, 0, 3, 3)])
	_check(RpgActor.walk_steps(5, 5, 3, 5) == [3, 3], "-X: %s" % [RpgActor.walk_steps(5, 5, 3, 5)])
	_check(RpgActor.walk_steps(5, 5, 5, 5).is_empty(), "no move")
	var a := RpgActor.new()
	add_child(a)
	a.setup(1, 1, 30, 30, 2, 0)
	var seen: Array[int] = []
	var watch := func() -> void:
		while a.walking or seen.is_empty():
			if a.walking and (seen.is_empty() or seen[-1] != a.dir):
				seen.append(a.dir)
			await get_tree().process_frame
	watch.call()
	await a.walk_to(31, 26, -1, false)        # up-right on screen (-Y) for 4 steps, then down-right (+X)
	_check(a.gx == 31 and a.gy == 26, "arrives at (31,26): (%d,%d)" % [a.gx, a.gy])
	_check(seen == [0, 1], "faces up-right (0) then down-right (1) while walking: %s" % [seen])
	await a.walk_to(31, 26, 0xFFFF, true)
	_check(a.dir == 0, "a final facing of 0xFFFF becomes 0: %d" % a.dir)
	await a.walk_to(29, 26, 2, true)
	_check(a.dir == 2 and a.gx == 29, "final facing 2 after walking -X")
	a.queue_free()
	# distance-field route (0x4291f7 / 0x428256) around a wall: a 3×3 actor going +X from (40,50) to (50,50) with
	# blocked cells x 45 for y 44..56 must step round the wall's end and still arrive
	var g := PackedByteArray()
	g.resize(100 * 100 * 2)
	for y in range(44, 57):
		g[2 * (100 * y + 45) + 1] = 0xf0
	RpgActor.grid = g
	var r: Variant = RpgActor.route(40, 50, 50, 50)
	_check(r != null, "route found around the wall")
	if r != null:
		var x := 40
		var y := 50
		var through := false
		for d in r:
			x += RpgActor.STEP_DX[d]
			y += RpgActor.STEP_DY[d]
			if RpgActor.blocked(x, y, 3, 3):
				through = true
		_check(x == 50 and y == 50 and not through, "arrives at (50,50) without crossing the wall: %s" % [r])
	RpgActor.grid = PackedByteArray()
	var open: Variant = RpgActor.route(40, 50, 43, 46)
	_check(open == RpgActor.walk_steps(40, 50, 43, 46), "open-ground route = the axis rule: %s" % [open])
	for y in range(0, 100):
		g[2 * (100 * y + 45) + 1] = 0xf0
	RpgActor.grid = g
	_check(RpgActor.route(40, 50, 50, 50) == null, "no route through a full wall")
	RpgActor.grid = PackedByteArray()
	print("t_rpgwalk: PASS" if _ok else "t_rpgwalk: FAILED")
