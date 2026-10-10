class_name GameUI
extends CanvasLayer
## Top-level UI: dialog, menus, popups, banners, captions, fades, cutscene video.
## The script windows of the 6.6 engine (talk window, message boxes, choice window, three-portrait window, captions,
## chapter titles, title / place fields, map portraits) are drawn like the original (Windows66, Win66, Text66);
## the older port windows (dialog.talk, popup, menu.choose, banner) stay for the battle and menu code.

var dialog: DialogBox
var menu: ChoiceMenu
var video: VideoLayer
var fade_rect: ColorRect
var _popup_box: PanelContainer
var _popup_label: Label
var _banner: Label
var _caption_root: Control
var _caption_lines: Array[Label] = []
var _title_root: Control
var _portrait_root: Node2D
var _win_root: Control           # the 6.6 script windows (above the fade: they show on a black screen)
var _cap: Win66                  # caption band (op 0x2c)
var _cap_col := 8                # 0x4b2b98 + 0x60: caption column (8-px units)
var _cap_y := 0x170              # + 0x64: caption line y
var _cap_dark := true            # + 0x68: the band still has to be darkened
var _info: _InfoBar              # title / place-name fields (ops 0x18 / 0x17)
var info_title := ""             # 0x49f1cc
var info_place := ""             # 0x4b0758
var _portraits: Array = []       # 0x4b2b98 slots (≤ 8): [pid, Sprite2D]

## Talk-window side flags and last speakers (0x48e864 / 0x4b1b24 story, 0x48e860 / 0x4b1b20 battle). Never reset
## by the original (initial 1 / none); not saved.
var talk_side := 1
var talk_last := -1
var btalk_side := 1
var btalk_last := -1


func _init() -> void:
	layer = 20
	# map portraits (ops 0x29..0x2b) are part of the scene picture: under the fade
	_portrait_root = Node2D.new()
	add_child(_portrait_root)
	var cap := Control.new()
	cap.set_anchors_preset(Control.PRESET_FULL_RECT)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cap)
	_caption_root = cap

	fade_rect = ColorRect.new()
	fade_rect.color = Color(0, 0, 0, 0)
	fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fade_rect)

	_info = _InfoBar.new()
	_info.ui = self
	add_child(_info)

	# 6.6 windows and captions are drawn into the screen itself, so they show on a black screen too
	_win_root = Control.new()
	_win_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_win_root)

	# chapter titles are usually shown on a black screen, so they go above the fade
	_title_root = Control.new()
	_title_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title_root)

	_banner = UIStyle.label("", 22, Color(1, 0.95, 0.7))
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.visible = false
	add_child(_banner)

	dialog = DialogBox.new()
	add_child(dialog)
	menu = ChoiceMenu.new()
	add_child(menu)

	_popup_box = PanelContainer.new()
	_popup_box.add_theme_stylebox_override("panel", UIStyle.panel_box())
	_popup_label = UIStyle.label("")
	_popup_box.add_child(_popup_label)
	_popup_box.visible = false
	add_child(_popup_box)

	video = VideoLayer.new()
	add_child(video)


func vsize() -> Vector2:
	return get_viewport().get_visible_rect().size


# ------------------------------------------------------------------ fades
## The 6.6 fades redraw or clear the screen, which also wipes the captions drawn on it (0x413e49 / 0x413ec7).
func fade_to_black(t := 0.35) -> void:
	clear_captions()
	if Game.autoplay:
		fade_rect.color.a = 1.0
		return
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", 1.0, t)
	await tw.finished


func fade_from_black(t := 0.35) -> void:
	clear_captions()
	if Game.autoplay:
		fade_rect.color.a = 0.0
		return
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", 0.0, t)
	await tw.finished


func set_black(on: bool) -> void:
	fade_rect.color.a = 1.0 if on else 0.0


# ------------------------------------------------------------------ popup (click to close)
func popup(text: String, auto_close := 0.0) -> void:
	if Game.autoplay:
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [popup] ", text)
		return
	_popup_label.text = text
	_popup_box.visible = true
	_popup_box.reset_size()
	await get_tree().process_frame
	_popup_box.position = (vsize() - _popup_box.size) / 2
	if auto_close > 0:
		await get_tree().create_timer(auto_close).timeout
	else:
		await _wait_click()
	_popup_box.visible = false


func _wait_click() -> void:
	if Game.demo:
		await get_tree().create_timer(1.2).timeout
		return
	if Game.autoplay:
		await get_tree().process_frame
		return
	# a new press (counted by Game._input), so the click that closed the previous box is not reused
	# and a tap shorter than a frame is not missed; holding Ctrl skips
	var n := Game.clicks
	while Game.clicks == n and not Game.skip_held():
		await get_tree().process_frame


# ------------------------------------------------------------------ banners / captions
## kind 0 = title (top-centre), 1 = place name (top-left)
func banner(text: String, kind: int) -> void:
	if Game.autoplay:
		return
	_banner.text = text
	_banner.add_theme_font_size_override("font_size", 24 if kind == 0 else 18)
	_banner.reset_size()
	if kind == 0:
		_banner.position = Vector2((vsize().x - _banner.size.x) / 2, vsize().y * 0.35)
	else:
		_banner.position = Vector2(24, 20)
	_banner.modulate.a = 0
	_banner.visible = true
	var tw := create_tween()
	tw.tween_property(_banner, "modulate:a", 1.0, 0.4)
	tw.tween_interval(1.4)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.4)
	await tw.finished
	_banner.visible = false


## Map text of op 0x2c (0x417235 → 0x4332a6(text, a1, a2, a3)), white, on the bottom band (0, 360)–(640, 440) of the
## scene, which the first caption after a clear darkens by 50 % (0x402edb(…, 0x32, 1), flag +0x68). a2 ≠ 0 starts
## a new line (column 8, y + 24) first; a1 = 0, or a new line below y 0x1b7, clears the band and restarts at
## (column 8, y 0x170). Text continues on the current line at the column where the last one ended (columns of 8 px,
## the markup bytes counted too); "\n" in the text starts a new line. Typewriter as the talk window. a3 ≠ 0: wait
## for a click (click mode) or 5 / 10 / 20 rounds of 2 ticks.
func caption(text: String, a1: int, a2: int, a3: int) -> void:
	Text66.trace("caption", text)
	if Game.autoplay:
		return
	if _cap == null:
		_cap = Win66.new()
		_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_win_root.add_child(_cap)
		_win_root.move_child(_cap, 0)
	if _cap_dark:
		_cap.parts.clear()
		_cap.fill(Rect2(0, 0x168, 0x280, 0x50), Color(0, 0, 0, 0.5))
		_cap_dark = false
	if a2 != 0:
		_cap_col = 8
		_cap_y += 0x18
	if a1 == 0 or (a2 != 0 and _cap_y > 0x1b7):
		_cap_col = 8
		_cap_y = 0x170
		_cap.clear_texts()
	var st := {"c": Text66.C_WHITE, "open": false}
	var ls := text.replace("\r", "").split("\n")
	for k in ls.size():
		_cap.text_line(_cap_col * Text66.COL, _cap_y, ls[k], st)
		await _cap.type_page(Text66.speed() != 0)
		_cap_col += Text66.gbk_len(ls[k]) + (1 if k < ls.size() - 1 else 0)
		if k < ls.size() - 1:
			_cap_col = 8
			_cap_y += 0x18
	if a3 != 0:
		_cap.mouse_filter = Control.MOUSE_FILTER_STOP
		if Game.demo:
			await get_tree().create_timer(1.2).timeout
		elif Text66.click_mode():
			await _wait_click()
		else:
			await _cap.rounds_or_click([5, 10, 20][mini(Text66.speed(), 2)])
		if is_instance_valid(_cap):
			_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Remove the captions and the darkened band (the scene is redrawn: scene change, fades). The next caption darkens
## the band again.
func clear_captions() -> void:
	for c in _caption_lines:
		c.queue_free()
	_caption_lines.clear()
	if _cap:
		_cap.queue_free()
		_cap = null
	_cap_dark = true
	_cap_col = 8
	_cap_y = 0x170


## Special technique name (绝招) banner.
func skill_banner(text: String) -> void:
	if Game.autoplay:
		return
	var bg := ColorRect.new()
	bg.color = Color(1, 1, 1, 0.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var band := ColorRect.new()
	band.color = Color(0, 0, 0, 0.7)
	band.position = Vector2(0, vsize().y * 0.4 - 36)
	band.size = Vector2(vsize().x, 72)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(band)
	var l := UIStyle.label(text, 40, Color(1, 0.85, 0.3))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(vsize().x, 56)
	l.position = Vector2(vsize().x, vsize().y * 0.4 - 28)
	add_child(l)
	Audio.play_se("se37")
	var tw := create_tween()
	tw.tween_property(bg, "color:a", 0.7, 0.08)
	tw.tween_property(bg, "color:a", 0.0, 0.2)
	tw.parallel().tween_property(l, "position:x", 0.0, 0.25)
	tw.tween_interval(0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.25)
	tw.parallel().tween_property(band, "modulate:a", 0.0, 0.25)
	await tw.finished
	for n in [bg, band, l]:
		n.queue_free()


## Op 0x67 → 0x40b935(n, text): the screen is cleared to black (0x47d340), then "序章" (n = 0), "第一章".."第九章"
## (1..9) or "终章" (≥ 10) and then the title are each drawn centred in (0, 40)–(640, 440) in 64-px bold 宋体, white
## over two grey copies offset by 2 (#999999) and 1 (#cccccc) (0x40ba03), held for 20 / 40 rounds of 2 ticks or until
## a click (0x42c646), and faded out (0x4066a2). The screen stays black. n < 0 (port: the ending's "全剧终") shows
## only the text.
func chapter_title(num: int, text: String) -> void:
	if Game.autoplay:
		print("  [chapter] ", num, " ", text)
		return
	var head := ""
	if num >= 0:
		var n := num & 0xff
		if n == 0:
			head = "序章"
		elif n < 10:
			head = "第%s章" % ["一", "二", "三", "四", "五", "六", "七", "八", "九"][n - 1]
		else:
			head = "终章"
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.add_child(bg)
	var fv := FontVariation.new()
	fv.base_font = Assets.font()
	fv.variation_embolden = 0.9
	var k := 0
	for s in [head, text]:
		if s == "":
			k += 1
			continue
		var holder := Control.new()
		holder.position = Vector2(0, 0x28)
		holder.size = Vector2(0x280, 0x190)
		_title_root.add_child(holder)
		for layer in [[2, Text66.pal(0x18)], [1, Text66.pal(0x15)], [0, Text66.pal(Text66.C_WHITE)]]:
			var l := Label.new()
			l.text = s
			l.add_theme_font_override("font", fv)
			l.add_theme_font_size_override("font_size", 64)
			l.add_theme_color_override("font_color", layer[1])
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.position = Vector2(layer[0], layer[0])
			l.size = holder.size
			holder.add_child(l)
		await _rounds_or_click((k + 1) * 20)
		var tw := create_tween()
		tw.tween_property(holder, "modulate:a", 0.0, 0.4)      # [G] duration of the 0x402edb fade
		await tw.finished
		holder.queue_free()
		k += 1
	set_black(true)
	bg.queue_free()


## 0x42c646(n): n rounds of 2 ticks; a click ends it.
func _rounds_or_click(rounds: int) -> void:
	if Game.demo:
		await get_tree().create_timer(minf(rounds * 0.1, 2.0)).timeout
		return
	var n := Game.clicks
	var t := 0.0
	while t < rounds * 2 * Text66.TICK and Game.clicks == n and not Game.skip_held():
		await get_tree().process_frame
		t += get_process_delta_time()


# ------------------------------------------------------------------ 6.6 script windows
## Put a script window on the screen (above the fade and the captions, below the port's menus).
func add_window(w: Control) -> void:
	_win_root.add_child(w)


## Talk window 0x42d5b0(text, pid, flags) (ops 0x14 / 0x15 / 0x16, …): a portrait window for pid 0..0x3ff, the plain
## sand box otherwise; in a battle 0x42cd05 (placed by the speaker's unit). Returns when the last page is clicked.
func talk(pid: int, text: String, flags := 0x20) -> void:
	await Windows66.talk(self, pid, text, flags)


## Battle dialog with a speaker (op 0x14 in a battle → 0x45965d): only when the speaker's unit is on the map
## (talk_anchor(pid) with "battle" and "cell"); the stage's `talk_focus(pid)` (if any) scrolls to it first
## (0x4596bd), then the battle talk window 0x42cd05 opens next to the unit.
func battle_bubble(pid: int, text: String) -> void:
	var a: Variant = Windows66.anchor(pid)
	if not (a is Dictionary) or not bool(a.get("battle", false)) or not a.has("cell"):
		Text66.trace("skip", text)
		return
	var st: Variant = Game.main.stage if Game.main else null
	if st != null and st.has_method("talk_focus"):
		await st.talk_focus(pid)
		a = Windows66.anchor(pid)
	await Windows66.talk_battle(self, pid, text, a)


## Message box 0x42f699(style, text): 2 = the one-line narration box (op 0x69, item found, …), timed; 0 = the 确认
## dialog; 1 = yes / no (use yes_no()).
func message(style: int, text: String) -> void:
	if style == 2:
		await Windows66.message2(self, text)
	elif style == 1:
		await Windows66.dialog(self, text, true)
	else:
		await Windows66.dialog(self, text, false)


## 0x42f699(1, text): the 是 / 否 dialog (op 0x04 with "可以吗？"). True = 是.
func yes_no(text: String) -> bool:
	return await Windows66.dialog(self, text, true)


## Op 0x12 choice window 0x42de7d: `options` = the lines without numbers (≤ 6; "1."… are added here, as 0x42c9fc
## does), portrait of `pid` (0xFFFF → 0 is the caller's: the original shows person 0 then). 0-based index.
func choose_dialog(options: Array, pid: int) -> int:
	return await Windows66.choose(self, options, pid)


## 0x72 sub 34 dialog (0x42c992): `options` without numbers (≤ 9), radio buttons or check boxes (at most
## `max_checked` checked). Returns the chosen 0-based indices (one for radio buttons).
func choice_modal(options: Array, checkboxes: bool, max_checked: int) -> Array:
	return await Windows66.choice_modal(self, options, checkboxes, max_checked)


## One op 0x7a segment (0x42d8bf): persons [left, middle, right] (-1 = empty; in a battle already resolved from units
## by the caller), lit = mask bit 2 / 1 / 0. The window is drawn and removed per call, as in the original (its
## background is restored at the end of 0x42d8bf); consecutive segments show no gap.
func dialog3(persons: Array, lit_mask: int, text: String) -> void:
	await Windows66.dialog3(self, persons, lit_mask, text)


## Nothing to close: every dialog3 call removes its own window (kept for callers that pair the calls).
func dialog3_close() -> void:
	pass


## Op 0x17 (0x476612): the place name (the op handler expands it into 0x4b0758 first) goes into the 176 × 17 field (white frame, white text centred, surface 0xf,
## rect 0x4868d0); nothing is drawn in a battle and nothing waits.
func place_name(text: String) -> void:
	if Windows66.in_battle():
		return
	info_place = text
	_info.queue_redraw()


## Op 0x18 (0x47650f): the scenario title into the 268 × 17 field (surface 0xe, rect 0x4868c0); not in a battle.
func title_text(text: String) -> void:
	if Windows66.in_battle():
		return
	info_title = text
	_info.queue_redraw()


## Ops 0x29 / 0x2a / 0x2b map portraits (object 0x4b2b98, 8 slots of {person, x, y + 40}):
## show 0x42c4a5 — the face (120 × 120) at (x, y + 40) in a free slot (a person can be shown twice), with the
## transition 0x401c61 ([G] a 0.25 s fade); returns when drawn.
func portrait_show(pid: int, x: int, y: int) -> void:
	if _portraits.size() >= 8:
		return
	var s := Sprite2D.new()
	s.centered = false
	s.texture = Game.person_face(pid)
	s.region_enabled = true
	s.region_rect = Rect2(0, 0, 120, 120)
	s.position = Vector2(x, y + 0x28)
	_portrait_root.add_child(s)
	_portraits.append([pid, s])
	if Game.autoplay:
		return
	s.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(s, "modulate:a", 1.0, 0.25)
	await tw.finished


## Move 0x432adf: steps of max(|dx|, |dy|) / 4 (at least one pixel per axis), one tick each, until at (x, y + 40).
func portrait_move(pid: int, x: int, y: int) -> void:
	var e := _portrait_slot(pid)
	if e.is_empty():
		return
	var s: Sprite2D = e[1]
	var tx := x
	var ty := y + 0x28
	var sx := int(s.position.x)
	var sy := int(s.position.y)
	var n := maxi(absi(_div4(sx - tx)), absi(_div4(sy - ty)))
	var vx := 0
	var vy := 0
	if n != 0:
		vx = _divt(tx - sx, n)
		vy = _divt(ty - sy, n)
	if vx == 0:
		vx = -1 if sx - tx >= 0 else 1
	if vy == 0:
		vy = -1 if sy - ty >= 0 else 1
	while true:
		if absi(sx - tx) < absi(vx):
			vx = tx - sx
		if absi(sy - ty) < absi(vy):
			vy = ty - sy
		if sx != tx:
			sx += vx
		if sy != ty:
			sy += vy
		s.position = Vector2(sx, sy)
		if sx == tx and sy == ty:
			break
		if not Game.autoplay:
			await get_tree().create_timer(Text66.TICK).timeout
		if not is_instance_valid(s):
			return


## Hide 0x403cba: transition out ([G] 0.25 s fade), slot freed.
func portrait_hide(pid: int) -> void:
	var e := _portrait_slot(pid)
	if e.is_empty():
		return
	_portraits.erase(e)
	var s: Sprite2D = e[1]
	if not Game.autoplay:
		var tw := create_tween()
		tw.tween_property(s, "modulate:a", 0.0, 0.25)
		await tw.finished
	s.queue_free()


## 历史情报 (0x41c3d7): with no records (dword 0x509000 = 0) the 确认 box "目前无记录" instead; else the record
## window (HistoryWin66). [0x492e20] ≥ 5 (window pattern option) gives "需要设置对话框花色" in the original; the
## port has no pattern option.
func history_window() -> void:
	if Mem.r32(HistoryWin66.BUF) == 0:
		await message(0, "目前无记录")
		return
	if Game.autoplay:
		return
	var w := HistoryWin66.new()
	add_window(w)
	await w.run()
	w.queue_free()


## All map portraits off at once (scene change; port helper).
func portraits_clear() -> void:
	for e in _portraits:
		(e[1] as Node).queue_free()
	_portraits.clear()


func _portrait_slot(pid: int) -> Array:
	for e in _portraits:
		if int(e[0]) == pid:
			return e
	return []


static func _div4(v: int) -> int:
	return _divt(v, 4)


## C division (truncates toward zero).
static func _divt(a: int, b: int) -> int:
	var q := absi(a) / absi(b)
	return q if (a >= 0) == (b > 0) else -q


## The title / place-name fields of ops 0x18 / 0x17, showing the strings in memory (scenario title 0x49f1cc and
## place / stage name 0x4b0758, both saved with the game; 0x72 sub 8 also writes 0x4b0758), else the last texts passed
## to title_text() / place_name(): two framed fields (white 1-px frame, transparent inside —
## 0x4097fc fills with the key colour 8 and frames with 0x12) with the text centred on the 8-px grid
## (column = (w/8 − strlen) / 2, y + 1). The original's fields are child windows at (0, 34) 268 × 17 and
## (277, 34) 176 × 17 of an info window whose screen position was not found ([G]: shown in the 40-px band above the
## scene, at y 11, while a story scene runs).
class _InfoBar:
	extends Control
	var ui: GameUI

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	var _shown := ""

	func _process(_d: float) -> void:
		var st: Variant = Game.main.stage if Game.main else null
		var key := _mem_str(0x49f1cc, 22) + "|" + _mem_str(0x4b0758, 23) + "|" + ui.info_title + "|" + ui.info_place
		var on: bool = st != null and is_instance_valid(st) and not (st.has_method("in_battle") and st.in_battle()) \
				and key != "|||"
		if on != visible:
			visible = on
		if on and key != _shown:
			_shown = key
			queue_redraw()

	## The GBK string at addr (at most n bytes).
	static func _mem_str(addr: int, n: int) -> String:
		var b := PackedByteArray()
		for k in n:
			var c := Mem.r8(addr + k)
			if c == 0:
				break
			b.append(c)
		return TextExpand.from_gbk(b)

	func _draw() -> void:
		var f := Assets.font()
		var asc := f.get_ascent(Text66.FONT_SIZE)
		var t := _mem_str(0x49f1cc, 22)
		var pl := _mem_str(0x4b0758, 23)
		for e in [[Rect2(0, 11, 0x10c, 0x11), t if t != "" else ui.info_title],
				[Rect2(0x115, 11, 0xb0, 0x11), pl if pl != "" else ui.info_place]]:
			var r: Rect2 = e[0]
			draw_rect(Rect2(r.position + Vector2(0.5, 0.5), r.size - Vector2.ONE), Text66.pal(Text66.C_WHITE), false, 1.0)
			var s: String = e[1]
			var col := (int(r.size.x) >> 3) - Text66.gbk_len(s)
			if col < 0:
				continue
			col >>= 1
			var st := {"c": Text66.C_WHITE, "open": false}
			for g in Text66.glyphs(s, st):
				draw_string(f, Vector2(r.position.x + (col + int(g[2])) * Text66.COL, r.position.y + 1 + asc - 2), g[0],
						HORIZONTAL_ALIGNMENT_LEFT, -1, Text66.FONT_SIZE, Text66.pal(int(g[1])))
