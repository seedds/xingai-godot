class_name GameUI
extends CanvasLayer
## Top-level UI: dialog, menus, popups, banners, captions, fades, cutscene video.

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


func _init() -> void:
	layer = 20
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
func fade_to_black(t := 0.35) -> void:
	if Game.autoplay:
		fade_rect.color.a = 1.0
		return
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", 1.0, t)
	await tw.finished


func fade_from_black(t := 0.35) -> void:
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


## Narration captions over a dark/background screen. `wait` = wait for click after this line,
## `clear` = clear accumulated lines afterwards.
func caption(text: String, a1: int, wait_click: int, clear: int) -> void:
	if Game.autoplay:
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [caption] ", text)
		return
	var l := UIStyle.label(text, 18)
	l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	l.size = Vector2(vsize().x * 0.66, 10)
	_caption_root.add_child(l)
	_caption_lines.append(l)
	# stack the lines by their wrapped height; move the block up when it would run off the screen
	var gap := 10.0
	var lh := Assets.font().get_height(18) + 2
	var heights: Array[float] = []
	var total := 0.0
	for c in _caption_lines:
		var hh := maxf(c.get_line_count(), 1) * lh
		heights.append(hh)
		total += hh + gap
	var y := minf(vsize().y * 0.25, maxf(vsize().y - 24 - total, 12.0))
	for i in _caption_lines.size():
		_caption_lines[i].position = Vector2(vsize().x * 0.16, y)
		_caption_lines[i].size = Vector2(vsize().x * 0.66, heights[i])
		y += heights[i] + gap
	l.modulate.a = 0
	var tw := create_tween()
	tw.tween_property(l, "modulate:a", 1.0, 0.5)
	await tw.finished
	if wait_click != 0:
		await _wait_click()
	else:
		await get_tree().create_timer(0.6).timeout
	if clear != 0:
		var tw2 := create_tween()
		for c in _caption_lines:
			tw2.parallel().tween_property(c, "modulate:a", 0.0, 0.4)
		await tw2.finished
		for c in _caption_lines:
			c.queue_free()
		_caption_lines.clear()


func clear_captions() -> void:
	for c in _caption_lines:
		c.queue_free()
	_caption_lines.clear()


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


func chapter_title(num: int, text: String) -> void:
	if Game.autoplay:
		print("  [chapter] ", num, " ", text)
		return
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.add_child(bg)
	var l1 := UIStyle.label("第 %d 章" % (num + 1) if num >= 0 else "", 20, Color(0.9, 0.8, 0.5))
	var l2 := UIStyle.label(text, 32, Color(1, 0.95, 0.8))
	for l in [l1, l2]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.size = Vector2(vsize().x, 40)
		_title_root.add_child(l)
	l1.position = Vector2(0, vsize().y * 0.36)
	l2.position = Vector2(0, vsize().y * 0.36 + 40)
	_title_root.modulate.a = 0
	var tw := create_tween()
	tw.tween_property(_title_root, "modulate:a", 1.0, 0.6)
	tw.tween_interval(1.8)
	tw.tween_property(_title_root, "modulate:a", 0.0, 0.6)
	await tw.finished
	for c in _title_root.get_children():
		c.queue_free()
	_title_root.modulate.a = 1
