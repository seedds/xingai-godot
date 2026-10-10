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
	print("t_rpgwalk: PASS" if _ok else "t_rpgwalk: FAILED")
