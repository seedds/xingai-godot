class_name SysDialog66
extends Control
## The engine's Win32 dialogs drawn in the Windows-classic look they have in the original:
## * 339 "确认" (OK, 0x40b3a6 → 0x40f144) and 340 (是 / 否, 0x474af0 → 0x418c34; IDYES → 1) of message box 0x42f699
##   styles 0 / 1: icon #137 at (7, 7), the text at (32, 7), buttons 50 × 14 at y 36 (dialog units, 宋体 9 pt);
## * 342 (0x72 sub 34, 0x42c992 / init 0x42ca5e): "1."… options as radio buttons (BS_AUTORADIOBUTTON) or check boxes
##   (BS_AUTOCHECKBOX) at (72, 10 + 16·i), 308 × 12 px; the dialog is sized max(maxlen·6 + 100, 240) ×
##   max(n·16 + 20, 96); 确定 is enabled only with a selection, at most `max` boxes can be checked; Esc and the close
##   box do nothing.
## Dialog units → pixels: 1.5 (宋体 9 pt base units 6 × 12). [G] the icon is not drawn and the window is centred.

signal done(result: Variant)

const FACE := Color8(212, 208, 200)
const DARK := Color8(128, 128, 128)
const DARKER := Color8(64, 64, 64)
const LIGHT := Color8(255, 255, 255)
const CAPTION := Color8(10, 36, 106)
const CAPTION2 := Color8(166, 202, 240)
const TEXT := Color8(0, 0, 0)
const FS := 12
const CAP_H := 18.0

var _rect := Rect2()
var _caption := ""
var _lines: PackedStringArray = []
var _text_pos := Vector2.ZERO
var _buttons: Array = []        # [Rect2, label, value]
var _options: Array = []        # [Rect2, label]
var _checked: Array = []
var _checkboxes := false
var _max := 1
var _press := -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _font() -> Font:
	return Assets.font()


func _tw(s: String) -> float:
	return _font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x


## Message dialog: returns true for the first button (OK / 是).
func run(caption: String, text: String, buttons: Array) -> bool:
	_caption = caption
	_lines = text.replace("\r", "").split("\n")
	var tw := 0.0
	for l in _lines:
		tw = maxf(tw, _tw(l))
	var th := _lines.size() * (FS + 4)
	var cw := maxf((121.0 if buttons.size() > 1 else 63.0) * 1.5, 48 + tw + 12)
	var ch := maxf(57.0 * 1.5, 11 + th + 12 + 21 + 10)
	_place(cw, ch)
	_text_pos = _rect.position + Vector2(48, CAP_H + 11)
	var by := _rect.end.y - 10 - 21
	var bx := _rect.position.x + 11
	if buttons.size() > 1:
		bx = _rect.position.x + (cw - 75 * 2 - 10) / 2
	for k in buttons.size():
		_buttons.append([Rect2(bx + k * 85, by, 75, 21), str(buttons[k]), k == 0])
	queue_redraw()
	var r: Variant = await done
	return bool(r)


## Option dialog of sub 34: returns the selected 0-based indices.
func run_options(labels: Array, checkboxes: bool, max_checked: int) -> Array:
	_caption = ""
	_checkboxes = checkboxes
	_max = maxi(max_checked, 1)
	var maxlen := 0
	for l in labels:
		maxlen = maxi(maxlen, Text66.gbk_len(str(l)))
	var cw := maxf(maxlen * 6 + 100, 240)
	var ch := maxf(labels.size() * 16 + 20, 96) + 30
	_place(cw, ch)
	for k in labels.size():
		_options.append([Rect2(_rect.position.x + 72, _rect.position.y + CAP_H + 10 + 16 * k, minf(308, cw - 76), 12),
				str(labels[k])])
		_checked.append(false)
	_buttons.append([Rect2(_rect.position.x + 6, _rect.end.y - 8 - 21, 55, 21), "确定", true])
	queue_redraw()
	var r: Variant = await done
	return r


func _place(cw: float, ch: float) -> void:
	var size := Vector2(cw, ch + CAP_H)
	_rect = Rect2(((Vector2(640, 480) - size) / 2).floor(), size)


func _ok_enabled() -> bool:
	if _options.is_empty():
		return true
	return _checked.has(true)


func _gui_input(ev: InputEvent) -> void:
	accept_event()
	if not (ev is InputEventMouseButton) or ev.button_index != MOUSE_BUTTON_LEFT:
		return
	var p: Vector2 = ev.position
	if ev.pressed:
		_press = -1
		for k in _buttons.size():
			if (_buttons[k][0] as Rect2).has_point(p):
				_press = k
		for k in _options.size():
			if (_options[k][0] as Rect2).has_point(p):
				_toggle(k)
		queue_redraw()
	elif _press >= 0:
		var k := _press
		_press = -1
		queue_redraw()
		if (_buttons[k][0] as Rect2).has_point(p):
			_click(k)


func _toggle(k: int) -> void:
	if _checkboxes:
		if _checked[k]:
			_checked[k] = false
		elif _checked.count(true) < _max:
			_checked[k] = true
	else:
		for i in _checked.size():
			_checked[i] = i == k
	queue_redraw()


func _click(k: int) -> void:
	if not _options.is_empty():
		if not _ok_enabled():
			return
		var out := []
		for i in _checked.size():
			if _checked[i]:
				out.append(i)
		done.emit(out)
		return
	done.emit(bool(_buttons[k][2]))


func _unhandled_input(ev: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if ev.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if _options.is_empty() or _ok_enabled():
			_click(0)
	elif ev.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _options.is_empty() and _buttons.size() > 1:
			done.emit(false)        # 否 (IDNO); the sub-34 dialog swallows Esc


func _bevel(r: Rect2, sunken := false) -> void:
	var a := DARK if sunken else LIGHT
	var b := DARKER if sunken else DARKER
	draw_rect(r, FACE, true)
	draw_line(r.position, Vector2(r.end.x - 1, r.position.y), a)
	draw_line(r.position, Vector2(r.position.x, r.end.y - 1), a)
	draw_line(Vector2(r.position.x, r.end.y - 1), r.end - Vector2(1, 1), b)
	draw_line(Vector2(r.end.x - 1, r.position.y), r.end - Vector2(1, 1), b)


func _draw() -> void:
	var f := _font()
	var asc := f.get_ascent(FS)
	_bevel(_rect)
	if _caption != "" or _options.is_empty():
		var cap := Rect2(_rect.position + Vector2(3, 3), Vector2(_rect.size.x - 6, CAP_H - 3))
		draw_rect(cap, CAPTION, true)
		draw_rect(Rect2(cap.position + Vector2(cap.size.x * 0.5, 0), Vector2(cap.size.x * 0.5, cap.size.y)), CAPTION2.lerp(CAPTION, 0.4), true)
		draw_string(f, cap.position + Vector2(4, asc + 1), _caption, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, LIGHT)
	var y := _text_pos.y
	for l in _lines:
		draw_string(f, Vector2(_text_pos.x, y + asc), l, HORIZONTAL_ALIGNMENT_LEFT, -1, FS, TEXT)
		y += FS + 4
	for k in _options.size():
		var r: Rect2 = _options[k][0]
		var box := Rect2(r.position + Vector2(0, 0), Vector2(12, 12))
		if _checkboxes:
			draw_rect(box, LIGHT, true)
			draw_rect(box, DARKER, false, 1.0)
			if _checked[k]:
				draw_line(box.position + Vector2(2, 6), box.position + Vector2(5, 9), TEXT, 2.0)
				draw_line(box.position + Vector2(5, 9), box.position + Vector2(10, 3), TEXT, 2.0)
		else:
			draw_circle(box.get_center(), 5.5, LIGHT)
			draw_arc(box.get_center(), 5.5, 0, TAU, 16, DARKER, 1.0)
			if _checked[k]:
				draw_circle(box.get_center(), 2.5, TEXT)
		draw_string(f, Vector2(r.position.x + 16, r.position.y + asc - 1), _options[k][1], HORIZONTAL_ALIGNMENT_LEFT,
				r.size.x - 16, FS, TEXT)
	for k in _buttons.size():
		var r: Rect2 = _buttons[k][0]
		_bevel(r, _press == k)
		var en := _ok_enabled() or _options.is_empty()
		var s: String = _buttons[k][1]
		var tw := _tw(s)
		draw_string(f, Vector2(r.position.x + (r.size.x - tw) / 2, r.position.y + (r.size.y - FS) / 2 + asc), s,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FS, TEXT if en else DARK)
