class_name HistoryWin66
extends Control
## 历史情报 (dialog 341, 0x41c3d7 open, painter 0x41bf21): the records op 0x16 writes while EV[4071] ≠ 0 —
## buffer 0x509000, byte length u32 0x508994, record = "&" + category byte (1..4) + text (no terminator; the next
## record's "&" follows). The painter splits records into lines (0x44d950): "\n" ends a line, "&c" starts the next
## record with category c, NUL ends; with EV[4060] = 0 the digits at the start of every line (the records' sort
## numbers) are skipped; "*/N" shows EV[N]. Lines are coloured by category (COLORREF table 0x4828e8: 1 black, 2 red,
## 3 blue, 4 purple) with the "[Cxx" markup (0x41c99a), 宋体 weight 600, from x 4.
## Order by EV[4064]: 1 = all records in buffer order; ≥ 2 = only category EV[4064] − 1; 0 = categories 1..4 one
## after the other. An empty buffer opens the 确认 box instead (0x42f699(0)). The original window is modeless
## (CreateDialogParam) with a scroll bar; here it is modal and scrolls by wheel / Up / Down / Page keys, and closes with
## a right click, Esc or the × box.

signal closed

const BUF := 0x509000
const LEN := 0x508994
const CAT_COLOURS := [Color8(0, 0, 0), Color8(255, 0, 0), Color8(0, 0, 255), Color8(240, 0, 240)]
const FS := 12
const LH := 14.0

var _rect := Rect2()
var _area := Rect2()
var _lines: Array = []        # [category, glyphs]
var _top := 0
var _rows := 1


## Records as display lines (0x41bf21 + 0x44d950).
static func lines() -> Array:
	var n := Mem.r32(LEN)
	var b := PackedByteArray()
	for i in n:
		b.append(Mem.r8(BUF + i))
	# split into [category, line bytes]
	var raw := []
	var cat := 1
	var cur := PackedByteArray()
	var i := 0
	while i < b.size():
		var c := b[i]
		if c == 0x26 and i + 1 < b.size():          # "&" + category: a new record
			if not cur.is_empty() or not raw.is_empty():
				raw.append([cat, cur])
			cur = PackedByteArray()
			cat = b[i + 1]
			i += 2
			continue
		if c == 0x0a:
			raw.append([cat, cur])
			cur = PackedByteArray()
			i += 1
			continue
		if c >= 0x80 and i + 1 < b.size():
			cur.append(c)
			cur.append(b[i + 1])
			i += 2
			continue
		cur.append(c)
		i += 1
	if not cur.is_empty():
		raw.append([cat, cur])
	var out := []
	var skip_digits := Mem.ev(4060) == 0
	for e in raw:
		var lb: PackedByteArray = e[1]
		var k := 0
		if skip_digits:
			while k < lb.size() and lb[k] >= 0x30 and lb[k] <= 0x39:
				k += 1
		var s := TextExpand.from_gbk(lb.slice(k)).replace("\r", "")
		out.append([int(e[0]), _expand_ev(s)])
	return out


## "*/N" → EV[N] in decimal (0x44d950 → 0x426e64 / 0x4246ae).
static func _expand_ev(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "*" and i + 1 < s.length() and s[i + 1] == "/":
			var j := i + 2
			var num := ""
			while j < s.length() and s[j] >= "0" and s[j] <= "9":
				num += s[j]
				j += 1
			out += str(Mem.r32s(Mem.EV + 4 * int(num))) if num != "" else ""
			i = j
			continue
		out += s[i]
		i += 1
	return out


## Lines in the order of EV[4064].
static func ordered() -> Array:
	var all := lines()
	var mode := Mem.ev(4064)
	if mode == 1:
		return all
	if mode >= 2:
		return all.filter(func(e: Array) -> bool: return int(e[0]) == mode - 1)
	var out := []
	for c in range(1, 5):
		out.append_array(all.filter(func(e: Array) -> bool: return int(e[0]) == c))
	return out


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)


func run() -> void:
	for e in ordered():
		var st := {"c": 0, "open": false}
		_lines.append([int(e[0]), Text66.glyphs(str(e[1]), st)])
	var size := Vector2(205, 194) * 1.5 + Vector2(0, 18)
	_rect = Rect2(((Vector2(640, 480) - size) / 2).floor(), size)
	_area = Rect2(_rect.position + Vector2(6, 24), _rect.size - Vector2(12, 30))
	_rows = maxi(int((_area.size.y - 8) / LH), 1)
	queue_redraw()
	await closed


func _scroll(d: int) -> void:
	_top = clampi(_top + d, 0, maxi(_lines.size() - _rows, 0))
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	accept_event()
	if ev is InputEventMouseButton and ev.pressed:
		match ev.button_index:
			MOUSE_BUTTON_WHEEL_UP: _scroll(-3)
			MOUSE_BUTTON_WHEEL_DOWN: _scroll(3)
			MOUSE_BUTTON_RIGHT: closed.emit()
			MOUSE_BUTTON_LEFT:
				if _close_box().has_point(ev.position):
					closed.emit()


func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("ui_cancel"):
		closed.emit()
	elif ev.is_action_pressed("ui_up"):
		_scroll(-1)
	elif ev.is_action_pressed("ui_down"):
		_scroll(1)
	elif ev.is_action_pressed("ui_page_up", true):
		_scroll(-_rows)
	elif ev.is_action_pressed("ui_page_down", true):
		_scroll(_rows)
	else:
		return
	get_viewport().set_input_as_handled()


func _close_box() -> Rect2:
	return Rect2(_rect.end.x - 20, _rect.position.y + 4, 15, 13)


func _draw() -> void:
	var f := Assets.font()
	var fv := FontVariation.new()
	fv.base_font = f
	fv.variation_embolden = 0.3                        # weight 600
	var asc := f.get_ascent(FS)
	draw_rect(_rect, SysDialog66.FACE, true)
	draw_rect(Rect2(_rect.position, _rect.size - Vector2(1, 1)), SysDialog66.LIGHT, false, 1.0)
	draw_line(Vector2(_rect.position.x, _rect.end.y - 1), _rect.end - Vector2(1, 1), SysDialog66.DARKER)
	draw_line(Vector2(_rect.end.x - 1, _rect.position.y), _rect.end - Vector2(1, 1), SysDialog66.DARKER)
	var cap := Rect2(_rect.position + Vector2(3, 3), Vector2(_rect.size.x - 6, 15))
	draw_rect(cap, SysDialog66.CAPTION, true)
	draw_string(f, cap.position + Vector2(4, asc + 1), "历史情报", HORIZONTAL_ALIGNMENT_LEFT, -1, FS, SysDialog66.LIGHT)
	var cb := _close_box()
	draw_rect(cb, SysDialog66.FACE, true)
	draw_string(f, cb.position + Vector2(3, asc), "×", HORIZONTAL_ALIGNMENT_LEFT, -1, FS, SysDialog66.TEXT)
	draw_rect(_area, Color.WHITE, true)
	draw_rect(_area, SysDialog66.DARK, false, 1.0)
	for r in _rows:
		var k := _top + r
		if k >= _lines.size():
			break
		var cat := clampi(int(_lines[k][0]) - 1, 0, 3)
		var y := _area.position.y + 4 + r * LH
		for g in _lines[k][1]:
			var c: Color = CAT_COLOURS[cat] if int(g[1]) == 0 else Text66.pal(int(g[1]))
			draw_string(fv, Vector2(_area.position.x + 4 + int(g[2]) * 6, y + asc), g[0], HORIZONTAL_ALIGNMENT_LEFT, -1, FS, c)
	if _lines.size() > _rows:
		var h := _area.size.y * _rows / _lines.size()
		var y0 := _area.position.y + (_area.size.y - h) * _top / maxf(_lines.size() - _rows, 1)
		draw_rect(Rect2(_area.end.x - 8, y0, 6, h), SysDialog66.DARK, true)
