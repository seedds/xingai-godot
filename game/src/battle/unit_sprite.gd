class_name UnitSprite
extends Node2D
## Battle unit graphic (Unit_mov 48×48 frames, Unit_atk 64×64 frames drawn at (−8, −8), Unit_spc 48×48; docs/gfx.md §3).
## Directions use the original engine codes: 0 up, 1 right, 2 down, 3 left; right-facing frames are the left-facing
## ones mirrored (0x40d38c).
##   mov: 0-1 walk down, 2-3 walk up, 4-5 walk left, 6 stand down, 7 stand up, 8 stand left, 9-10 weak
##   atk: 0-3 attack down, 4-7 attack up, 8-11 attack left
##   spc: 0 defend down, 1 defend up, 2 defend left, 3 hurt, 4 cheer

enum Pose { STAND, WALK, ATTACK, DEFEND, HURT, CHEER, WEAK, STILL }

const MOV_W := 48
const ATK_W := 64

var entry := 0
var dir := 2
var pose := Pose.STAND
var frame := 0
var anim_time := 0.0
var walk_speed := 4.0      # frames per second of the idle / walk cycle
var greyed := false        # finished its action (0x43eae4: acted units are drawn grey)
var flash := 0.0           # white blend (critical flash 0x40e9e5, white fade of 0x4419b6)
var tint := Color(0, 0, 0, 0)   # colour blend: rgb, a = amount (hit: red 0xff0000 at 40 %, 0x404388)
var fade := 1.0
var offset_px := Vector2.ZERO
var shrink := 1.0          # height factor (silent retreat 0x4419b6 kind 1: the frame sinks away)
var _mov: Texture2D
var _atk: Texture2D
var _spc: Texture2D
var _shader_mat: ShaderMaterial

static var _grey_shader: Shader


func _init() -> void:
	if _grey_shader == null:
		_grey_shader = Shader.new()
		_grey_shader.code = """
shader_type canvas_item;
uniform float grey = 0.0;
uniform float flash = 0.0;
uniform vec4 tint = vec4(0.0);
void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	float l = dot(c.rgb, vec3(0.3, 0.59, 0.11));
	c.rgb = mix(c.rgb, vec3(l * 0.85), grey);
	c.rgb = mix(c.rgb, tint.rgb, tint.a);
	c.rgb = mix(c.rgb, vec3(1.0), flash);
	COLOR = c;
}
"""
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = _grey_shader
	material = _shader_mat


func set_entry(e: int) -> void:
	entry = e
	_mov = Assets.tex("gfx/units/mov/%03d.png" % e)
	_atk = Assets.tex("gfx/units/atk/%03d.png" % e)
	_spc = Assets.tex("gfx/units/spc/%03d.png" % e)
	queue_redraw()


func set_pose(p: int, d: int = -1) -> void:
	pose = p
	if d >= 0:
		dir = d
	frame = 0
	anim_time = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	anim_time += delta
	if pose == Pose.WALK or pose == Pose.WEAK or pose == Pose.STAND:
		var f := int(anim_time * walk_speed) % 2
		if f != frame:
			frame = f
			queue_redraw()
	_shader_mat.set_shader_parameter("grey", 1.0 if greyed else 0.0)
	_shader_mat.set_shader_parameter("flash", flash)
	_shader_mat.set_shader_parameter("tint", tint)
	modulate.a = fade


## Direction → (row for down / up / left, mirrored).
func _dir_index() -> Array:
	match dir:
		0: return [1, false]
		1: return [2, true]
		3: return [2, false]
		_: return [0, false]


func _draw() -> void:
	var di: Array = _dir_index()
	var d: int = di[0]
	var mirror: bool = di[1]
	var tex: Texture2D = _mov
	var fw := MOV_W
	var idx := 0
	match pose:
		Pose.STAND, Pose.WALK:
			idx = d * 2 + frame
		Pose.STILL:
			idx = 6 + d
		Pose.WEAK:
			idx = 9 + frame
			mirror = false
		Pose.ATTACK:
			tex = _atk
			fw = ATK_W
			idx = d * 4 + clampi(frame, 0, 3)
		Pose.DEFEND:
			tex = _spc
			idx = d
		Pose.HURT:
			tex = _spc
			idx = 3
			mirror = false
		Pose.CHEER:
			tex = _spc
			idx = 4
			mirror = false
	if tex == null:
		draw_rect(Rect2(4, 4, 40, 40), Color(1, 0, 1, 0.6))
		return
	var src := Rect2(0, idx * fw, fw, fw)
	var off := offset_px + (Vector2.ZERO if fw == MOV_W else Vector2(-8, -8))
	var h := fw * shrink
	var dst := Rect2(off + Vector2(0, fw - h), Vector2(fw, h))
	if mirror:
		draw_set_transform(Vector2(dst.position.x + fw, dst.position.y), 0, Vector2(-1, 1))
		draw_texture_rect_region(tex, Rect2(Vector2.ZERO, dst.size), src)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	else:
		draw_texture_rect_region(tex, dst, src)


## Still frame of the standing pose (mov frames 6..8).
func set_still(d: int) -> void:
	dir = d
	pose = Pose.STILL
	queue_redraw()


## Show one attack frame (0..3) in direction d.
func attack_frame(d: int, f: int) -> void:
	pose = Pose.ATTACK
	dir = d
	frame = f
	queue_redraw()


## Play the 4-frame attack animation with the given per-frame durations (seconds).
func play_attack(d: int, frame_time := 0.09) -> void:
	set_pose(Pose.ATTACK, d)
	for f in 4:
		frame = f
		queue_redraw()
		await get_tree().create_timer(frame_time * (2.0 if f == 2 else 1.0)).timeout
	set_pose(Pose.STAND, d)
