class_name Shapes
extends RefCounted
## Attack/strategy range codes and effect-area codes (docs/rules.md §6, assets/data/shapes.json).

static var _d: Dictionary = {}


static func _data() -> Dictionary:
	if _d.is_empty():
		_d = Assets.json("data/shapes.json")
	return _d


## Cells (absolute) reachable by range `code` from `c`. 10 = whole map, 11 = none.
static func range_cells(code: int, c: Vector2i, w: int, h: int, include_origin := false) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if code == 11:
		if include_origin:
			out.append(c)
		return out
	if code == 10:
		for y in h:
			for x in w:
				out.append(Vector2i(x, y))
		return out
	var r: Dictionary = _data()["range"].get(str(code), {})
	for o in r.get("cells", []):
		var p := c + Vector2i(int(o[0]), int(o[1]))
		if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h:
			out.append(p)
	if include_origin and not out.has(c):
		out.append(c)
	return out


## Effect area of `code` around target `t`, cast from `src`.
static func area_cells(code: int, src: Vector2i, t: Vector2i, w: int, h: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [t]
	var a: Dictionary = _data()["area"].get(str(code), {})
	var cells: Variant = a.get("cells", [])
	var d := t - src
	var step := Vector2i(signi(d.x), signi(d.y))
	if cells is String:
		if cells == "line":
			var n := int(a.get("length", 1))
			if code == 12:
				n = maxi(w, h)
			var p := t
			for k in n:
				p += step
				if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h:
					break
				out.append(p)
		elif cells == "sweep":
			if absi(d.x) <= 1 and absi(d.y) <= 1:
				if d.x == 0 or d.y == 0:
					var perp := Vector2i(step.y, step.x)
					for p in [t + perp, t - perp]:
						out.append(p)
				else:
					out.append(src + Vector2i(d.x, 0))
					out.append(src + Vector2i(0, d.y))
		elif cells == "caster8":
			out.clear()
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if dx != 0 or dy != 0:
						out.append(src + Vector2i(dx, dy))
	else:
		for o in cells:
			out.append(t + Vector2i(int(o[0]), int(o[1])))
	var clipped: Array[Vector2i] = []
	for p in out:
		if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h and not clipped.has(p):
			clipped.append(p)
	return clipped
