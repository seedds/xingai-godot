class_name Sortie66
extends Dlg66
## Dialog 236 选择武将 (0x45e6b3 → proc 0x45e82a; selection object 0x45c131): the sortie choice before a battle.
##  * Upper picture (0x43f, 512×296, U_select[3]): the candidates — the forced persons first, then the other members
##    (builder 0x418597), at most 30 — on a grid of 8 × 4 cells of 64 × 72 (cell i at ((i % 8)·64, (i / 8)·72 + 8);
##    hit test 0x45c57a): the standing frame 6 of the unit graphic (colour 0) at x + 8, darkened 40 % when chosen
##    (0x45ce5a), the level at y + 32 and the name centred at y + 48; the hovered non-forced name is highlighted
##    (0x45cae9). Two sort buttons at (408, 244) / (408, 266), 88 × 16 (rects 0x486790, painter 0x45e495): the left
##    one toggles 顺 (class) / 武将名, the right one cycles 等级 / 攻击 / 防御 / 精神 (0x45e063; a button first takes
##    over the current key, the next click advances it); stable insertion sort 0x45de80, ascending for 顺 / 武将名,
##    descending for the others; the keys persist between calls (0x48e3a8, 0x48e3b0). First sort by the right
##    button's key, then by the current one (0x45c131).
##  * Count line 0x56c: "出阵武将  - %2d/%2d" (0x45daa5).
##  * Lower picture (0x441, 512×128, U_select[4]): the 20 sortie slots, 10 × 2 of 51 × 64 (hit test 0x45c614):
##    pedestals U_select[0..2] at ((i % 10)·51 + 1, (i / 10)·64 + 13) for i < max — frame 2 for forced slots, 1 up
##    to ⌊2·max / 3⌋, 0 beyond — and the chosen units' standing frames at y − 12.
##  * A left click on a non-forced candidate (in either picture, 0x410942 / 0x45d85d) adds it (SE 15) when there is
##    room, or removes it (SE 1) and closes the gap; a right click opens its 武将情报 (0x412291). The 武将情报 group
##    shows the hovered person (0x45c697): portrait, name, class, Lv, 武力 统率 智力 敏捷 运气, HP (bar of 1000), MP
##    (255), Exp (100, "MAX"), 攻击 防御 精神 爆发 士气 (1200) and 移动.
##  * 决定 is enabled while 1 ≤ count ≥ ⌊2·max / 3⌋ (0x4090fa); 取消 clears every slot, the forced ones too
##    (0x45c085 / 0x427700): the result is empty. 战场位置 stays disabled (template WS_DISABLED). [G] Esc = 取消.
## The original's pictures are pixel-exact child windows larger than the 640×480 screen allows; they are scaled
## with the dialog here.

const KEY_NAMES := ["顺", "武将名", "等级", "攻击", "防御", "精神"]
const SORT_RECTS := [Rect2(408, 244, 88, 16), Rect2(408, 266, 88, 16)]
const UP_W := 512.0
const UP_H := 296.0
const LO_H := 128.0
const COL_TEXT := Color8(255, 255, 255)
const COL_HI := Color8(255, 255, 96)          # [G] text colour 0x28
const COL_LV := Color8(160, 224, 255)         # [G] 0x3a
const COL_LV_ON := Color8(255, 176, 64)       # [G] the chosen non-forced level

static var sort_cur := 0                      # 0x48e3a8
static var sort_keys := [0, 2]                # 0x48e3b0

var cands: Array[int] = []    # person ids
var nforced := 0
var maxn := 0
var disp: Array[int] = []    # display position → candidate index (+10)
var chosen: Array[int] = []   # slot → candidate index (+0x28)
var hovered := -1             # +8
var _pressed_sort := -1       # +0x104
var _up := Rect2()            # the pictures on the screen
var _lo := Rect2()
var _k := 1.0                 # screen px per original px
var _bg_up: Texture2D
var _bg_lo: Texture2D


## Returns the chosen person ids in slot order, or [] when cancelled.
static func run(ui: Node, candidates: Array[int], forced_count: int, max_count: int) -> Array[int]:
	var d := Sortie66.new()
	d.build(candidates, forced_count, max_count)
	var res: Variant = await Dlg66.run_dialog(ui, d)
	var out: Array[int] = []
	if res is Array:
		for v in res:
			out.append(int(v))
	return out


func build(candidates: Array[int], forced_count: int, max_count: int) -> void:
	cands.assign(candidates.slice(0, 30))
	nforced = mini(forced_count, cands.size())
	maxn = mini(max_count, cands.size())
	for i in cands.size():
		disp.append(i)
	for i in nforced:
		chosen.append(i)
	_sort(sort_keys[1])
	if sort_cur != sort_keys[1]:
		_sort(sort_cur)
	setup("选择武将", 475, 314)
	_k = dscale / 1.5
	var col := r(3, 1, 340, 294)
	var tot := (UP_H + 2 + 18 + LO_H + 2) * _k
	var x0 := col.position.x + (col.size.x - (UP_W + 2) * _k) / 2
	var y0 := col.position.y + maxf((col.size.y - tot) / 2, 0)
	_up = Rect2(x0 + _k, y0 + _k, UP_W * _k, UP_H * _k)
	_lo = Rect2(x0 + _k, y0 + (UP_H + 2 + 18 + 1) * _k, UP_W * _k, LO_H * _k)
	_bg_up = Assets.tex("gfx/ui/u_select/03.jpg")
	_bg_lo = Assets.tex("gfx/ui/u_select/04.jpg")
	add_group(348, 1, 125, 294, "武将情报")
	add_pic(0x434, 352, 12, 80, 80)
	add_static(0x473, 434, 13, 38, 10)
	add_static(0x475, 434, 23, 35, 8)
	var labels := ["Lv", "武力", "统率", "智力", "敏捷", "运气"]
	var ly := [33, 44, 54, 64, 74, 84]
	for k in 6:
		add_static(null, 434, ly[k], 21, 8, labels[k])
		add_static(0x3f7 + k, 456, ly[k], 14, 8, "", 2)
	var groups := ["HP", "MP", "Exp", "攻击", "防御", "精神", "爆发", "士气", "移动"]
	for k in 9:
		var gy := 94 + 22 * k
		add_group(352, gy, 117, 21, groups[k])
		if k < 8:
			add_bar(0x563 + k, 356, gy + 9, 87, 7)
		add_static(0x3fd + k, 446, gy + 8, 18, 8, "", 2)
	add_button(0x3e9, 348, 298, 44, 14, "战场位置")
	enable(0x3e9, false)
	add_button(1, 397, 298, 37, 14, "决定")
	add_button(2, 435, 298, 37, 14, "取消")
	_update_ok()
	_info()


# ------------------------------------------------------------------ model
func _key_value(ci: int, key: int) -> int:
	var p := Game.person(cands[ci])
	match key:
		0: return p.cls
		1: return p.id
		2: return p.level
		3, 4, 5: return p.stat(key - 3)
	return 0


## 0x45de80: insertion sort of the display order (stable).
func _sort(key: int) -> void:
	var asc := key < 2
	for i in range(1, disp.size()):
		var j := i
		while j > 0:
			var d := _key_value(disp[j], key) - _key_value(disp[j - 1], key)
			if (asc and d >= 0) or (not asc and d <= 0):
				break
			var t := disp[j]
			disp[j] = disp[j - 1]
			disp[j - 1] = t
			j -= 1


## 0x45d85d: add / remove a non-forced candidate.
func _toggle(ci: int) -> void:
	if ci < nforced:
		return
	var at := chosen.find(ci)
	if at < 0:
		if chosen.size() < maxn:
			SoundMap.play_se_id(0xf, 1)
			chosen.append(ci)
	else:
		SoundMap.play_se_id(1, 1)
		chosen.remove_at(at)
	_update_ok()
	queue_redraw()


func _update_ok() -> void:
	enable(1, chosen.size() != 0 and chosen.size() >= maxn * 2 / 3)


## The 武将情报 group for the hovered candidate (0x45c697).
func _info() -> void:
	var on := hovered >= 0
	var p: Person = Game.person(cands[hovered]) if on else null
	ctrl(0x434)["tex"] = p.face_tex() if on else null
	set_text(0x473, p.name if on else "")
	set_text(0x475, p.class_name_str() if on else "")
	set_text(0x3f7, "%d" % p.level if on else "")
	for k in 5:
		set_text(0x3f8 + k, "%d" % Mem.r8(p.base + 0x21 + k) if on else "")
	var vals := []
	var maxes := [1000, 255, 100, 1200, 1200, 1200, 1200, 1200]
	var styles := [1, 3, 5, 6, 6, 6, 6, 6]
	if on:
		vals = [p.max_hp(), p.max_mp(), 100 if p.exp == 0xff else p.exp]
		for s in 5:
			vals.append(p.stat(s))
	for k in 8:
		var c := ctrl(0x563 + k)
		c["on"] = on
		c["value"] = vals[k] if on else 0
		c["maxv"] = maxes[k]
		c["style"] = styles[k]
		c["label"] = ""
		var t := ""
		if on:
			t = "MAX" if k == 2 and p.exp == 0xff else "%d" % vals[k]
		set_text(0x3fd + k, t)
	set_text(0x405, "%d" % p.move_points() if on else "")
	queue_redraw()


# ------------------------------------------------------------------ hit tests
func _up_local(p: Vector2) -> Vector2:
	return (p - _up.position) / _k


func _lo_local(p: Vector2) -> Vector2:
	return (p - _lo.position) / _k


## 0x45c57a: the candidate under an upper-picture point, or −1.
func _cand_up(q: Vector2) -> int:
	if q.x < 8 or q.y < 8:
		return -1
	var c := int(q.x - 8) / 64
	var rr := int(q.y - 8) / 72
	if c >= 8 or rr >= 4:
		return -1
	var pos := c + rr * 8
	return disp[pos] if pos < disp.size() else -1


## 0x45c614: the candidate in a lower-picture slot, or −1.
func _cand_lo(q: Vector2) -> int:
	if q.x < 0 or q.y < 0:
		return -1
	var c := int(q.x) / 51
	var rr := int(q.y) >> 6
	if c >= 10 or rr >= 2:
		return -1
	var i := rr * 10 + c
	return chosen[i] if i < chosen.size() else -1


func _cand_at(p: Vector2) -> int:
	if _up.has_point(p):
		return _cand_up(_up_local(p))
	if _lo.has_point(p):
		return _cand_lo(_lo_local(p))
	return -1


func _sort_at(p: Vector2) -> int:
	if not _up.has_point(p):
		return -1
	var q := _up_local(p)
	for b in 2:
		if (SORT_RECTS[b] as Rect2).has_point(q):
			return b
	return -1


func _gui_input(ev: InputEvent) -> void:
	if _done:
		return
	if ev is InputEventMouseMotion and (_up.has_point(ev.position) or _lo.has_point(ev.position)):
		_hover(_cand_at(ev.position))
		if _pressed_sort >= 0:
			var b := _sort_at(ev.position)
			if b != _pressed_sort:
				queue_redraw()
		accept_event()
		return
	if ev is InputEventMouseButton and (_up.has_point(ev.position) or _lo.has_point(ev.position) or _pressed_sort >= 0):
		accept_event()
		var p: Vector2 = ev.position
		var ci := _cand_at(p)
		if ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				_hover(ci)
				_pressed_sort = _sort_at(p)
				queue_redraw()
			else:
				var b := _pressed_sort
				_pressed_sort = -1
				if b >= 0:
					if _sort_at(p) == b:
						_sort_click(b)
					queue_redraw()
				elif ci >= 0:
					_hover(ci)
					_toggle(ci)
		elif ev.button_index == MOUSE_BUTTON_RIGHT and not ev.pressed and ci >= 0:
			_hover(ci)
			await StatusPanel.show_person(self, Game.person(cands[ci]))
		return
	super._gui_input(ev)


func _hover(ci: int) -> void:
	if ci == hovered or ci < 0:
		return
	hovered = ci
	_info()


## 0x45e063.
func _sort_click(b: int) -> void:
	if b == 1:
		if sort_cur > 1:
			sort_keys[1] += 1
			if sort_keys[1] > 5:
				sort_keys[1] = 2
	elif sort_cur < 2:
		sort_keys[0] += 1
		if sort_keys[0] > 1:
			sort_keys[0] = 0
	sort_cur = sort_keys[b]
	_sort(sort_cur)


func _on_command(id: Variant) -> void:
	match id:
		1:
			SoundMap.play_se_id(5, 1)
			var out := []
			for ci in chosen:
				out.append(cands[ci])
			close(out)
		2:
			chosen.clear()
			close([])


# ------------------------------------------------------------------ drawing
func _draw() -> void:
	super._draw()
	_draw_upper()
	_draw_lower()
	var cr := Rect2(_up.position.x, _up.end.y + 2 * _k, _up.size.x, 16 * _k)
	text_at(cr, "出阵武将  - %2d/%2d" % [chosen.size(), maxn], 0)


func _sprite(pid: int) -> Texture2D:
	return Assets.tex("gfx/units/mov/%03d.png" % Game.person(pid).sprite_entry(0))


func _draw_unit(at: Vector2, pid: int, dark: bool) -> void:
	var t := _sprite(pid)
	if t == null:
		return
	draw_texture_rect_region(t, Rect2(at, Vector2(48, 48)), Rect2(0, 6 * 48, 48, 48),
		Color(0.6, 0.6, 0.6) if dark else Color(1, 1, 1))


func _draw_upper() -> void:
	draw_rect(_up.grow(1), DARK, false, 1.0)
	draw_set_transform(_up.position, 0, Vector2(_k, _k))
	if _bg_up:
		draw_texture_rect(_bg_up, Rect2(0, 0, UP_W, UP_H), false)
	var f := _font()
	for pos in disp.size():
		var ci := disp[pos]
		var pid := cands[ci]
		var x := (pos % 8) * 64.0
		var y := (pos / 8) * 72.0 + 8
		var on := chosen.has(ci)
		_draw_unit(Vector2(x + 8, y), pid, on)
		var lv_col := COL_LV
		if on:
			lv_col = COL_HI if ci < nforced else COL_LV_ON
		_outlined(f, Vector2(x + 2, y + 32 + 13), "%d" % Game.person(pid).level, lv_col, 14)
		var nm := Game.person(pid).name
		var w := f.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		_outlined(f, Vector2(x + (64 - w) / 2, y + 48 + 14), nm, COL_HI if ci == hovered and ci >= nforced else COL_TEXT, 14)
	for b in 2:
		var rr: Rect2 = SORT_RECTS[b]
		var box := Rect2(rr.position + Vector2(2, 4), Vector2(88, 16))
		draw_rect(box, Color(0, 0, 1, 0.32))
		var label := "<%s>" % KEY_NAMES[sort_keys[b]]
		var lw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var off := Vector2(1, 1) if _pressed_sort == b else Vector2.ZERO
		_outlined(f, Vector2(box.position.x + (88 - lw) / 2, box.position.y + 13) + off, label,
			COL_HI if sort_keys[b] == sort_cur else Color8(200, 200, 200), 14)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


func _draw_lower() -> void:
	draw_rect(_lo.grow(1), DARK, false, 1.0)
	draw_set_transform(_lo.position, 0, Vector2(_k, _k))
	if _bg_lo:
		draw_texture_rect(_bg_lo, Rect2(0, 0, UP_W, LO_H), false)
	for i in maxn:
		var fr := 0
		if i < nforced:
			fr = 2
		elif i < maxn * 2 / 3:
			fr = 1
		var ft := Assets.tex("gfx/ui/u_select/%02d.png" % fr)
		if ft:
			draw_texture_rect(ft, Rect2((i % 10) * 51 + 1, (i / 10) * 64 + 13, 50, 50), false)
	for i in chosen.size():
		_draw_unit(Vector2((i % 10) * 51 + 1, (i / 10) * 64 + 1), cands[chosen[i]], false)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)


func _outlined(f: Font, at: Vector2, s: String, col: Color, fs: int) -> void:
	draw_string_outline(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0))
	draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
