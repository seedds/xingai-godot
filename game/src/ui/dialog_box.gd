class_name DialogBox
extends Control
## Talk / message window with optional portrait, name and typewriter text.
## Usage: await dialog.talk(face_tex, "name", "text", top)

signal advanced

const CHARS_PER_SEC := 60.0

var face: Texture2D
var speaker := ""
var _label: Label
var _name_label: Label
var _shown := 0.0
var _typing := false
var _waiting := false
var _box := Rect2()
var _face_rect := Rect2()
var fast_forward := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_label = UIStyle.label("", UIStyle.FONT_SIZE)
	_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	# lay out the whole text even while the typewriter hides part of it: the box height comes from the line count
	# (by default the hidden characters are cut before layout, so a fresh text measured as one line), and the
	# lines don't re-wrap as characters appear
	_label.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	_label.add_theme_constant_override("line_spacing", 4)
	add_child(_label)
	_name_label = UIStyle.label("", UIStyle.FONT_SIZE, UIStyle.NAME_COLOR)
	add_child(_name_label)
	visible = false


func _layout(top: bool) -> void:
	var vs := get_viewport_rect().size
	var h := 128.0
	var text_x := 8.0 + 14
	if face:
		var fs0 := face.get_size()
		text_x = 8 + 8 + fs0.x * minf(1.0, (h - 12) / fs0.y) + 12
	# long texts get a taller box instead of running out of it
	var ty_off := 32.0 if speaker != "" else 12.0
	var tw := vs.x - 8 - text_x - 14
	_label.size = Vector2(tw, 10)
	var lh := Assets.font().get_height(UIStyle.FONT_SIZE) + 4
	h = clampf(ty_off + _label.get_line_count() * lh + 10, h, vs.y - 16)
	var y := 8.0 if top else vs.y - h - 8.0
	_box = Rect2(8, y, vs.x - 16, h)
	if face:
		var fs := face.get_size()
		var scale := minf(1.0, (128.0 - 12) / fs.y)
		_face_rect = Rect2(_box.position.x + 8, _box.position.y + (h - fs.y * scale) / 2, fs.x * scale, fs.y * scale)
	_name_label.position = Vector2(text_x, _box.position.y + 8)
	_name_label.size = Vector2(_box.end.x - text_x - 10, 20)
	var ty := _box.position.y + ty_off
	_label.position = Vector2(text_x, ty)
	_label.size = Vector2(tw, _box.end.y - ty - 8)


func _draw() -> void:
	if not visible:
		return
	UIStyle.draw_panel(self, _box)
	if face:
		draw_rect(_face_rect.grow(2), UIStyle.BORDER_OUT, false, 2.0)
		draw_texture_rect(face, _face_rect, false)
	if _waiting:
		var t := Time.get_ticks_msec() / 300 % 2
		var p := Vector2(_box.end.x - 20, _box.end.y - 14 + t * 2)
		draw_colored_polygon(PackedVector2Array([p, p + Vector2(10, 0), p + Vector2(5, 6)]), UIStyle.NAME_COLOR)


## Show a message. Returns when the player dismisses it.
func talk(face_tex: Texture2D, name: String, text: String, top := false) -> void:
	face = face_tex
	speaker = name
	_name_label.text = name
	_label.text = text
	_label.visible_characters = 0
	_shown = 0.0
	_typing = true
	_waiting = false
	visible = true
	_layout(top)
	queue_redraw()
	if Game.demo:
		await get_tree().create_timer(1.6).timeout
		_label.visible_characters = -1
		await get_tree().create_timer(0.8).timeout
		visible = false
		return
	if Game.autoplay:
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [%s] %s" % [name, text.replace("\n", " ")])
		await get_tree().process_frame
		visible = false
		return
	await advanced
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	if _typing:
		_shown += delta * CHARS_PER_SEC * (8.0 if fast_forward or Game.skip_held() else 1.0)
		_label.visible_characters = int(_shown)
		if _label.visible_characters >= _label.get_total_character_count():
			_label.visible_characters = -1
			_typing = false
			_waiting = true
	elif _waiting and Game.skip_held():
		_waiting = false
		advanced.emit()
	queue_redraw()


func _confirm() -> void:
	if _typing:
		_typing = false
		_label.visible_characters = -1
		_waiting = true
	elif _waiting:
		_waiting = false
		advanced.emit()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_confirm()
		accept_event()


func _unhandled_input(ev: InputEvent) -> void:
	if not visible:
		return
	if ev.is_action_pressed("ui_accept") or ev.is_action_pressed("ui_cancel"):
		_confirm()
		get_viewport().set_input_as_handled()
