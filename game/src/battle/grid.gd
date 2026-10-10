class_name Grid
extends RefCounted
## Grid helpers: reachable cells (Dijkstra with per-cell costs), path reconstruction,
## and range shapes. Cells are Vector2i(x, y).

const DIRS: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0)]


## cost_fn(cell: Vector2i) -> int   (movement cost to ENTER cell; <0 or >=999 means impassable)
## blocked_fn(cell: Vector2i) -> bool (cell occupied by a unit you can't pass through)
## stop_fn(cell: Vector2i) -> bool   (entering the cell ends movement, e.g. zone of control)
## Returns {cell: remaining_mp}; also fills `parents` {cell: prev_cell} if given.
static func reachable(start: Vector2i, mp: int, w: int, h: int, cost_fn: Callable, blocked_fn: Callable, stop_fn: Callable = Callable(), parents: Dictionary = {}) -> Dictionary:
	var best := {start: mp}
	parents.clear()
	var open: Array = [[mp, start]]
	while not open.is_empty():
		# pop max remaining
		var bi := 0
		for i in range(1, open.size()):
			if open[i][0] > open[bi][0]:
				bi = i
		var cur = open[bi]
		open.remove_at(bi)
		var rem: int = cur[0]
		var c: Vector2i = cur[1]
		if best.get(c, -1) > rem:
			continue
		if c != start and stop_fn.is_valid() and stop_fn.call(c):
			continue
		for d in DIRS:
			var n := c + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h:
				continue
			var cost: int = cost_fn.call(n)
			if cost < 0 or cost >= 999:
				continue
			if blocked_fn.call(n):
				continue
			var r := rem - cost
			if r < 0:
				continue
			if r > best.get(n, -1):
				best[n] = r
				parents[n] = c
				open.append([r, n])
	return best


static func path_to(parents: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var c := goal
	var guard := 0
	while c != start and guard < 1000:
		out.push_front(c)
		if not parents.has(c):
			return []
		c = parents[c]
		guard += 1
	return out


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## Offsets list -> absolute cells clipped to map.
static func apply_offsets(center: Vector2i, offsets: Array, w: int, h: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for o in offsets:
		var c := center + Vector2i(o[0], o[1])
		if c.x >= 0 and c.y >= 0 and c.x < w and c.y < h:
			out.append(c)
	return out


## Diamond of radius r (excluding cells closer than rmin).
static func diamond(rmin: int, rmax: int) -> Array:
	var out := []
	for dy in range(-rmax, rmax + 1):
		for dx in range(-rmax, rmax + 1):
			var d := absi(dx) + absi(dy)
			if d >= rmin and d <= rmax:
				out.append([dx, dy])
	return out


## Direction code from a delta, engine convention: 0 up, 1 right, 2 down, 3 left.
static func dir_of(delta: Vector2i) -> int:
	if absi(delta.x) > absi(delta.y):
		return 3 if delta.x < 0 else 1
	return 0 if delta.y < 0 else 2


static func dir_vec(d: int) -> Vector2i:
	match d:
		0: return Vector2i(0, -1)
		1: return Vector2i(1, 0)
		3: return Vector2i(-1, 0)
	return Vector2i(0, 1)
