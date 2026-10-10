class_name UnitSprite
extends Node2D
## Battle unit graphic (48x48 move/special frames, 64x64 attack frames).
## Directions use the original engine codes: 0 up, 1 right, 2 down, 3 left.
## Right-facing frames are the left-facing ones mirrored.

enum Pose { STAND, WALK, ATTACK, DEFEND, HURT, CHEER, WEAK }

const MOV_W := 48
const ATK_W := 64

var entry := 0
var dir := 2
var pose := Pose.STAND
var frame := 0
var anim_time := 0.0
var walk_speed := 4.0      # frames per second for walking
var greyed := false        # already acted this turn
var flash := 0.0           # white flash amount (hit)
var fade := 1.0
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
void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	float l = dot(c.rgb, vec3(0.3, 0.59, 0.11));
	c.rgb = mix(c.rgb, vec3(l * 0.85), grey);
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
	modulate.a = fade


## Map direction to (frame-base for up/down/left, mirrored)
func _dir_index() -> Array:
	match dir:
		0: return [1, false]   # up
		1: return [2, true]    # right = mirrored left
		3: return [2, false]   # left
		_: return [0, false]   # down


func _draw() -> void:
	var di: Array = _dir_index()
	var d: int = di[0]
	var mirror: bool = di[1]
	var tex: Texture2D = _mov
	var fw := MOV_W
	var idx := 0
	match pose:
		Pose.STAND:
			# CCZ units idle with the 2-frame walk cycle on the battlefield
			idx = d * 2 + frame
		Pose.WALK:
			idx = d * 2 + frame
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
	var off := Vector2.ZERO if fw == MOV_W else Vector2(-8, -8)
	if mirror:
		draw_set_transform(Vector2(off.x + fw, off.y), 0, Vector2(-1, 1))
		draw_texture_rect_region(tex, Rect2(0, 0, fw, fw), src)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
	else:
		draw_texture_rect_region(tex, Rect2(off, Vector2(fw, fw)), src)


## Still frame used for the standing pose (no animation): stand_down/up/left.
func set_still(d: int) -> void:
	dir = d
	pose = Pose.STAND
	queue_redraw()


## Play the 4-frame attack animation. Returns after it finishes.
func play_attack(d: int, frame_time := 0.09) -> void:
	set_pose(Pose.ATTACK, d)
	for f in 4:
		frame = f
		queue_redraw()
		await get_tree().create_timer(frame_time * (2.0 if f == 2 else 1.0)).timeout
	set_pose(Pose.STAND, d)
