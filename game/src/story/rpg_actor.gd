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
## (0x42836e), so it walks that axis first, then the other. (The original's distance field, 0x429266, also routes
## around blocked cells; that is not modelled.)
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


## Walk to (x, y) step by step (facing each step's direction), then face `end_dir`: op 0x32 → 0x429159, which
## turns a facing above 3 into 0. end_dir -1 keeps the last step's facing.
func walk_to(x: int, y: int, end_dir: int = -1, fast := false) -> void:
	walking = true
	_anim_t = 0.0
	var st := 0.0 if fast else STEP_TIME
	for d in walk_steps(gx, gy, x, y):
		dir = d
		await _tween_to(foot_point(gx + STEP_DX[d], gy + STEP_DY[d], gz), st)
		gx += STEP_DX[d]
		gy += STEP_DY[d]
		_place()
	walking = false
	if end_dir >= 0:
		dir = end_dir if end_dir <= 3 else 0
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
