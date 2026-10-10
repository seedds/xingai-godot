class_name ChoiceMenu
extends Control
## Vertical selection menu. `var i = await menu.choose(["a","b"], pos, cancellable)`
## Returns the chosen index, or -1 when cancelled. Lists taller than the screen scroll; lines wider than
## the screen are cut short.

signal chosen(index: int)

const ROW_H := 24
const PAD := 10
const TAP_SLOP := 10.0       # finger travel (px) before a touch on a long list scrolls it instead of picking

var items: PackedStringArray = []
var enabled: Array = []
var sel := 0
var cancellable := true
var title := ""
var _rect := Rect2()
var _active := false
var _min_width := 0.0
var _top := 0                # first visible row
var _rows := 0               # rows that fit on the screen
var _touch_down := false     # touch: a press on this open menu, not yet released
var _touch_y := 0.0          # touch: finger y where the list last scrolled by a row
var _touch_from := Vector2.ZERO
var _touch_scrolled := false
var _touch_outside := false  # touch: the press was outside the menu box (a tap there cancels)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false


func choose(options: Array, at := Vector2(-1, -1), can_cancel := true, header := "", enabled_mask: Array = [], min_width := 0.0, first := 0) -> int:
	items = PackedStringArray(options)
	enabled = enabled_mask if enabled_mask.size() == options.size() else []
	cancellable = can_cancel
	title = header
	_min_width = min_width
	sel = clampi(first, 0, maxi(items.size() - 1, 0))
	while not _is_enabled(sel) and sel < items.size() - 1:
		sel += 1
	var f := Assets.font()
	var w := _min_width
	for s in items:
		w = maxf(w, f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE).x)
	if title != "":
		w = maxf(w, f.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE).x)
	var vs := get_viewport_rect().size
	w = minf(w, vs.x - PAD * 2 - 16 - 8)
	var head := ROW_H if title != "" else 0
	_rows = clampi(int((vs.y - 8 - PAD * 2 - head) / ROW_H), 1, maxi(items.size(), 1))
	_top = 0
	_scroll_to(sel)
	var h := _rows * ROW_H + PAD * 2 + head
	var pos := at
	if pos.x < 0:
		pos = (vs - Vector2(w + PAD * 2 + 16, h)) / 2
	pos.x = clampf(pos.x, 0, vs.x - (w + PAD * 2 + 16))
	pos.y = clampf(pos.y, 0, vs.y - h)
	_rect = Rect2(pos, Vector2(w + PAD * 2 + 16, h))
	visible = true
	_active = true
	_touch_down = false
	queue_redraw()
	if Game.autoplay or Game.demo:
		if Game.demo:
			await get_tree().create_timer(1.0).timeout
		await get_tree().process_frame
		visible = false
		_active = false
		var pick := 0
		var opts := []
		for k in items.size():
			if _is_enabled(k):
				opts.append(k)
		if not opts.is_empty():
			pick = opts[Rules.rand(opts.size())] if OS.get_environment("WG_RANDOM") != "" else opts[0]
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [menu] %s -> %s" % [items, items[pick] if pick < items.size() else "?"])
		return pick
	var r: int = await chosen
	visible = false
	_active = false
	return r


func _is_enabled(i: int) -> bool:
	return enabled.is_empty() or (i < enabled.size() and enabled[i])


## Screen rectangle of item i (only meaningful while it is one of the visible rows).
func _row_rect(i: int) -> Rect2:
	var y0 := _rect.position.y + PAD + (ROW_H if title != "" else 0)
	return Rect2(_rect.position.x + 4, y0 + (i - _top) * ROW_H, _rect.size.x - 8, ROW_H)


func _visible(i: int) -> bool:
	return i >= _top and i < _top + _rows


func _scroll_to(i: int) -> void:
	if i < _top:
		_top = i
	elif i >= _top + _rows:
		_top = i - _rows + 1
	_top = clampi(_top, 0, maxi(items.size() - _rows, 0))


func _draw() -> void:
	UIStyle.draw_panel(self, _rect)
	if title != "":
		UIStyle.draw_text(self, Vector2(_rect.position.x + PAD + 8, _rect.position.y + PAD + 17), title, UIStyle.NAME_COLOR)
	var f := Assets.font()
	var max_w := _rect.size.x - PAD * 2 - 16
	for i in range(_top, mini(_top + _rows, items.size())):
		var rr := _row_rect(i)
		if i == sel:
			draw_rect(rr, UIStyle.HILITE)
		var col := UIStyle.TEXT_COLOR if _is_enabled(i) else Color(0.55, 0.55, 0.6)
		var t := items[i]
		if f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE).x > max_w:
			while t.length() > 1 and f.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, UIStyle.FONT_SIZE).x > max_w:
				t = t.left(-1)
			t += "…"
		UIStyle.draw_text(self, Vector2(rr.position.x + PAD + 4, rr.position.y + 17), t, col)
	# more rows above / below
	var ax := _rect.end.x - 14
	if _top > 0:
		var y := _row_rect(_top).position.y + 4
		draw_colored_polygon(PackedVector2Array([Vector2(ax, y + 6), Vector2(ax + 8, y + 6), Vector2(ax + 4, y)]), UIStyle.NAME_COLOR)
	if _top + _rows < items.size():
		var y2 := _row_rect(_top + _rows - 1).end.y - 4
		draw_colored_polygon(PackedVector2Array([Vector2(ax, y2 - 6), Vector2(ax + 8, y2 - 6), Vector2(ax + 4, y2)]), UIStyle.NAME_COLOR)


func _move(d: int) -> void:
	if items.is_empty():
		return
	for k in items.size():
		sel = (sel + d + items.size()) % items.size()
		if _is_enabled(sel):
			break
	_scroll_to(sel)
	Audio.se(0)
	queue_redraw()


## Index of the enabled visible row at p, or -1.
func _row_at(p: Vector2) -> int:
	for i in items.size():
		if _visible(i) and _row_rect(i).has_point(p) and _is_enabled(i):
			return i
	return -1


## Touch: a press highlights the row under the finger and the release picks it, so a finger can slide onto the
## right row first. A vertical drag on a list longer than the screen scrolls it instead (and picks nothing).
## A tap outside the box (pressed and released there) cancels, like a right click, if the menu can be cancelled.
func _touch_input(ev: InputEventMouse) -> void:
	if ev is InputEventMouseMotion:
		if not _touch_down:
			return
		var p := ev.position
		if _touch_outside:
			return
		if items.size() > _rows and (_touch_scrolled or absf(p.y - _touch_from.y) > TAP_SLOP):
			if not _touch_scrolled:
				_touch_scrolled = true
				_touch_y = p.y
			var n := int((p.y - _touch_y) / ROW_H)       # finger down = earlier rows come into view
			if n != 0:
				_touch_y += n * ROW_H
				_top = clampi(_top - n, 0, maxi(items.size() - _rows, 0))
				queue_redraw()
		elif not _touch_scrolled:
			var i := _row_at(p)
			if i >= 0 and i != sel:
				sel = i
				queue_redraw()
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_touch_down = true
		_touch_scrolled = false
		_touch_from = mb.position
		_touch_outside = not _rect.has_point(mb.position)
		var i := _row_at(mb.position)
		if i >= 0 and i != sel:
			sel = i
			queue_redraw()
	elif _touch_down:
		_touch_down = false
		if _touch_outside:
			if cancellable and not _rect.has_point(mb.position):
				_finish(-1)
		elif not _touch_scrolled:
			var i := _row_at(mb.position)
			if i >= 0:
				sel = i
				_finish(i)


func _gui_input(ev: InputEvent) -> void:
	if not _active:
		return
	if Game.touch and ev is InputEventMouse and (ev is InputEventMouseMotion or ev.button_index == MOUSE_BUTTON_LEFT):
		_touch_input(ev)
		accept_event()
		return
	if ev is InputEventMouseMotion:
		for i in items.size():
			if _visible(i) and _row_rect(i).has_point(ev.position) and sel != i and _is_enabled(i):
				sel = i
				queue_redraw()
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			for i in items.size():
				if _visible(i) and _row_rect(i).has_point(ev.position) and _is_enabled(i):
					sel = i
					_finish(i)
					return
		elif ev.button_index == MOUSE_BUTTON_RIGHT and cancellable:
			_finish(-1)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_move(-1)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_move(1)
	accept_event()


func _unhandled_input(ev: InputEvent) -> void:
	if not _active:
		return
	if ev.is_action_pressed("ui_up"):
		_move(-1)
	elif ev.is_action_pressed("ui_down"):
		_move(1)
	elif ev.is_action_pressed("ui_page_up", true):
		_page(-1)
	elif ev.is_action_pressed("ui_page_down", true):
		_page(1)
	elif ev.is_action_pressed("ui_accept"):
		if _is_enabled(sel):
			_finish(sel)
	elif ev.is_action_pressed("ui_cancel") and cancellable:
		_finish(-1)
	else:
		return
	get_viewport().set_input_as_handled()


func _page(d: int) -> void:
	if items.is_empty():
		return
	sel = clampi(sel + d * _rows, 0, items.size() - 1)
	_scroll_to(sel)
	Audio.se(0)
	queue_redraw()


func _finish(i: int) -> void:
	_active = false
	Audio.se(1 if i >= 0 else 2)
	chosen.emit(i)
