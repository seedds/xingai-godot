class_name RpgActor
extends Node2D
## A character in a story (R) scene. Isometric half-cell coordinates (x, y, z).
## Screen mapping (0x4272c5 with camX=60, camY=25, W=200, scene view at y=40):
##   foot point (sx, sy) = (8*(x-y) + 312, 4*(x+y) - 8*z - 152); 48x64 frame drawn at (sx, sy-64).
## Directions (actor +0x2e = sprite row): 0 up-right (-Y, back view), 1 down-right (+X, mirrored front),
## 2 down-left (+Y, front), 3 up-left (-X, mirrored back) — the walk step tables dx@0x48b8c0 = (0,1,0,-1),
## dy@0x48b8b0 = (-1,0,1,0); each step sets +0x2e to its code (0x42a4f5).
## Actions (table 0x48b920): 0 = walk cycle frames [0,1,0,2] (idle shows frame 0),
## 1..17 = single pose frame action+2, 18 = nothing.

const FW := 48
const FH := 64
const STEP_TIME := 0.055

var pid := -1
var sprite_id := 0
var gx := 0
var gy := 0
var gz := 0
var dir := 2
var action := 0
var frame := 0
var walking := false
var _sheet: Texture2D
var _anim_t := 0.0


func setup(person_id: int, spr: int, x: int, y: int, d: int, act: int) -> void:
	pid = person_id
	set_sprite(spr)
	gx = x
	gy = y
	dir = d & 3
	set_action(act)
	_place()


func set_sprite(spr: int) -> void:
	sprite_id = spr
	_sheet = Assets.tex("gfx/rpg_sprites/%03d.png" % spr)
	queue_redraw()


func set_action(a: int) -> void:
	action = a if a <= 18 else 0
	frame = 0 if action == 0 else action + 2
	queue_redraw()


static func foot_point(x: int, y: int, z: int = 0) -> Vector2:
	return Vector2(8 * (x - y) + 312, 4 * (x + y) - 8 * z - 152)


func foot() -> Vector2:
	return foot_point(gx, gy, gz)


func _place() -> void:
	position = foot()
	z_index = int(position.y)
	queue_redraw()


func screen_rect() -> Rect2:
	return Rect2(position + Vector2(0, -FH), Vector2(FW, FH))


func _draw() -> void:
	if action == 18 or _sheet == null:
		return
	var src := Rect2(frame * FW, dir * FH, FW, FH)
	draw_texture_rect_region(_sheet, Rect2(0, -FH, FW, FH), src)


func _process(delta: float) -> void:
	if walking:
		_anim_t += delta
		var seq := [0, 1, 0, 2]
		var f: int = seq[int(_anim_t / 0.12) % 4]
		if f != frame:
			frame = f
			queue_redraw()


const STEP_DX := [0, 1, 0, -1]
const STEP_DY := [-1, 0, 1, 0]


## Direction codes of the steps from (x0, y0) to (x1, y1), as the original's path in open ground: it starts along
## the axis with the larger distance, X on a tie (0x42855f), and keeps its direction while that still gets closer
## (0x428256), so it walks that axis first, then the other — route() on open ground.
static func walk_steps(x0: int, y0: int, x1: int, y1: int) -> Array[int]:
	var dx := x1 - x0
	var dy := y1 - y0
	var sx: Array[int] = []
	for i in absi(dx):
		sx.append(1 if dx > 0 else 3)
	var sy: Array[int] = []
	for i in absi(dy):
		sy.append(2 if dy > 0 else 0)
	if absi(dy) > absi(dx):
		sy.append_array(sx)
		return sy
	sx.append_array(sy)
	return sx


## Pmap grid of the current scene (Pmap.e5 entry = scene byte + 256·EV[4027], loaded by StoryStage like 0x425dcd):
## X×Y u16 cells, high byte 0xf0 = blocked (0x426913). Empty = open ground.
static var grid := PackedByteArray()
static var grid_x := 100
static var grid_y := 100
## Script actors are created 3×3 cells large (0x411dae → 0x428c8e(…, 3, 3, …), actor +0xa / +0xc).
const FOOT := 3


## Grid word of a cell (0x4268ba, z = 0): x past the width reads as blocked; y is not checked by the original (rows
## past the grid read the zeroed buffer behind it → free).
static func cell(x: int, y: int) -> int:
	if x >= grid_x or grid.is_empty():
		return 0xf000 if x >= grid_x else 0
	var o := 2 * (grid_x * y + x)
	if o < 0 or o + 1 >= grid.size():
		return 0
	return grid[o] | (grid[o + 1] << 8)


## Footprint test 0x426913: cells x .. x+w−1 × y−h+1 .. y; any cell with high byte 0xf0 blocks.
static func blocked(x: int, y: int, w: int, h: int) -> bool:
	for yy in range(y - h + 1, y + 1):
		for xx in range(x, x + w):
			if cell(xx, yy) & 0xff00 == 0xf000:
				return true
	return false


## One step (0x4281c7): the stepped footprint must lie inside the grid — right edge x+w−1 < X, x ≥ 0, and (the
## original subtracts h−1 twice) y − (h−1) and y − 2(h−1) within 0..Y−1. Returns the new cell or null.
static func step(x: int, y: int, w: int, h: int, d: int) -> Variant:
	var nx: int = x + STEP_DX[d]
	var ny: int = y + STEP_DY[d]
	for v in [nx + w - 1, nx]:
		if v < 0 or v >= grid_x:
			return null
	for v in [ny - 2 * (h - 1), ny - (h - 1)]:
		if v < 0 or v >= grid_y:
			return null
	return Vector2i(nx, ny)


## Initial heading 0x40aedc(from, to): the axis with the larger distance, X on a tie.
static func heading(x0: int, y0: int, x1: int, y1: int) -> int:
	var dx := x1 - x0
	var dy := y1 - y0
	if dx < 1:
		if dy < 1:
			return 3 if -dy <= -dx else 0
		return 2 if -dx < dy else 3
	if dy < 1:
		return 1 if -dy <= dx else 0
	return 2 if dx < dy else 1


## Route of op 0x32 (0x429159): a breadth-first distance field from the target (0x4291f7: neighbours in direction
## order 0..3, blocked footprints marked, the search stops when it steps onto the start), then the walk 0x42869c /
## 0x428256: from the start, each step takes the neighbour with the smallest distance, trying the last direction first
## and then the next ones clockwise (+1, +2, +3), so it keeps its heading while that still gets closer. Returns the
## direction codes, or null when the target cannot be reached (the actor then does not move).
static func route(x0: int, y0: int, x1: int, y1: int, w := FOOT, h := FOOT) -> Variant:
	var steps: Array[int] = []
	if x0 == x1 and y0 == y1:
		return steps
	var W := grid_x
	var field := PackedInt32Array()
	field.resize(W * 200)
	field.fill(0xfefe)
	var t := y1 * W + x1
	if t < 0 or t >= field.size():
		return null
	field[t] = 0
	var queue: Array[int] = [t]
	var head := 0
	var found := false
	while head < queue.size() and not found:
		var c := queue[head]
		head += 1
		var v := field[c]
		var cx := c % W
		var cy := c / W
		for d in 4:
			var n: Variant = step(cx, cy, w, h, d)
			if n == null:
				continue
			var nx: int = n.x
			var ny: int = n.y
			if nx == x0 and ny == y0:
				found = true
				break
			var i := ny * W + nx
			if i < 0 or i >= field.size() or field[i] != 0xfefe:
				continue
			if blocked(nx, ny, w, h):
				field[i] = 0xfeff
				continue
			field[i] = v + 1
			queue.append(i)
	if not found:
		return null
	var last := heading(x0, y0, x1, y1)
	var x := x0
	var y := y0
	var guard := 0
	while guard < 1000:
		guard += 1
		var best := field[y * W + x] if y * W + x < field.size() else 0xfefe
		if best == 0:
			break
		var pick := -1
		for k in 4:
			var d := (last + k) & 3
			var n: Variant = step(x, y, w, h, d)
			if n == null or blocked(n.x, n.y, w, h):
				continue
			var fv := field[n.y * W + n.x]
			if fv < best:
				best = fv
				pick = d
		if pick < 0:
			break
		last = pick
		steps.append(pick)
		x += STEP_DX[pick]
		y += STEP_DY[pick]
	return steps


## Walk to (x, y) along route() (facing each step's direction), then face `end_dir` (0x429159 turns a value above 3
## into 0). When the target is unreachable the actor neither moves nor turns.
func walk_to(x: int, y: int, end_dir: int = 0xffff, fast := false) -> void:
	var r: Variant = route(gx, gy, x, y)
	if r == null:
		if OS.get_environment("WG_OPSTATS") != "" or OS.get_environment("WG_TRACE_ROUTE") != "":
			print("ROUTE none: person %d (%d,%d) -> (%d,%d)" % [pid, gx, gy, x, y])
		return
	walking = true
	_anim_t = 0.0
	var st := 0.0 if fast else STEP_TIME
	for d in r:
		dir = d
		await _tween_to(foot_point(gx + STEP_DX[d], gy + STEP_DY[d], gz), st)
		gx += STEP_DX[d]
		gy += STEP_DY[d]
		_place()
	walking = false
	dir = end_dir if end_dir >= 0 and end_dir <= 3 else 0
	set_action(action if action != 0 else 0)
	frame = 0 if action == 0 else action + 2
	queue_redraw()


func _tween_to(p: Vector2, t: float) -> void:
	if t <= 0:
		position = p
		return
	var tw := create_tween()
	tw.tween_property(self, "position", p, t)
	await tw.finished
