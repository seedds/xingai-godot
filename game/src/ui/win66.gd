class_name Win66
extends Control
## One window of the 6.6 engine (Ekd5.exe), built from the same pieces its blitters use: pictures blitted at fixed
## positions (0x47e09b), the tiled window background with its shadow lines (0x473202), palette-coloured lines and
## rectangles, and text on the 8-px column grid (0x42c8b0, see Text66). The window covers the screen and swallows
## mouse input while it is open, like the engine's modal message loops.
## Waits: `type_page()` reveals text one character per tick (50 ms) while the message speed is on, and a click or
## a held skip key finishes the page at once (0x42c8b0 checks the mouse every character); `page_wait()` is 0x42d565.

var parts: Array = []        # draw list: [kind, ...]
var texts: Array = []        # {"x": px, "y": px, "g": glyphs, "shown": n}
var _clip := Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		accept_event()


# ------------------------------------------------------------------ building
## Blit a picture (or the `src` part of it) with its top-left at `pos`.
func pic(t: Texture2D, pos: Vector2, src := Rect2(), mod := Color.WHITE) -> void:
	if t == null:
		return
	if src.size == Vector2.ZERO:
		src = Rect2(Vector2.ZERO, t.get_size())
	parts.append(["tex", t, Rect2(pos, src.size), src, mod])
	queue_redraw()


## Window background 0x473202(x, y, w, h, flag): 48×48 tiles from (x, y) — Mark 花色 (0x2a0, the dove pattern) when
## `dove`, else the sand tile Mark 标志 frame 0 (0x3ada0) — then three shadow lines along the bottom and right edges
## (palette 0x83/0x85/0x87, or 0x18/0x1a/0x1c with `dove`) and a one-pixel light line above and left of the window
## (0x80, or 0x13 with `dove`).
func frame_window(r: Rect2, dove := false) -> void:
	var tile: Texture2D = Assets.tex("gfx/ui/mark/01.png") if dove else Assets.tex("gfx/ui/mark/07.png")
	var y := r.position.y
	while y < r.end.y:
		var x := r.position.x
		while x < r.end.x:
			var w := minf(48.0, r.end.x - x)
			var h := minf(48.0, r.end.y - y)
			parts.append(["tex", tile, Rect2(x, y, w, h), Rect2(0, 0, w, h), Color.WHITE])
			x += 48
		y += 48
	var c0 := 0x18 if dove else 0x83
	var x0 := r.position.x
	var y0 := r.position.y
	var x1 := r.end.x
	var y1 := r.end.y
	for i in 3:
		var c := Text66.pal(c0 + 2 * i)
		fill(Rect2(x0 + i, y1 + i, x1 - x0 - i + 1, 1), c)            # 0x47d4be(x+i, y+h+i, x+w, y+h+i)
		fill(Rect2(x1 + i, y0 + i, 1, y1 + 2 - y0 - i + 1), c)        # 0x47d4be(x+w+i, y+i, x+w+i, y+h+2)
	var hc := Text66.pal(0x13 if dove else 0x80)
	fill(Rect2(x0, y0 - 1, x1 - x0 + 1, 1), hc)
	fill(Rect2(x0 - 1, y0 - 1, 1, y1 - y0 + 2), hc)


func fill(r: Rect2, c: Color) -> void:
	parts.append(["rect", r, c, true])
	queue_redraw()


func outline(r: Rect2, c: Color) -> void:
	parts.append(["rect", r, c, false])
	queue_redraw()


## A text line at (x, y) (top of the 16-px cell) in palette colour `colour`, with the markup state `st` (Text66).
## Returns its index in `texts`; the line starts hidden.
func text_line(x: float, y: float, line: String, st: Dictionary) -> int:
	texts.append({"x": x, "y": y, "g": Text66.glyphs(line, st), "shown": 0})
	queue_redraw()
	return texts.size() - 1


## Text drawn at once and kept for the window's life (names), in palette colour `colour`.
func label(x: float, y: float, line: String, colour: int) -> void:
	var st := {"c": colour, "open": false}
	var g := Text66.glyphs(line, st)
	parts.append(["glyphs", {"x": x, "y": y, "g": g, "shown": g.size()}])
	queue_redraw()


func clear_texts() -> void:
	texts.clear()
	queue_redraw()


func remove_parts_from(n: int) -> void:
	parts.resize(n)
	queue_redraw()


# ------------------------------------------------------------------ waits
## Reveal the hidden text lines: one character per tick if `typewriter`, else at once; a click finishes them.
func type_page(typewriter: bool) -> void:
	if not typewriter or Game.autoplay:
		for t in texts:
			t["shown"] = (t["g"] as Array).size()
		queue_redraw()
		return
	var clicks := Game.clicks
	for t in texts:
		var g: Array = t["g"]
		while int(t["shown"]) < g.size():
			if Game.clicks != clicks or Game.skip_held() or not is_inside_tree():
				for t2 in texts:
					t2["shown"] = (t2["g"] as Array).size()
				queue_redraw()
				return
			var ch: String = g[int(t["shown"])][0]
			t["shown"] = int(t["shown"]) + 1
			queue_redraw()
			# 0x42c8b0: one tick per character, a second one after "、"
			await get_tree().create_timer(Text66.TICK * (2 if ch == "、" else 1)).timeout


## End of a page (0x42d565): click mode → wait for a click (0x42c782); else 15 / 10 / 20 rounds of 2 ticks for
## message speed 0 / 1 / 2, a click ending the wait early (0x42c646).
func page_wait() -> void:
	if Game.autoplay:
		return
	if Game.demo:
		await get_tree().create_timer(1.4).timeout
		return
	var n := Game.clicks
	if Text66.click_mode() or Text66.speed() >= 3:
		while Game.clicks == n and not Game.skip_held() and is_inside_tree():
			await get_tree().process_frame
		return
	var rounds: int = [15, 10, 20][Text66.speed()]
	await rounds_or_click(rounds)


## 0x42c646(n): n rounds of 2 ticks, a click ends it.
func rounds_or_click(rounds: int) -> void:
	if Game.autoplay:
		return
	var n := Game.clicks
	var t := 0.0
	while t < rounds * 2 * Text66.TICK and Game.clicks == n and not Game.skip_held() and is_inside_tree():
		await get_tree().process_frame
		t += get_process_delta_time()


## n ticks (0x423971 / 0x42c632 + 0x42c4e5), not skippable.
func ticks(n: int) -> void:
	if Game.autoplay or n <= 0:
		return
	await get_tree().create_timer(n * Text66.TICK).timeout


# ------------------------------------------------------------------ drawing
func _draw() -> void:
	var f := Assets.font()
	var asc := f.get_ascent(Text66.FONT_SIZE)
	for p in parts:
		match p[0]:
			"glyphs":
				_draw_glyphs(p[1], f, asc)
			"tex":
				draw_texture_rect_region(p[1], p[2], p[3], p[4])
			"rect":
				if p[3]:
					draw_rect(p[1], p[2], true)
				else:
					draw_rect(Rect2(p[1].position + Vector2(0.5, 0.5), p[1].size - Vector2.ONE), p[2], false, 1.0)
	for t in texts:
		_draw_glyphs(t, f, asc)


func _draw_glyphs(t: Dictionary, f: Font, asc: float) -> void:
	var g: Array = t["g"]
	for k in mini(int(t["shown"]), g.size()):
		var e: Array = g[k]
		draw_string(f, Vector2(float(t["x"]) + Text66.COL * int(e[2]), float(t["y"]) + asc), e[0],
				HORIZONTAL_ALIGNMENT_LEFT, -1, Text66.FONT_SIZE, Text66.pal(int(e[1])))
