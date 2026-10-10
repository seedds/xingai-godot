class_name ChoiceWin66
extends Win66
## The choice window of op 0x12 (0x42de7d): the portrait, the ◀ of Mark 单挑框 and a white list box whose rows the
## mouse highlights (0x42e195 recolours the row: black text → white, white/blue ground → blue); a left click on the
## highlighted row flashes it (blue → red, 0x42e195 mode 1) for 2 ticks and returns its index. Up/Down/Enter also work
## (port addition; the original reads only the mouse).

signal picked(index: int)

var _rows: Array[Rect2] = []
var _labels: Array = []
var _hover := -1
var _flash := false
var _active := false
var _box := Rect2()


func run(labels: Array, pid: int) -> int:
	_labels = labels
	var n := clampi(labels.size(), 3, 6)
	var t: Array = Windows66.CHOICE_ROWS[n]
	var off := int(t[0])
	var h := int(t[1])
	var x0 := (Windows66.W - 0x1d0) >> 1
	var y0 := (Windows66.H - 0x50) >> 1
	pic(Windows66.face(pid), Vector2(x0, y0), Rect2(Vector2.ZERO, Windows66.FACE))
	pic(Assets.tex("gfx/ui/mark/11.png"), Vector2(x0 + 0x78, y0 + 0x3c), Rect2(0, 0, 16, 16))
	_box = Rect2(x0 + 0x98, y0 + off, 0x120, h)
	fill(_box, Text66.pal(Text66.C_WHITE))       # [G] 0x4736af(…, 0, 0x12) taken as a filled white box
	var st := {"c": Text66.C_TEXT, "open": false}
	var y := y0 + off + 4
	for k in labels.size():
		var i := text_line(_box.position.x, y, str(labels[k]), st)
		texts[i]["shown"] = (texts[i]["g"] as Array).size()
		_rows.append(Rect2(_box.position.x, y - 1, 0x120, 0x12))
		y += 0x13
		queue_redraw()
		await ticks(3)
	_active = true
	_hover = _row_at(get_local_mouse_position())
	queue_redraw()
	var r: int = await picked
	_active = false
	_flash = true
	queue_redraw()
	await ticks(2)
	return r


func _row_at(p: Vector2) -> int:
	for i in _rows.size():
		if _rows[i].has_point(p):
			return i
	return -1


func _gui_input(ev: InputEvent) -> void:
	if not _active:
		accept_event()
		return
	if ev is InputEventMouseMotion:
		var i := _row_at(ev.position)
		if i != _hover:
			_hover = i
			queue_redraw()
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var i := _row_at(ev.position)
		if i >= 0:
			_hover = i
			picked.emit(i)
	accept_event()


func _unhandled_input(ev: InputEvent) -> void:
	if not _active:
		return
	if ev.is_action_pressed("ui_up"):
		_hover = (_hover - 1 + _rows.size()) % _rows.size() if _hover >= 0 else _rows.size() - 1
	elif ev.is_action_pressed("ui_down"):
		_hover = (_hover + 1) % _rows.size() if _hover >= 0 else 0
	elif ev.is_action_pressed("ui_accept") and _hover >= 0:
		picked.emit(_hover)
	else:
		return
	queue_redraw()
	get_viewport().set_input_as_handled()


func _draw() -> void:
	super._draw()
	if _hover < 0 or _hover >= _rows.size():
		return
	draw_rect(_rows[_hover], Text66.pal(0x28) if _flash else Text66.pal(Text66.C_NAME), true)
	var t: Dictionary = texts[_hover]
	var f := Assets.font()
	var asc := f.get_ascent(Text66.FONT_SIZE)
	for e in t["g"]:
		var c := Text66.pal(int(e[1]))
		if int(e[1]) == Text66.C_TEXT:
			c = Text66.pal(Text66.C_WHITE)
		draw_string(f, Vector2(float(t["x"]) + Text66.COL * int(e[2]), float(t["y"]) + asc), e[0],
				HORIZONTAL_ALIGNMENT_LEFT, -1, Text66.FONT_SIZE, c)
