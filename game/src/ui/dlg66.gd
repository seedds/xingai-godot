class_name Dlg66
extends Control
## Base of the 6.6 engine's Win32 dialogs (Ekd5.exe RT_DIALOG templates, 宋体 9 pt) drawn in the Windows-classic look of
## SysDialog66: controls are placed by their template rects in dialog units, scaled so the dialog fits the 640×480
## screen (the original's dialogs are separate top-level windows and may be larger than the game window; 1 DLU =
## 1.5 px there) and centred.
## Controls: buttons (BS_PUSHBUTTON), group boxes, statics (left / centre / right, SS_SUNKEN), picture statics, list
## views (SysListView32 report view, owner-drawn rows: Dlg66.ListView), tab controls (SysTabControl32), combo boxes
## (CBS_DROPDOWNLIST) and list boxes (LISTBOX). Subclasses fill them and react in `_on_command(id)`,
## `_on_list_click(list, row)` (left button released on an enabled row: the lists' vtable+0x34 action, 0x4652b9),
## `_on_list_rclick(list, row)` (right button: vtable+0x38), `_on_list_select(list, row)` (LVN_ITEMCHANGED → +0x30),
## `_on_tab(id, i)`, `_on_combo(id, i)`, `_on_pic(id, button)`. Id 2 (IDCANCEL, 结束 / 确定) and Esc close the dialog.

signal closed(result: Variant)

const FACE := Color8(212, 208, 200)
const DARK := Color8(128, 128, 128)
const DARKER := Color8(64, 64, 64)
const LIGHT := Color8(255, 255, 255)
const WINDOW := Color8(255, 255, 255)
const CAPTION := Color8(10, 36, 106)
const CAPTION2 := Color8(166, 202, 240)
const HILITE := Color8(10, 36, 106)
const TEXT := Color8(0, 0, 0)
const GREY := Color8(128, 128, 128)
const FS := 12
const CAP_H := 18.0
const ROW_H := 18.0

var title := ""
var dlu := Vector2(100, 100)
var dscale := 1.5
var origin := Vector2.ZERO          # client area top-left on the screen
var ctrls: Dictionary = {}         # id → Dictionary
var order: Array = []              # draw order of control ids
var _press_id: Variant = null      # button being pressed
var _combo_open: Variant = null    # id of the open drop-down
var _combo_hover := -1
var _drag_list: Variant = null     # list whose scroll thumb is dragged
var _done := false
var _auto_id := -100


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


## Size the dialog from its template client size (dialog units).
func setup(caption: String, cx: float, cy: float) -> void:
	title = caption
	dlu = Vector2(cx, cy)
	dscale = minf(1.5, minf(626.0 / cx, (466.0 - CAP_H) / cy))
	var sz := dlu * dscale + Vector2(0, CAP_H)
	origin = ((Vector2(640, 480) - sz) / 2).floor() + Vector2(0, CAP_H)


## A template rect (dialog units) on the screen.
func r(x: float, y: float, w: float, h: float) -> Rect2:
	return Rect2((origin + Vector2(x, y) * dscale).floor(), (Vector2(w, h) * dscale).floor())


func client_rect() -> Rect2:
	return Rect2(origin, dlu * dscale)


static func run_dialog(ui: Node, d: Dlg66) -> Variant:
	ui.add_child(d)
	var res: Variant = await d.closed
	d.queue_free()
	return res


func close(result: Variant = null) -> void:
	if _done:
		return
	_done = true
	closed.emit(result)


# ------------------------------------------------------------------ building
func _add(id: Variant, c: Dictionary) -> Dictionary:
	if id == null:
		_auto_id -= 1
		id = _auto_id
	c["id"] = id
	if not c.has("enabled"):
		c["enabled"] = true
	if not c.has("visible"):
		c["visible"] = true
	ctrls[id] = c
	order.append(id)
	queue_redraw()
	return c


func add_button(id: Variant, x: float, y: float, w: float, h: float, text: String) -> Dictionary:
	return _add(id, {"kind": "button", "r": r(x, y, w, h), "text": text})


func add_group(x: float, y: float, w: float, h: float, text: String) -> Dictionary:
	return _add(null, {"kind": "group", "r": r(x, y, w, h), "text": text})


## align 0 left, 1 centre, 2 right; `sunken` = SS_SUNKEN (0x1000).
func add_static(id: Variant, x: float, y: float, w: float, h: float, text := "", align := 0, sunken := false) -> Dictionary:
	return _add(id, {"kind": "static", "r": r(x, y, w, h), "text": text, "align": align, "sunken": sunken,
		"color": TEXT})


func add_line(x: float, y: float, w: float, h: float) -> Dictionary:
	return _add(null, {"kind": "line", "r": r(x, y, w, h)})


func add_pic(id: Variant, x: float, y: float, w: float, h: float, sunken := true) -> Dictionary:
	return _add(id, {"kind": "pic", "r": r(x, y, w, h), "tex": null, "sunken": sunken})


## Progress-like bar inside a static (the exp bars, painter 0x461448): `value` / `maxv`, `label` drawn over it.
## An invisible click area (a drop target such as the equipment frames 0x590..0x592 of 0x469b7e): clicks go to
## `_on_pic(id, button)`.
func add_hot(id: Variant, x: float, y: float, w: float, h: float) -> Dictionary:
	return _add(id, {"kind": "hot", "r": r(x, y, w, h)})


func add_bar(id: Variant, x: float, y: float, w: float, h: float) -> Dictionary:
	return _add(id, {"kind": "bar", "r": r(x, y, w, h), "value": 0, "maxv": 100, "label": "", "on": false})


func add_list(id: Variant, x: float, y: float, w: float, h: float) -> ListView:
	var lv := ListView.new()
	lv.rect = r(x, y, w, h)
	_add(id, {"kind": "list", "r": lv.rect, "lv": lv})
	return lv


func add_listbox(id: Variant, x: float, y: float, w: float, h: float) -> ListView:
	var lv := ListView.new()
	lv.rect = r(x, y, w, h)
	lv.header = false
	lv.columns = [{"title": "", "w": lv.rect.size.x, "align": 0}]
	_add(id, {"kind": "list", "r": lv.rect, "lv": lv})
	return lv


func add_tab(id: Variant, x: float, y: float, w: float, h: float, labels: Array) -> Dictionary:
	return _add(id, {"kind": "tab", "r": r(x, y, w, h), "labels": labels, "sel": 0})


func add_combo(id: Variant, x: float, y: float, w: float, h_drop: float, items: Array) -> Dictionary:
	var rr := r(x, y, w, 12)
	return _add(id, {"kind": "combo", "r": rr, "items": items, "sel": 0 if not items.is_empty() else -1,
		"drop_h": h_drop * dscale})


func ctrl(id: Variant) -> Dictionary:
	return ctrls.get(id, {})


func set_text(id: Variant, s: String) -> void:
	if ctrls.has(id):
		ctrls[id]["text"] = s
		queue_redraw()


func set_color(id: Variant, c: Color) -> void:
	if ctrls.has(id):
		ctrls[id]["color"] = c
		queue_redraw()


func enable(id: Variant, on: bool) -> void:
	if ctrls.has(id):
		ctrls[id]["enabled"] = on
		queue_redraw()


func show_ctrl(id: Variant, on: bool) -> void:
	if ctrls.has(id):
		ctrls[id]["visible"] = on
		queue_redraw()


func list(id: Variant) -> ListView:
	return ctrls[id]["lv"] if ctrls.has(id) and ctrls[id].has("lv") else null


## Message box 0x42f699(0, text): the 339 确认 dialog with OK, on top of this dialog.
func msg_box(text: String) -> void:
	if Game.autoplay:
		return
	var m := SysDialog66.new()
	add_child(m)
	await m.run("确认", text, ["OK"])
	m.queue_free()


# ------------------------------------------------------------------ virtuals
func _on_command(id: Variant) -> void:
	if id == 2:
		close(null)


func _on_list_click(_lid: Variant, _row: int) -> void:
	pass


func _on_list_rclick(_lid: Variant, _row: int) -> void:
	pass


func _on_list_select(_lid: Variant, _row: int) -> void:
	pass


func _on_tab(_id: Variant, _i: int) -> void:
	pass


func _on_combo(_id: Variant, _i: int) -> void:
	pass


func _on_pic(_id: Variant, _button: int) -> void:
	pass


# ------------------------------------------------------------------ input
func _ctrl_at(p: Vector2) -> Variant:
	for i in range(order.size() - 1, -1, -1):
		var c: Dictionary = ctrls[order[i]]
		if not c["visible"]:
			continue
		if c["kind"] in ["group", "line"]:
			continue
		if (c["r"] as Rect2).has_point(p):
			return order[i]
	return null


func _gui_input(ev: InputEvent) -> void:
	accept_event()
	if _done:
		return
	if ev is InputEventMouseMotion:
		if _drag_list != null:
			(ctrls[_drag_list]["lv"] as ListView).drag_thumb(ev.position)
			queue_redraw()
		elif _combo_open != null:
			_combo_hover = _combo_row_at(ev.position)
			queue_redraw()
		return
	if not (ev is InputEventMouseButton):
		return
	var p: Vector2 = ev.position
	if ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if ev.pressed:
			var id0: Variant = _ctrl_at(p)
			if id0 != null and ctrls[id0]["kind"] == "list":
				(ctrls[id0]["lv"] as ListView).scroll(-3 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else 3)
				queue_redraw()
		return
	if _combo_open != null:
		if ev.pressed:
			var k := _combo_row_at(p)
			var cid: Variant = _combo_open
			_combo_open = null
			if k >= 0 and k != int(ctrls[cid]["sel"]):
				ctrls[cid]["sel"] = k
				_on_combo(cid, k)
			queue_redraw()
		return
	if ev.button_index == MOUSE_BUTTON_LEFT and not ev.pressed and _drag_list != null:
		_drag_list = null
		return
	var id: Variant = _ctrl_at(p)
	if ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_press_id = id
			if id != null:
				var c: Dictionary = ctrls[id]
				if not c["enabled"]:
					return
				match c["kind"]:
					"list":
						var lv: ListView = c["lv"]
						if lv.on_scrollbar(p):
							if lv.thumb_rect().has_point(p):
								_drag_list = id
								lv.begin_drag(p)
							else:
								lv.page(p)
						else:
							var row := lv.row_at(p)
							if lv.header and lv.header_rect().has_point(p):
								pass
							elif row >= 0 and row != lv.sel:
								lv.sel = row
								_on_list_select(id, row)
					"tab":
						var k := _tab_at(c, p)
						if k >= 0 and k != int(c["sel"]):
							c["sel"] = k
							_on_tab(id, k)
					"combo":
						_combo_open = id
						_combo_hover = int(c["sel"])
			queue_redraw()
		else:
			var was: Variant = _press_id
			_press_id = null
			queue_redraw()
			if id == null or was != id or not ctrls[id]["enabled"]:
				return
			match ctrls[id]["kind"]:
				"button":
					_on_command(id)
				"list":
					var lv2: ListView = ctrls[id]["lv"]
					if not lv2.on_scrollbar(p):
						var row2 := lv2.row_at(p)
						if row2 >= 0 and row2 == lv2.sel and lv2.row_enabled(row2):
							_on_list_click(id, row2)
				"pic", "static", "hot":
					_on_pic(id, MOUSE_BUTTON_LEFT)
	elif ev.button_index == MOUSE_BUTTON_RIGHT and not ev.pressed:
		if id != null and ctrls[id]["enabled"]:
			match ctrls[id]["kind"]:
				"list":
					var lv3: ListView = ctrls[id]["lv"]
					var row3 := lv3.row_at(p)
					if row3 >= 0:
						lv3.sel = row3
						_on_list_rclick(id, row3)
				"pic", "static", "hot":
					_on_pic(id, MOUSE_BUTTON_RIGHT)
		queue_redraw()


func _unhandled_input(ev: InputEvent) -> void:
	if not is_visible_in_tree() or _done:
		return
	if not (ev is InputEventKey or ev is InputEventAction or ev is InputEventJoypadButton):
		return
	get_viewport().set_input_as_handled()
	if not ev.is_pressed():
		return
	if ev.is_action_pressed("ui_cancel"):
		if _combo_open != null:
			_combo_open = null
			queue_redraw()
		else:
			_on_command(2)        # Esc = IDCANCEL
	else:
		_on_key(ev)


## Keys other than Esc (subclasses: arrows in lists …).
func _on_key(ev: InputEvent) -> void:
	for id in order:
		var c: Dictionary = ctrls[id]
		if c["kind"] == "list" and c["visible"] and c["enabled"]:
			var lv: ListView = c["lv"]
			if lv.rows.is_empty():
				continue
			if ev.is_action_pressed("ui_down") or ev.is_action_pressed("ui_up"):
				var d := 1 if ev.is_action_pressed("ui_down") else -1
				var n := clampi(lv.sel + d, 0, lv.rows.size() - 1)
				if n != lv.sel:
					lv.sel = n
					lv.ensure_visible(n)
					_on_list_select(id, n)
					queue_redraw()
				return
			if ev.is_action_pressed("ui_accept") and lv.sel >= 0 and lv.row_enabled(lv.sel):
				_on_list_click(id, lv.sel)
				queue_redraw()
				return


func _tab_at(c: Dictionary, p: Vector2) -> int:
	var rects := _tab_rects(c)
	for k in rects.size():
		if (rects[k] as Rect2).has_point(p):
			return k
	return -1


func _tab_rects(c: Dictionary) -> Array:
	var out := []
	var x: float = c["r"].position.x + 2
	for s in c["labels"]:
		var w := _tw(str(s)) + 16
		out.append(Rect2(x, c["r"].position.y, w, 19))
		x += w
	return out


func _combo_rows_rect(c: Dictionary) -> Rect2:
	var n := mini((c["items"] as Array).size(), int(float(c["drop_h"]) / 16.0))
	return Rect2(c["r"].position + Vector2(0, c["r"].size.y), Vector2(c["r"].size.x, maxi(n, 1) * 16 + 2))


func _combo_row_at(p: Vector2) -> int:
	if _combo_open == null:
		return -1
	var c: Dictionary = ctrls[_combo_open]
	var rr := _combo_rows_rect(c)
	if not rr.has_point(p):
		return -1
	var k := int((p.y - rr.position.y - 1) / 16.0) + int(c.get("top", 0))
	return k if k < (c["items"] as Array).size() else -1


# ------------------------------------------------------------------ drawing
func _font() -> Font:
	return Assets.font()


func _tw(s: String, fs := FS) -> float:
	return _font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x


func bevel(rr: Rect2, sunken := false, fill := true) -> void:
	if fill:
		draw_rect(rr, FACE, true)
	var a := DARK if sunken else LIGHT
	var b := LIGHT if sunken else DARKER
	draw_line(rr.position, Vector2(rr.end.x - 1, rr.position.y), a)
	draw_line(rr.position, Vector2(rr.position.x, rr.end.y - 1), a)
	draw_line(Vector2(rr.position.x, rr.end.y - 1), rr.end - Vector2(1, 1), b)
	draw_line(Vector2(rr.end.x - 1, rr.position.y), rr.end - Vector2(1, 1), b)


func text_at(rr: Rect2, s: String, align := 0, col := TEXT, fs := FS) -> void:
	var f := _font()
	var asc := f.get_ascent(fs)
	var y := rr.position.y + (rr.size.y - f.get_height(fs)) / 2 + asc
	# like Win32 statics the text is not cut; centred / right-aligned text wider than its rect starts at the left
	var tw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := rr.position.x
	if tw < rr.size.x:
		if align == 1:
			x += (rr.size.x - tw) / 2
		elif align == 2:
			x += rr.size.x - tw
	draw_string(f, Vector2(x, y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw() -> void:
	var cr := client_rect()
	var win := Rect2(cr.position - Vector2(3, CAP_H + 3), cr.size + Vector2(6, CAP_H + 6))
	bevel(win)
	var cap := Rect2(win.position + Vector2(3, 3), Vector2(win.size.x - 6, CAP_H - 2))
	draw_rect(cap, CAPTION, true)
	draw_rect(Rect2(cap.position + Vector2(cap.size.x * 0.5, 0), Vector2(cap.size.x * 0.5, cap.size.y)),
			CAPTION2.lerp(CAPTION, 0.4), true)
	text_at(Rect2(cap.position + Vector2(4, 0), cap.size), title, 0, LIGHT)
	for id in order:
		var c: Dictionary = ctrls[id]
		if c["visible"]:
			_draw_ctrl(c)
	if _combo_open != null:
		_draw_combo_drop(ctrls[_combo_open])


func _draw_ctrl(c: Dictionary) -> void:
	var rr: Rect2 = c["r"]
	match c["kind"]:
		"button":
			bevel(rr, _press_id == c["id"])
			var bfs := FS
			while bfs > 9 and _tw(c["text"], bfs) > rr.size.x - 4:
				bfs -= 1
			text_at(rr, c["text"], 1, TEXT if c["enabled"] else GREY, bfs)
		"group":
			var tw := _tw(c["text"])
			var top := rr.position.y + 6
			var gr := Rect2(rr.position.x, top, rr.size.x, rr.size.y - 6)
			draw_rect(Rect2(gr.position, gr.size - Vector2(1, 1)), DARK, false, 1.0)
			draw_rect(Rect2(gr.position + Vector2(1, 1), gr.size - Vector2(1, 1)), LIGHT, false, 1.0)
			if c["text"] != "":
				draw_rect(Rect2(rr.position.x + 6, top - 6, tw + 4, 12), FACE, true)
				text_at(Rect2(rr.position.x + 8, top - 7, tw, 12), c["text"])
		"line":
			draw_line(rr.position, Vector2(rr.end.x, rr.position.y), DARK)
			draw_line(rr.position + Vector2(0, 1), Vector2(rr.end.x, rr.position.y + 1), LIGHT)
		"static":
			if c["sunken"]:
				bevel(rr, true, false)
			var tr := rr.grow_individual(-2, 0, -2, 0)
			var s: String = c["text"]
			if s.contains("\n") or rr.size.y > FS * 2 + 4:
				_paragraph(tr.grow_individual(0, -2, 0, -2), s, c["color"])
			else:
				text_at(tr, s, int(c["align"]), c["color"] if c["enabled"] else GREY)
		"pic":
			if c.has("bg"):
				draw_rect(rr.grow(-1), c["bg"], true)
			if c["sunken"]:
				bevel(rr, true, false)
			var t: Texture2D = c["tex"]
			if t:
				var src: Rect2 = c.get("src", Rect2(Vector2.ZERO, t.get_size()))
				var inner := rr.grow(-1)
				var s2 := minf(inner.size.x / src.size.x, inner.size.y / src.size.y)
				var sz := src.size * minf(s2, float(c.get("max_scale", 99.0)))
				draw_texture_rect_region(t, Rect2(inner.position + (inner.size - sz) / 2, sz), src)
			if c.get("hilite", false):
				draw_rect(rr.grow(-1), Color(0.04, 0.14, 0.42, 0.35), true)
		"bar":
			if not c["on"]:
				return
			bevel(rr, true, false)
			if c["on"]:
				var inner2 := rr.grow(-2)
				var fr := clampf(float(c["value"]) / maxf(float(c["maxv"]), 1.0), 0.0, 1.0)
				_bar_fill(Rect2(inner2.position, Vector2(inner2.size.x * fr, inner2.size.y)), int(c.get("style", 5)))
				text_at(inner2, c["label"], 2, TEXT, 10)
		"tab":
			_draw_tab(c)
		"combo":
			draw_rect(rr, WINDOW, true)
			bevel(rr, true, false)
			var items: Array = c["items"]
			var sel := int(c["sel"])
			if sel >= 0 and sel < items.size():
				text_at(Rect2(rr.position + Vector2(3, 0), rr.size - Vector2(20, 0)), str(items[sel]))
			var b := Rect2(rr.end.x - 16, rr.position.y + 2, 14, rr.size.y - 4)
			bevel(b)
			var cx := b.get_center()
			draw_colored_polygon(PackedVector2Array([cx + Vector2(-3, -1), cx + Vector2(4, -1), cx + Vector2(0, 3)]), TEXT)
		"list":
			(c["lv"] as ListView).draw(self, c["enabled"])


## Bar fill of the painter 0x46146f: the colour gradients of Mark.e5 [0] (条状物, 2×84: 8 rows each — red, yellow,
## green, blue, cyan, pink) stretched over the bar. [G] style → gradient: 1 HP green, 2 / 4 HP / MP with an ailment
## red, 3 MP blue, 5 Exp yellow, 6 a stat cyan, 7 a lowered stat red, 8 a raised stat pink.
const BAR_ROWS := {1: 16, 2: 0, 3: 24, 4: 0, 5: 8, 6: 32, 7: 0, 8: 40}


func _bar_fill(rr: Rect2, style: int) -> void:
	if rr.size.x <= 0:
		return
	var t: Texture2D = Assets.tex("gfx/ui/mark/00.png")
	if t == null:
		draw_rect(rr, Color8(0, 0, 160), true)
		return
	draw_texture_rect_region(t, rr, Rect2(0, int(BAR_ROWS.get(style, 8)), 2, 7))


func _draw_tab(c: Dictionary) -> void:
	var rr: Rect2 = c["r"]
	var body := Rect2(rr.position.x, rr.position.y + 18, rr.size.x, rr.size.y - 18)
	bevel(body)
	var rects := _tab_rects(c)
	for k in rects.size():
		var t: Rect2 = rects[k]
		if k == int(c["sel"]):
			t = t.grow_individual(2, 2, 2, 1)
		draw_rect(t, FACE, true)
		draw_line(t.position, Vector2(t.end.x - 1, t.position.y), LIGHT)
		draw_line(t.position, Vector2(t.position.x, t.end.y), LIGHT)
		draw_line(Vector2(t.end.x - 1, t.position.y), Vector2(t.end.x - 1, t.end.y), DARKER)
		text_at(t, str(c["labels"][k]), 1)


func _draw_combo_drop(c: Dictionary) -> void:
	var rr := _combo_rows_rect(c)
	draw_rect(rr, WINDOW, true)
	draw_rect(rr, TEXT, false, 1.0)
	var items: Array = c["items"]
	var n := int((rr.size.y - 2) / 16.0)
	var top := clampi(int(c["sel"]) - n / 2, 0, maxi(items.size() - n, 0))
	c["top"] = top
	for k in n:
		var i := top + k
		if i >= items.size():
			break
		var row := Rect2(rr.position.x + 1, rr.position.y + 1 + 16 * k, rr.size.x - 2, 16)
		var hot := i == _combo_hover
		if hot:
			draw_rect(row, HILITE, true)
		text_at(row.grow_individual(-2, 0, 0, 0), str(items[i]), 0, LIGHT if hot else TEXT)


func _paragraph(rr: Rect2, s: String, col: Color) -> void:
	var f := _font()
	var lines := maxi(int(rr.size.y / f.get_height(FS)), 1)
	draw_multiline_string(f, rr.position + Vector2(0, f.get_ascent(FS)), s.replace("\r", ""), HORIZONTAL_ALIGNMENT_LEFT,
			rr.size.x, FS, lines, col)


## SysListView32 in report view with owner-drawn rows (0x46776a): an icon column, the header, a vertical scroll bar.
## Rows whose `enabled` is false are drawn grey (the lists' vtable+0x20 → colour 0x80) and do not act on a click.
class ListView:
	extends RefCounted
	var rect := Rect2()
	var columns: Array = []      # {title, w, align}
	var rows: Array = []         # {cells: [String], icon: Texture2D, enabled: bool, data: Variant}
	var sel := -1
	var top := 0
	var header := true
	const ROW := 18.0
	var _drag_y := 0.0
	var _drag_top := 0

	func header_rect() -> Rect2:
		return Rect2(rect.position + Vector2(2, 2), Vector2(rect.size.x - 4, ROW if header else 0.0))

	func body_rect() -> Rect2:
		var h := header_rect()
		return Rect2(rect.position.x + 2, h.end.y, rect.size.x - 4 - (16 if need_scroll() else 0), rect.end.y - 2 - h.end.y)

	func visible_rows() -> int:
		var h := rect.size.y - 4 - (ROW if header else 0.0)
		return maxi(int(h / ROW), 1)

	func need_scroll() -> bool:
		return rows.size() > visible_rows()

	func scroll(d: int) -> void:
		top = clampi(top + d, 0, maxi(rows.size() - visible_rows(), 0))

	func ensure_visible(i: int) -> void:
		if i < top:
			top = i
		elif i >= top + visible_rows():
			top = i - visible_rows() + 1
		scroll(0)

	func row_at(p: Vector2) -> int:
		var b := body_rect()
		if not b.has_point(p):
			return -1
		var i := top + int((p.y - b.position.y) / ROW)
		return i if i < rows.size() else -1

	func row_enabled(i: int) -> bool:
		return i >= 0 and i < rows.size() and bool(rows[i].get("enabled", true))

	func on_scrollbar(p: Vector2) -> bool:
		return need_scroll() and Rect2(rect.end.x - 18, body_rect().position.y, 16, body_rect().size.y).has_point(p)

	func thumb_rect() -> Rect2:
		var b := body_rect()
		var track := Rect2(rect.end.x - 18, b.position.y + 16, 16, b.size.y - 32)
		var n := rows.size()
		var v := visible_rows()
		var th := maxf(track.size.y * v / maxf(n, 1), 12.0)
		var span := maxi(n - v, 1)
		return Rect2(track.position.x, track.position.y + (track.size.y - th) * top / span, 16, th)

	func begin_drag(p: Vector2) -> void:
		_drag_y = p.y
		_drag_top = top

	func drag_thumb(p: Vector2) -> void:
		var b := body_rect()
		var track_h := b.size.y - 32 - thumb_rect().size.y
		if track_h <= 0:
			return
		top = _drag_top
		scroll(int(round((p.y - _drag_y) / track_h * maxi(rows.size() - visible_rows(), 1))))

	func page(p: Vector2) -> void:
		var b := body_rect()
		if p.y < b.position.y + 16:
			scroll(-1)
		elif p.y > b.end.y - 16:
			scroll(1)
		elif p.y < thumb_rect().position.y:
			scroll(-visible_rows())
		else:
			scroll(visible_rows())

	## Column widths from sample strings + padding, stretched to the client width (0x466eaf / 0x4640c5).
	func fit_columns(_d: Variant) -> void:
		var tot := 0.0
		for c in columns:
			tot += float(c["w"])
		var avail := rect.size.x - 4 - (16 if need_scroll() else 0)
		if tot <= 0:
			return
		for c in columns:
			c["w"] = float(c["w"]) * avail / tot

	func draw(d: Variant, enabled: bool) -> void:
		d.draw_rect(rect, Color8(255, 255, 255), true)
		d.bevel(rect, true, false)
		var x := rect.position.x + 2
		if header:
			var hr := header_rect()
			for c in columns:
				var w: float = c["w"]
				var cr := Rect2(x, hr.position.y, w, hr.size.y)
				d.bevel(cr)
				d.text_at(cr.grow_individual(-4, 0, -4, 0), str(c["title"]), int(c["align"]))
				x += w
		var b := body_rect()
		var n := visible_rows()
		for k in n:
			var i := top + k
			if i >= rows.size():
				break
			var row: Dictionary = rows[i]
			var rr := Rect2(b.position.x, b.position.y + k * ROW, b.size.x, ROW)
			var hot := i == sel
			var on := enabled and bool(row.get("enabled", true))
			var col := Color8(0, 0, 0) if on else Color8(128, 128, 128)
			if hot:
				d.draw_rect(rr, Color8(10, 36, 106), true)
				col = Color8(255, 255, 255) if on else Color8(192, 192, 192)
			var cx := rr.position.x
			var cells: Array = row["cells"]
			for ci in columns.size():
				var w2: float = columns[ci]["w"]
				var cell := Rect2(cx, rr.position.y, w2, rr.size.y)
				var tr := cell.grow_individual(-5, 0, -5, 0)
				if ci == 0 and row.get("icon") != null:
					var ic: Texture2D = row["icon"]
					d.draw_texture_rect(ic, Rect2(cell.position + Vector2(2, 1), Vector2(16, 16)), false)
					tr = tr.grow_individual(-17, 0, 0, 0)
				if ci < cells.size():
					d.text_at(tr, str(cells[ci]), int(columns[ci]["align"]), col)
				cx += w2
		if need_scroll():
			var track := Rect2(rect.end.x - 18, b.position.y, 16, b.size.y)
			d.draw_rect(track, Color8(224, 224, 224), true)
			d.bevel(Rect2(track.position, Vector2(16, 16)))
			d.bevel(Rect2(track.end - Vector2(16, 16), Vector2(16, 16)))
			d.bevel(thumb_rect())
